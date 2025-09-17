from __future__ import annotations
from pathlib import Path
import time
import psutil
from PIL import ImageChops

from .config import load_config
from .paths import Paths
from .hardware.display import get_waveshare_display, MockDisplay
from .ui.screens import HomeScreen, InfoScreen, BackupScreen, VerifyScreen, DoneScreen, WebserverConfirmScreen, WebserverEnabledScreen, SettingsScreen, ErrorScreen, SettingsConfirmScreen, DeviceDetectedScreen, DeviceRemovedScreen, ProxiesScreen, BootScreen
from .i18n import t as tr
from .backup.scanner import find_source_mounts
from .backup.backup import copy_from_source
from .proxies.generate import generate_for_folder
from .hardware.buttons import Buttons
from .hardware.power import is_undervoltage
from .ap_mode import start_ap, stop_ap, get_ap_address
from .hardware.usb import UsbDeviceMonitor, ensure_usb_mounted
from .media.metadata import MediaMetadataIndex
from .gopro.network import gopro_present
from .gopro.link import prepare_link, teardown_link
from .gopro.http_importer import import_media_http
from .stats import collect_trip_media_stats


def bytes_to_gb(n: int) -> str:
    return f"{n/1_000_000_000:.0f}gb"


def render_and_push(disp, screen):
    img = screen.draw()

    last_state = getattr(render_and_push, '_last_frame', None)
    if last_state:
        last_disp, last_img, last_type = last_state
    else:
        last_disp, last_img, last_type = None, None, None

    current_type = type(screen)
    partial_whitelist = getattr(render_and_push, '_partial_whitelist', None)
    if partial_whitelist is None:
        partial_whitelist = {HomeScreen}
        render_and_push._partial_whitelist = partial_whitelist

    allow_partial = current_type in partial_whitelist and last_type is current_type

    supports_partial = allow_partial and hasattr(disp, 'supports_partial') and disp.supports_partial()
    if supports_partial and last_img is not None and last_disp is disp and img.size == last_img.size:
        diff = ImageChops.difference(last_img, img)
        bbox = diff.getbbox()
        if bbox is None:
            render_and_push._last_frame = (disp, img.copy(), current_type)
            return
        padding = 3
        x0 = max(0, bbox[0] - padding)
        y0 = max(0, bbox[1] - padding)
        x1 = min(img.width, bbox[2] + padding)
        y1 = min(img.height, bbox[3] + padding)
        area = (x1 - x0) * (y1 - y0)
        full_area = img.width * img.height
        if area < full_area // 3:
            disp.render_partial(img, (x0, y0, x1, y1))
        else:
            disp.render(img)
    else:
        disp.render(img)

    render_and_push._last_frame = (disp, img.copy(), current_type)


