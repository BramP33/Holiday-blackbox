from __future__ import annotations
from pathlib import Path
import time
import psutil

from .config import load_config
from .paths import Paths
from .hardware.display import get_waveshare_display, MockDisplay
from .ui.screens import HomeScreen, InfoScreen, BackupScreen, VerifyScreen, DoneScreen, APConfirmScreen, APEnabledScreen, SettingsScreen, ErrorScreen, SettingsConfirmScreen
from .backup.scanner import find_first_dcim, find_dcim_mounts
from .backup.backup import copy_from_source
from .proxies.generate import generate_for_folder
from .hardware.buttons import Buttons
from .hardware.power import is_undervoltage
from .ap_mode import start_ap, stop_ap, get_ap_address


def bytes_to_gb(n: int) -> str:
    return f"{n/1_000_000_000:.0f}gb"


def render_and_push(disp, screen):
    img = screen.draw()
    disp.render(img)


def run_settings_flow(disp, cfg, buttons: Buttons, dev_mode: bool = False):
    idx = 0
    verify = cfg['verify']['default_mode']
    power_off = cfg.get('power_off_screen', 'info')
    tone = True  # placeholder toggle only

    render_and_push(disp, SettingsScreen(disp.width, disp.height, verify, power_off, tone, selected=idx))
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
            idx = (idx - 1) % 3
            render_and_push(disp, SettingsScreen(disp.width, disp.height, verify, power_off, tone, selected=idx))
        if st[1] and not last[1]:
            idx = (idx + 1) % 3
            render_and_push(disp, SettingsScreen(disp.width, disp.height, verify, power_off, tone, selected=idx))
        if st[2] and not last[2]:
            # toggle
            if idx == 0:
                verify = 'sha256' if verify == 'fast' else 'fast'
            elif idx == 1:
                power_off = {'info':'weather','weather':'clear','clear':'info'}[power_off]
            else:
                tone = not tone
            render_and_push(disp, SettingsScreen(disp.width, disp.height, verify, power_off, tone, selected=idx))
        if st[3] and not last[3]:
            # save confirm
            render_and_push(disp, SettingsConfirmScreen(disp.width, disp.height))
            # interpret: third=Yes, bottom=No
            while True:
                st2 = buttons.read() or [False, False, False, False]
                if st2[2]:  # yes
                    cfg['verify']['default_mode'] = verify
                    cfg['power_off_screen'] = power_off
                    from .config import save_config
                    save_config(cfg)
                    return
                if st2[3]:  # no
                    return
                _t.sleep(0.05)
        last = st
        _t.sleep(0.05)


def run(dev_mode: bool = True):
    cfg = load_config()
    paths = Paths(cfg).ensure()
    disp = MockDisplay() if dev_mode else get_waveshare_display()
    buttons = Buttons(pins=cfg.get('hardware',{}).get('buttons',[5,6,13,19]), dev_mode=dev_mode)

    # State: simple menu navigation
    menu = ['Start back-up', 'AP-mode', 'Info', 'Settings']
    sel = 0
    render_and_push(disp, HomeScreen(disp.width, disp.height))

    # For this skeleton, immediately run selected action if dev_mode (no GPIO)
    if dev_mode:
        sel = 0  # Start back-up by default in mock mode
    else:
        # Await a selection (Up/Down/Select)
        import time as _t
        last_state = [False, False, False, False]
        while True:
            st = buttons.read() or [False, False, False, False]
            if st[0] and not last_state[0]:
                sel = (sel - 1) % len(menu)
                render_and_push(disp, HomeScreen(disp.width, disp.height))
            if st[1] and not last_state[1]:
                sel = (sel + 1) % len(menu)
                render_and_push(disp, HomeScreen(disp.width, disp.height))
            if st[2] and not last_state[2]:
                break
            last_state = st
            _t.sleep(0.05)

    # Manual backup flow (single source only)
    matches = find_dcim_mounts(cfg['paths']['source_roots'])
    if not matches:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, 'No media'))
        return
    if len(matches) > 1:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, '2 cards detected! Remove one'))
        return
    src = matches[0]

    # Backup screen
    remaining = psutil.disk_usage(str(paths.nvme_mount)).free
    render_and_push(
        disp,
        BackupScreen(
            disp.width,
            disp.height,
            device_label='device',
            copying_from=str(src),
            copying_to=str(paths.trip_root()),
            eta_min=None,
            remaining_str=f"{bytes_to_gb(remaining)} free",
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
                device_label='device',
                copying_from=str(src),
                copying_to=str(paths.trip_root()),
                eta_min=None,
                remaining_str=f"{bytes_to_gb(remaining)} free",
                progress=frac,
            ),
        )

    # Check undervoltage; pause until stable
    if is_undervoltage():
        render_and_push(disp, ErrorScreen(disp.width, disp.height, 'Low power. Waiting...'))
        while is_undervoltage():
            time.sleep(2)
        render_and_push(disp, BackupScreen(disp.width, disp.height, 'device', str(src), str(paths.trip_root()), None, f"{bytes_to_gb(remaining)} free", 0.0))

    result = copy_from_source(src, paths, verify_mode=cfg['verify']['default_mode'], progress_cb=progress_cb)

    # Verify screen (since per-file verify is done); show 100%.
    render_and_push(disp, VerifyScreen(disp.width, disp.height, cfg['verify']['default_mode'].upper(), 1.0))

    if result.errors:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, 'Verify failed'))
        return

    # Start proxies after verification
    generate_for_folder(paths.trip_root(), paths.proxies_dir(), cfg['previews']['max_cache_gb'] * 1_000_000_000, height=cfg['previews']['video_height'], bitrate=str(cfg['previews']['video_bitrate']))

    # Done
    render_and_push(disp, DoneScreen(disp.width, disp.height, result.copied_files))

    # AP-mode confirm -> start AP -> show URL
    if sel == 1:
        render_and_push(disp, APConfirmScreen(disp.width, disp.height))
        rc = start_ap()
        if rc != 0:
            render_and_push(disp, ErrorScreen(disp.width, disp.height, 'AP start failed'))
            return
        url = get_ap_address()
        render_and_push(disp, APEnabledScreen(disp.width, disp.height, url))

    # Settings flow
    if sel == 3:
        run_settings_flow(disp, cfg, buttons, dev_mode)


if __name__ == '__main__':
    run(dev_mode=True)