def run_manual_backup(disp, cfg, paths, buttons: Buttons, dev_mode: bool):
    # Manual backup flow (single source only)
    # Allow a short grace period for the OS to automount the device
    # after we detected a USB insert event.
    matches = []
    start_wait = time.monotonic()
    wait_timeout = 12.0  # seconds
    tried_mount = False
    while True:
        matches = find_source_mounts(cfg['paths']['source_roots'])
        # Exclude the destination NVMe mount from sources
        try:
            nvme_res = paths.nvme_mount.resolve()
            matches = [m for m in matches if m.resolve() != nvme_res]
        except Exception:
            pass
        if matches:
            break
        # After a short delay, attempt auto-mounting USB partitions if still nothing
        if not tried_mount and (time.monotonic() - start_wait) >= 1.0:
            try:
                ensure_usb_mounted()
            except Exception:
                pass
            tried_mount = True
        if (time.monotonic() - start_wait) >= wait_timeout:
            break
        time.sleep(0.5)
    if not matches:
        lang = cfg.get('language', 'en')
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.insert_sd')))
        _wait_for_home(buttons, dev_mode)
        return
    if len(matches) > 1:
        lang = cfg.get('language', 'en')
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.two_cards')))
        _wait_for_home(buttons, dev_mode)
        return
    src = matches[0]

    # Backup screen
    remaining = psutil.disk_usage(str(paths.nvme_mount)).free
    lang = cfg.get('language', 'en')
    render_and_push(
        disp,
        BackupScreen(
            disp.width,
            disp.height,
            lang,
            device_label='device',
            copying_from=str(src),
            copying_to=str(paths.trip_root()),
            eta_min=None,
            remaining_gb=f"{bytes_to_gb(remaining)}",
            progress=0.0,
        ),
    )

    # Do copy with progress callback updating the bar
    total_seen = {'total': 1, 'i': 0}

    def progress_cb(i, total):
        total_seen['i'] = i
        total_seen['total'] = max(total_seen['total'], total)
        frac = i / float(total_seen['total']) if total_seen['total'] else 0
        render_and_push(
            disp,
            BackupScreen(
                disp.width,
                disp.height,
                lang,
                device_label='device',
                copying_from=str(src),
                copying_to=str(paths.trip_root()),
                eta_min=None,
                remaining_gb=f"{bytes_to_gb(remaining)}",
                progress=frac,
            ),
        )

    # Check undervoltage; pause until stable
    if is_undervoltage():
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.low_power_wait')))
        while is_undervoltage():
            time.sleep(2)
        render_and_push(disp, BackupScreen(disp.width, disp.height, lang, 'device', str(src), str(paths.trip_root()), None, f"{bytes_to_gb(remaining)}", 0.0))

    result = copy_from_source(src, paths, verify_mode=cfg['verify']['default_mode'], progress_cb=progress_cb)

    # Verify screen (since per-file verify is done); show 100%.
    render_and_push(disp, VerifyScreen(disp.width, disp.height, lang, cfg['verify']['default_mode'].upper(), 1.0))

    if result.errors:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.verify_failed')))
        _wait_for_home(buttons, dev_mode)
        return

    # Start proxies after verification, with on-screen progress (if enabled)
    if bool((cfg.get('previews', {}) or {}).get('enabled', True)):
        def proxies_progress(done: int, total: int, path: Path, kind: str):
            # Show current filename (basename)
            name = path.name if isinstance(path, Path) else ''
            render_and_push(disp, ProxiesScreen(disp.width, disp.height, lang, done, total, name))

        render_and_push(disp, ProxiesScreen(disp.width, disp.height, lang, 0, 0, ''))
        generate_for_folder(
            paths.trip_root(),
            paths.proxies_dir(),
            cfg['previews']['max_cache_gb'] * 1_000_000_000,
            height=cfg['previews']['video_height'],
            bitrate=str(cfg['previews']['video_bitrate']),
            progress_cb=proxies_progress,
        )

    # Done
    render_and_push(disp, DoneScreen(disp.width, disp.height, lang, result.copied_files))
    _wait_for_home(buttons, dev_mode)


def run_gopro_import(disp, cfg, paths, buttons: Buttons, dev_mode: bool):
    lang = cfg.get('language', 'en')
    remaining = psutil.disk_usage(str(paths.nvme_mount)).free
    render_and_push(
        disp,
        BackupScreen(
            disp.width,
            disp.height,
            lang,
            device_label='gopro',
            copying_from='GoPro',
            copying_to=str(paths.trip_root()),
            eta_min=None,
            remaining_gb=f"{bytes_to_gb(remaining)}",
            progress=0.0,
        ),
    )

    metadata_index = MediaMetadataIndex(paths)
    min_free = int(cfg.get('limits', {}).get('min_free_gb', 10)) * 1_000_000_000

    last_name = {'name': ''}

    def progress_cb(done: int, total: int, fraction: float, name: str) -> None:
        if name:
            last_name['name'] = name
        status = f"GoPro: {last_name['name']}" if last_name['name'] else 'GoPro'
        remaining_local = psutil.disk_usage(str(paths.nvme_mount)).free
        render_and_push(
            disp,
            BackupScreen(
                disp.width,
                disp.height,
                lang,
                device_label='gopro',
                copying_from=status,
                copying_to=str(paths.trip_root()),
                eta_min=None,
                remaining_gb=f"{bytes_to_gb(remaining_local)}",
                progress=fraction,
            ),
        )

    # Prefer HTTP (GoPro Connect) import for reliability
    link = prepare_link()
    if not link:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.gopro_connect_failed')))
        _wait_for_home(buttons, dev_mode)
        return
    iface, host_ip = link
    try:
        http_res = import_media_http(
            paths,
            metadata_index,
            min_free,
            progress_cb=progress_cb,
            host=host_ip,
        )
    finally:
        teardown_link(iface)

    result = http_res

    if result.total == 0:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.gopro_no_media')))
        _wait_for_home(buttons, dev_mode)
        return

    if result.downloaded and bool((cfg.get('previews', {}) or {}).get('enabled', True)):
        def proxies_progress(done: int, total: int, path: Path, kind: str):
            name = path.name if isinstance(path, Path) else ''
            render_and_push(disp, ProxiesScreen(disp.width, disp.height, lang, done, total, name))

        render_and_push(disp, ProxiesScreen(disp.width, disp.height, lang, 0, 0, ''))
        generate_for_folder(
            paths.trip_root(),
            paths.proxies_dir(),
            cfg['previews']['max_cache_gb'] * 1_000_000_000,
            height=cfg['previews']['video_height'],
            bitrate=str(cfg['previews']['video_bitrate']),
            progress_cb=proxies_progress,
        )

    render_and_push(disp, DoneScreen(disp.width, disp.height, lang, result.downloaded))
    _wait_for_home(buttons, dev_mode)



def run_settings_flow(disp, cfg, buttons: Buttons, dev_mode: bool = False):
    idx = 0
    verify = cfg['verify']['default_mode']
    power_off = cfg.get('power_off_screen', 'info')
    if power_off == 'weather':
        power_off = 'trip'
    proxies_enabled = bool((cfg.get('previews', {}) or {}).get('enabled', True))
    tone = True  # placeholder toggle only
    network_mode = (cfg.get('network', {}) or {}).get('mode', 'ap')
    language = (cfg.get('language') or 'en').lower()

    render_and_push(disp, SettingsScreen(disp.width, disp.height, language, verify, power_off, proxies_enabled, tone, network_mode, ui_language=language, selected=idx))
    if dev_mode:
        # Toggle verify and save in dev mode (no GPIO)
        verify = 'sha256' if verify == 'fast' else 'fast'
        cfg['verify']['default_mode'] = verify
        from .config import save_config
        save_config(cfg)
        return

    import time as _t
    last = [False, False, False, False]
    while True:
        st = buttons.read() or [False, False, False, False]
        if st[0] and not last[0]:
            idx = (idx - 1) % 6
            render_and_push(disp, SettingsScreen(disp.width, disp.height, language, verify, power_off, proxies_enabled, tone, network_mode, ui_language=language, selected=idx))
        if st[1] and not last[1]:
            idx = (idx + 1) % 6
            render_and_push(disp, SettingsScreen(disp.width, disp.height, language, verify, power_off, proxies_enabled, tone, network_mode, ui_language=language, selected=idx))
        if st[2] and not last[2]:
            # toggle current setting
            if idx == 0:
                verify = 'sha256' if verify == 'fast' else 'fast'
            elif idx == 1:
                power_off = {'info':'trip','trip':'clear','clear':'info'}.get(power_off, 'info')
            elif idx == 2:
                proxies_enabled = not proxies_enabled
            elif idx == 3:
                tone = not tone
            elif idx == 4:
                network_mode = 'wifi' if (network_mode or 'ap').lower() == 'ap' else 'ap'
            else:  # idx == 5 language
                language = 'nl' if (language or 'en').lower() == 'en' else 'en'
            render_and_push(disp, SettingsScreen(disp.width, disp.height, language, verify, power_off, proxies_enabled, tone, network_mode, ui_language=language, selected=idx))
        if st[3] and not last[3]:
            # Save confirmation: Yes=button1 (top) -> save & go home,
            # No=button2 -> go home without saving,
            # Home=button4 -> back to settings
            render_and_push(disp, SettingsConfirmScreen(disp.width, disp.height, language))
            while True:
                st2 = buttons.read() or [False, False, False, False]
                if st2[0]:  # Yes (top)
                    cfg['verify']['default_mode'] = verify
                    cfg['power_off_screen'] = power_off
                    # ensure network mode saved
                    cfg.setdefault('network', {})['mode'] = network_mode
                    cfg.setdefault('previews', {})['enabled'] = proxies_enabled
                    cfg['language'] = language
                    from .config import save_config
                    save_config(cfg)
                    return
                if st2[1]:  # No (second) -> go home
                    return
                if st2[3]:  # Home -> back to settings
                    break
                _t.sleep(0.05)
            # Re-render settings after canceling confirmation
            render_and_push(disp, SettingsScreen(disp.width, disp.height, language, verify, power_off, proxies_enabled, tone, network_mode, ui_language=language, selected=idx))
        last = st
        _t.sleep(0.05)


def _wait_for_home(buttons: Buttons, dev_mode: bool):
    if dev_mode:
        return
    import time as _t
    last = [False, False, False, False]
    while True:
        st = buttons.read() or [False, False, False, False]
        if st[3] and not last[3]:
            return
        last = st
        _t.sleep(0.05)


def _menu_select(disp, buttons: Buttons, sel: int, dev_mode: bool, monitor: UsbDeviceMonitor | None = None, poll_interval_s: float = 0.5, lang: str = 'en') -> int:
    if dev_mode:
        return sel
    import time as _t
    last_state = [False, False, False, False]
    last_poll = _t.monotonic()
    while True:
        st = buttons.read() or [False, False, False, False]
        if st[0] and not last_state[0]:
            sel = (sel - 1) % 4
            render_and_push(disp, HomeScreen(disp.width, disp.height, lang, selected=sel))
        if st[1] and not last_state[1]:
            sel = (sel + 1) % 4
            render_and_push(disp, HomeScreen(disp.width, disp.height, lang, selected=sel))
        if st[2] and not last_state[2]:
            return sel
        # Periodically poll for device events while on Home
        if monitor is not None and (_t.monotonic() - last_poll) >= poll_interval_s:
            evt = monitor.poll()
            last_poll = _t.monotonic()
            if evt == 'insert':
                return -1
            if evt == 'remove':
                return -2
            if evt == 'gopro_insert':
                return -3
            if evt == 'gopro_remove':
                return -4
            # Fallback: if GoPro was connected before monitor started, still offer import
            try:
                if gopro_present():
                    return -3
            except Exception:
                pass
            if evt == 'gopro_insert':
                return -3
            if evt == 'gopro_remove':
                return -4
        last_state = st
        _t.sleep(0.05)


def run(dev_mode: bool = True):
    cfg = load_config()
    paths = Paths(cfg).ensure()
    disp = MockDisplay() if dev_mode else get_waveshare_display()
    buttons = Buttons(pins=cfg.get('hardware',{}).get('buttons',[5,6,13,19]), dev_mode=dev_mode)
    monitor = UsbDeviceMonitor()
    # Show a simple boot screen briefly on startup
    try:
        lang = (cfg.get('language') or 'en').lower()
        render_and_push(disp, BootScreen(disp.width, disp.height, lang))
        time.sleep(1.0)
    except Exception:
        pass

    while True:
        # Reload config to reflect any changes saved in settings
        cfg = load_config()
        lang = cfg.get('language', 'en')
        # Home menu
        sel = 0
        render_and_push(disp, HomeScreen(disp.width, disp.height, lang, selected=sel))
        # Check hotplug events immediately on entering Home
        evt = monitor.poll()
        if evt == 'insert':
            # Show detection notice; 1=start backup, 4=dismiss
            render_and_push(disp, DeviceDetectedScreen(disp.width, disp.height, lang))
            if not dev_mode:
                import time as _t
                last = [False, False, False, False]
                while True:
                    st = buttons.read() or [False, False, False, False]
                    if st[0] and not last[0]:  # start backup
                        # Do not re-notify while device stays inserted
                        monitor.suppress_last_inserts()
                        monitor.enter_cooldown(1.0)
                        run_manual_backup(disp, cfg, paths, buttons, dev_mode)
                        break
                    if st[3] and not last[3]:  # dismiss
                        monitor.suppress_last_inserts()
                        monitor.enter_cooldown(1.0)
                        break
                    # If device is removed while this screen is open, switch to removed screen
                    evt2 = monitor.poll()
                    if evt2 == 'remove':
                        render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
                        _wait_for_home(buttons, dev_mode)
                        monitor.enter_cooldown(1.0)
                        break
                    last = st
                    _t.sleep(0.05)
            # After handling, re-render Home and continue
            render_and_push(disp, HomeScreen(disp.width, disp.height, lang, selected=sel))
        elif evt == 'remove':
            render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
            _wait_for_home(buttons, dev_mode)
            monitor.resync()
            monitor.enter_cooldown(1.0)
            render_and_push(disp, HomeScreen(disp.width, disp.height, selected=sel))
        elif evt == 'gopro_insert':
            render_and_push(disp, DeviceDetectedScreen(disp.width, disp.height, lang, title_key='device.gopro_connected_title', start_key='device.gopro_start_button'))
            if not dev_mode:
                import time as _t
                last = [False, False, False, False]
                while True:
                    st = buttons.read() or [False, False, False, False]
                    if st[0] and not last[0]:  # start import
                        monitor.suppress_gopro()
                        monitor.enter_cooldown(1.0)
                        run_gopro_import(disp, cfg, paths, buttons, dev_mode)
                        break
                    if st[3] and not last[3]:  # dismiss
                        monitor.suppress_gopro()
                        monitor.enter_cooldown(1.0)
                        break
                    evt2 = monitor.poll()
                    if evt2 == 'gopro_remove':
                        render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
                        _wait_for_home(buttons, dev_mode)
                        monitor.enter_cooldown(1.0)
                        break
                    last = st
                    _t.sleep(0.05)
            render_and_push(disp, HomeScreen(disp.width, disp.height, lang, selected=sel))
        elif evt == 'gopro_remove':
            render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
            _wait_for_home(buttons, dev_mode)
            monitor.resync()
            monitor.enter_cooldown(1.0)
            render_and_push(disp, HomeScreen(disp.width, disp.height, selected=sel))
        sel = _menu_select(disp, buttons, sel, dev_mode, monitor=monitor, poll_interval_s=0.5, lang=lang)
        if sel == -1:
            render_and_push(disp, DeviceDetectedScreen(disp.width, disp.height, lang))
            if not dev_mode:
                import time as _t
                last = [False, False, False, False]
                while True:
                    st = buttons.read() or [False, False, False, False]
                    if st[0] and not last[0]:  # start backup
                        monitor.suppress_last_inserts()
                        monitor.enter_cooldown(1.0)
                        run_manual_backup(disp, cfg, paths, buttons, dev_mode)
                        break
                    if st[3] and not last[3]:  # dismiss
                        monitor.suppress_last_inserts()
                        monitor.enter_cooldown(1.0)
                        break
                    evt2 = monitor.poll()
                    if evt2 == 'remove':
                        render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
                        _wait_for_home(buttons, dev_mode)
                        monitor.resync()
                        monitor.enter_cooldown(1.0)
                        break
                    last = st
                    _t.sleep(0.05)
            continue
        if sel == -2:
            render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
            _wait_for_home(buttons, dev_mode)
            monitor.resync()
            monitor.enter_cooldown(1.0)
            continue
        if sel == -3:
            render_and_push(disp, DeviceDetectedScreen(disp.width, disp.height, lang, title_key='device.gopro_connected_title', start_key='device.gopro_start_button'))
            if not dev_mode:
                import time as _t
                last = [False, False, False, False]
                while True:
                    st = buttons.read() or [False, False, False, False]
                    if st[0] and not last[0]:
                        monitor.suppress_gopro()
                        monitor.enter_cooldown(1.0)
                        run_gopro_import(disp, cfg, paths, buttons, dev_mode)
                        break
                    if st[3] and not last[3]:
                        monitor.suppress_gopro()
                        monitor.enter_cooldown(1.0)
                        break
                    evt2 = monitor.poll()
                    if evt2 == 'gopro_remove':
                        render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
                        _wait_for_home(buttons, dev_mode)
                        monitor.resync()
                        monitor.enter_cooldown(1.0)
                        break
                    last = st
                    _t.sleep(0.05)
            continue
        if sel == -4:
            render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
            _wait_for_home(buttons, dev_mode)
            monitor.resync()
            monitor.enter_cooldown(1.0)
            continue

        if sel == 0:
            run_manual_backup(disp, cfg, paths, buttons, dev_mode)
            
        elif sel == 1:
            # Webserver (AP) confirm: Yes=button1 (top), No=button2, Home=button4
            net_mode = (cfg.get('network', {}) or {}).get('mode', 'ap').lower()
            if net_mode == 'wifi':
                # In WiFi mode we don't create a hotspot; just show URL and allow exit with 3 or Home
                url = get_ap_address()
                render_and_push(disp, WebserverEnabledScreen(disp.width, disp.height, lang, url))
                import time as _t
                last2 = [False, False, False, False]
                while True:
                    st2 = buttons.read() or [False, False, False, False]
                    if st2[2] and not last2[2]:  # Button 3: close screen (no AP to stop)
                        break
                    if st2[3] and not last2[3]:  # Home
                        break
                    last2 = st2
                    _t.sleep(0.05)
                continue
            render_and_push(disp, WebserverConfirmScreen(disp.width, disp.height, lang))
            if not dev_mode:
                import time as _t
                last = [False, False, False, False]
                while True:
                    st = buttons.read() or [False, False, False, False]
                    if st[0] and not last[0]:  # Yes (top)
                        rc = start_ap()
                        if rc != 0:
                            msg = tr(lang, 'web.ap_error.start_failed')
                            if rc == 127:
                                msg = tr(lang, 'web.ap_error.nmcli_missing')
                            elif rc == 400:
                                msg = tr(lang, 'web.ap_error.ap_password_invalid')
                            elif rc == 401:
                                msg = tr(lang, 'web.ap_error.not_authorized')
                            render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, msg))
                            _wait_for_home(buttons, dev_mode)
                            break
                        url = get_ap_address()
                        render_and_push(disp, WebserverEnabledScreen(disp.width, disp.height, lang, url))
                        # Allow closing with button 3; button 4 returns home
                        last2 = [False, False, False, False]
                        while True:
                            st2 = buttons.read() or [False, False, False, False]
                            if st2[2] and not last2[2]:  # Button 3 closes hotspot
                                try:
                                    stop_ap()
                                finally:
                                    break
                            if st2[3] and not last2[3]:  # Home
                                break
                            last2 = st2
                            _t.sleep(0.05)
                        break
                    if st[1] and not last[1]:  # No (second)
                        break
                    if st[3] and not last[3]:  # Home
                        break
                    last = st
                    _t.sleep(0.05)
            else:
                # dev mode: simulate Webserver enabled
                url = 'http://blackbox.local:8080'
                render_and_push(disp, WebserverEnabledScreen(disp.width, disp.height, lang, url))
                import time as _t
                last2 = [False, False, False, False]
                while True:
                    st2 = buttons.read() or [False, False, False, False]
                    if st2[2] and not last2[2]:  # Button 3 closes (no-op in dev)
                        break
                    if st2[3] and not last2[3]:  # Home
                        break
                    last2 = st2
                    _t.sleep(0.05)

        elif sel == 2:
            media_stats = collect_trip_media_stats(cfg, paths)
            stats = {
                'trip_name': media_stats.trip_name,
                'video_duration': media_stats.video_duration_label,
                'photo_count': media_stats.photo_count,
                'free_gb': bytes_to_gb(media_stats.free_bytes),
                'devices': media_stats.device_names,
            }
            render_and_push(disp, InfoScreen(disp.width, disp.height, lang, stats))
            _wait_for_home(buttons, dev_mode)

        elif sel == 3:
            # Settings flow returns to Home on confirm Yes/No; if canceled, stays in Settings
            run_settings_flow(disp, cfg, buttons, dev_mode)


if __name__ == '__main__':
    # Default to real hardware if available; set BLACKBOX_DEV=1 to force mock mode.
    import os
    dev = os.environ.get('BLACKBOX_DEV') == '1'
    run(dev_mode=dev)
