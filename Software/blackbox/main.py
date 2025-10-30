from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional
import math
import os
import shutil
import threading
import time

import psutil
from PIL import ImageChops

from .config import load_config
from .paths import Paths
from .hardware.display import get_waveshare_display, MockDisplay
from .ui.screens import (
    HomeScreen,
    InfoScreen,
    BackupScreen,
    VerifyScreen,
    DoneScreen,
    WebserverConfirmScreen,
    WebserverEnabledScreen,
    SettingsScreen,
    ErrorScreen,
    SettingsConfirmScreen,
    DeviceDetectedScreen,
    DeviceRemovedScreen,
    ProxiesScreen,
    BootScreen,
    LargeDrivePromptScreen,
    LargeDriveConfirmScreen,
    LargeDriveProgressScreen,
    OffloadDoneScreen,
    OffloadCancelledScreen,
)
from .i18n import t as tr
from .backup.scanner import find_source_mounts
from .backup.backup import CopyProgress, copy_from_source
from .proxies.generate import generate_for_folder
from .hardware.buttons import Buttons
from .hardware.power import is_undervoltage
from .ap_mode import start_ap, stop_ap, get_ap_address
from .hardware.usb import UsbDeviceMonitor, ensure_usb_mounted, usb_partitions
from .media.metadata import MediaMetadataIndex
from .gopro.network import gopro_present
from .gopro.link import prepare_link, teardown_link
from .gopro.http_importer import import_media_http
from .gopro.mtp_importer import import_media_mtp
from .stats import collect_trip_media_stats
from .transcription.queue import TranscriptionQueue
from .transcription.worker import TranscriptionWorker, MissingDependencyError


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

    home_should_partial = False
    if current_type is HomeScreen:
        home_should_partial = getattr(render_and_push, '_home_should_partial_next', False)
        if last_type is not current_type:
            home_should_partial = False

    supports_partial = allow_partial and hasattr(disp, 'supports_partial') and disp.supports_partial()
    if current_type is HomeScreen and not home_should_partial:
        supports_partial = False

    did_partial = False
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
            did_partial = True
        else:
            disp.render(img)
    else:
        disp.render(img)

    render_and_push._last_frame = (disp, img.copy(), current_type)

    if current_type is HomeScreen:
        render_and_push._home_should_partial_next = not did_partial
    else:
        render_and_push._home_should_partial_next = False


LARGE_DRIVE_THRESHOLD_BYTES = 256 * 1_000_000_000
DEFAULT_OFFLOAD_SPEED_BPS = 90 * 1_000_000
COPY_CHUNK_SIZE = 8 * 1024 * 1024


@dataclass
class LargeDriveInfo:
    device_base: str
    partition: str
    mountpoint: Path
    label: str
    size_bytes: int
    total_bytes: int
    total_files: int
    estimated_seconds: float
    trip_name: str


@dataclass
class OffloadResult:
    files_copied: int
    bytes_copied: int
    cancelled: bool
    errors: List[str]


class OffloadCancelled(Exception):
    pass


_INDEX_NOW_STATE = {
    'thread': None,
    'status': 'idle',
    'error_code': None,
    'error_detail': None,
}


def _calculate_directory_totals(root: Path) -> tuple[int, int]:
    total_bytes = 0
    total_files = 0
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            try:
                p = Path(dirpath) / fn
                total_bytes += p.stat().st_size
                total_files += 1
            except FileNotFoundError:
                continue
            except OSError:
                continue
    return total_bytes, total_files


def _format_eta(seconds: Optional[float]) -> str:
    if seconds is None or seconds <= 0:
        return '0m'
    if seconds < 60:
        return '~1m'
    minutes = seconds / 60.0
    if minutes < 120:
        rounded = max(1, int(round(minutes)))
        return f"~{rounded}m"
    hours = minutes / 60.0
    if hours < 10:
        return f"~{hours:.1f}h"
    return f"~{int(round(hours))}h"


def _format_speed(bytes_per_sec: float) -> str:
    if bytes_per_sec <= 0:
        return '0 MB/s'
    mb = bytes_per_sec / 1_000_000.0
    if mb >= 100:
        return f"{mb:.0f} MB/s"
    return f"{mb:.1f} MB/s"


def _detect_large_drive(paths: Paths, monitor: UsbDeviceMonitor, threshold: int = LARGE_DRIVE_THRESHOLD_BYTES) -> Optional[LargeDriveInfo]:
    inserted = getattr(monitor, 'last_inserted', set()) or set()
    if not inserted:
        return None
    try:
        ensure_usb_mounted(readonly=False)
    except Exception:
        pass
    partitions = usb_partitions()
    if not partitions:
        return None

    try:
        nvme_resolved = paths.nvme_mount.resolve()
    except Exception:
        nvme_resolved = paths.nvme_mount

    trip_root = paths.trip_root()
    total_bytes, total_files = _calculate_directory_totals(trip_root)
    trip_name = trip_root.name

    for base in inserted:
        for part in partitions:
            name = part.get('name') or ''
            if not name or not name.startswith(base):
                continue
            try:
                size_bytes = int(part.get('size_bytes') or 0)
            except (TypeError, ValueError):
                size_bytes = 0
            if size_bytes < threshold:
                continue
            mountpoint = part.get('mountpoint')
            if not mountpoint:
                continue
            try:
                mp = Path(mountpoint)
            except Exception:
                continue
            try:
                if nvme_resolved and mp.resolve() == nvme_resolved:
                    continue
            except Exception:
                pass
            label_raw = part.get('label') or ''
            label = label_raw.strip() or mp.name or name.replace('/dev/', '')
            estimated_seconds = (total_bytes / DEFAULT_OFFLOAD_SPEED_BPS) if total_bytes else 0.0
            return LargeDriveInfo(
                device_base=base,
                partition=name,
                mountpoint=mp,
                label=label,
                size_bytes=size_bytes,
                total_bytes=total_bytes,
                total_files=total_files,
                estimated_seconds=estimated_seconds,
                trip_name=trip_name,
            )
    return None


def _perform_offload(
    trip_root: Path,
    dest_root: Path,
    buttons: Buttons,
    dev_mode: bool,
    total_bytes: int,
    total_files: int,
    progress_cb,
) -> OffloadResult:
    bytes_copied = 0
    files_copied = 0
    errors: List[str] = []
    cancelled = False

    cancel_state = {'last': [False, False, False, False]}

    def should_cancel() -> bool:
        if dev_mode:
            return False
        st = buttons.read()
        if st is None:
            return False
        # Ensure we copy since GPIO may return tuples reused between calls
        st_list = list(st)
        last = cancel_state['last']
        cancel = st_list[1] and not last[1]
        cancel_state['last'] = st_list
        return cancel

    if not dest_root.exists():
        dest_root.mkdir(parents=True, exist_ok=True)

    try:
        for dirpath, _, filenames in os.walk(trip_root):
            for fn in filenames:
                src = Path(dirpath) / fn
                try:
                    rel = src.relative_to(trip_root)
                except ValueError:
                    rel = Path(fn)
                dst = dest_root / rel
                dst.parent.mkdir(parents=True, exist_ok=True)

                file_bytes_written = 0
                try:
                    with src.open('rb') as fsrc, dst.open('wb') as fdst:
                        while True:
                            if should_cancel():
                                bytes_copied = max(0, bytes_copied - file_bytes_written)
                                raise OffloadCancelled
                            chunk = fsrc.read(COPY_CHUNK_SIZE)
                            if not chunk:
                                break
                            fdst.write(chunk)
                            written = len(chunk)
                            file_bytes_written += written
                            bytes_copied += written
                            progress_cb(bytes_copied, files_copied, total_bytes, total_files)
                        fdst.flush()
                        try:
                            os.fsync(fdst.fileno())
                        except OSError:
                            pass
                    shutil.copystat(src, dst, follow_symlinks=True)
                    files_copied += 1
                    progress_cb(bytes_copied, files_copied, total_bytes, total_files, force=True)
                except OffloadCancelled:
                    cancelled = True
                    try:
                        if dst.exists():
                            dst.unlink()
                    except Exception:
                        pass
                    raise
                except Exception as e:
                    bytes_copied = max(0, bytes_copied - file_bytes_written)
                    try:
                        if dst.exists():
                            dst.unlink()
                    except Exception:
                        pass
                    errors.append(f"{rel}: {e}")
                    progress_cb(bytes_copied, files_copied, total_bytes, total_files, force=True)
    except OffloadCancelled:
        cancelled = True

    return OffloadResult(files_copied=files_copied, bytes_copied=bytes_copied, cancelled=cancelled, errors=errors)


def _confirm_large_drive(disp, buttons: Buttons, dev_mode: bool, monitor: UsbDeviceMonitor, lang: str) -> bool:
    render_and_push(disp, LargeDriveConfirmScreen(disp.width, disp.height, lang))
    if dev_mode:
        return True
    import time as _t
    last = [False, False, False, False]
    while True:
        st = buttons.read() or [False, False, False, False]
        if st[0] and not last[0]:
            return True
        if (st[1] and not last[1]) or (st[3] and not last[3]):
            return False
        evt = monitor.poll()
        if evt == 'remove':
            return False
        last = st
        _t.sleep(0.05)


def _execute_large_drive_offload(
    disp,
    cfg,
    paths: Paths,
    buttons: Buttons,
    dev_mode: bool,
    lang: str,
    info: LargeDriveInfo,
) -> None:
    trip_root = paths.trip_root()
    total_bytes = info.total_bytes
    total_files = info.total_files

    if total_files <= 0 or total_bytes <= 0:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'offload.errors.no_media')))
        _wait_for_home(buttons, dev_mode)
        return

    if not info.mountpoint.exists():
        msg = tr(lang, 'offload.errors.mount_failed', name=info.label)
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, msg))
        _wait_for_home(buttons, dev_mode)
        return

    try:
        usage = psutil.disk_usage(str(info.mountpoint))
    except Exception:
        usage = None
    if usage and usage.free < total_bytes:
        msg = tr(lang, 'offload.errors.no_space', name=info.label)
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, msg))
        _wait_for_home(buttons, dev_mode)
        return

    dest_root = info.mountpoint / 'Blackbox' / 'trips' / info.trip_name
    start_time = time.monotonic()
    last_draw = [0.0]

    def progress_cb(bytes_copied: int, files_done: int, total_bytes: int, total_files: int, force: bool = False) -> None:
        now = time.monotonic()
        if not force and (now - last_draw[0]) < 0.5:
            return
        last_draw[0] = now
        fraction = (bytes_copied / total_bytes) if total_bytes > 0 else 0.0
        elapsed = max(now - start_time, 0.001)
        if bytes_copied <= 0:
            eta_seconds = info.estimated_seconds if info.total_bytes > 0 else 0.0
            speed_text = '--'
        else:
            speed = bytes_copied / elapsed
            speed_text = _format_speed(speed)
            remaining = max(total_bytes - bytes_copied, 0)
            eta_seconds = remaining / speed if speed > 1e-6 else None
        eta_text = _format_eta(eta_seconds)
        render_and_push(
            disp,
            LargeDriveProgressScreen(
                disp.width,
                disp.height,
                lang,
                info.label,
                info.trip_name,
                fraction,
                eta_text,
                speed_text,
                files_done,
                total_files,
            ),
        )

    progress_cb(0, 0, total_bytes, total_files, force=True)
    result = _perform_offload(trip_root, dest_root, buttons, dev_mode, total_bytes, total_files, progress_cb)
    progress_cb(result.bytes_copied, result.files_copied, total_bytes, total_files, force=True)

    if result.cancelled:
        render_and_push(disp, OffloadCancelledScreen(disp.width, disp.height, lang))
        _wait_for_home(buttons, dev_mode)
        return

    if result.errors:
        msg = result.errors[0]
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, msg))
        _wait_for_home(buttons, dev_mode)
        return

    render_and_push(disp, OffloadDoneScreen(disp.width, disp.height, lang, result.files_copied))
    _wait_for_home(buttons, dev_mode)


def _handle_large_drive(
    disp,
    cfg,
    paths: Paths,
    buttons: Buttons,
    dev_mode: bool,
    monitor: UsbDeviceMonitor,
    lang: str,
    info: LargeDriveInfo,
) -> None:
    estimated_minutes = 0
    if info.total_bytes > 0:
        estimated_minutes = max(1, int(math.ceil(info.estimated_seconds / 60.0))) if info.estimated_seconds > 0 else 1
    render_and_push(disp, LargeDrivePromptScreen(disp.width, disp.height, lang, info.label, estimated_minutes))

    if dev_mode:
        monitor.suppress_last_inserts()
        monitor.enter_cooldown(1.0)
        _execute_large_drive_offload(disp, cfg, paths, buttons, dev_mode, lang, info)
        return

    import time as _t
    last = [False, False, False, False]
    while True:
        st = buttons.read() or [False, False, False, False]
        if st[0] and not last[0]:
            confirmed = _confirm_large_drive(disp, buttons, dev_mode, monitor, lang)
            if confirmed:
                monitor.suppress_last_inserts()
                monitor.enter_cooldown(1.0)
                _execute_large_drive_offload(disp, cfg, paths, buttons, dev_mode, lang, info)
            else:
                monitor.suppress_last_inserts()
                monitor.enter_cooldown(1.0)
            break
        if st[1] and not last[1]:
            monitor.suppress_last_inserts()
            monitor.enter_cooldown(1.0)
            break
        if st[3] and not last[3]:
            monitor.suppress_last_inserts()
            monitor.enter_cooldown(1.0)
            break
        evt = monitor.poll()
        if evt == 'remove':
            render_and_push(disp, DeviceRemovedScreen(disp.width, disp.height, lang))
            _wait_for_home(buttons, dev_mode)
            monitor.resync()
            monitor.enter_cooldown(1.0)
            break
        last = st
        _t.sleep(0.05)


def _maybe_handle_large_drive_event(
    disp,
    cfg,
    paths: Paths,
    buttons: Buttons,
    dev_mode: bool,
    monitor: UsbDeviceMonitor,
    lang: str,
) -> bool:
    info = _detect_large_drive(paths, monitor)
    if not info:
        return False
    _handle_large_drive(disp, cfg, paths, buttons, dev_mode, monitor, lang, info)
    return True


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

    def progress_cb(progress: CopyProgress):
        total_seen['i'] = progress.index
        total_seen['total'] = max(total_seen['total'], progress.total)
        frac = progress.index / float(total_seen['total']) if total_seen['total'] else 0
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
            background_priority=bool(cfg['previews'].get('background_priority', True)),
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

    min_free = int(cfg.get('limits', {}).get('min_free_gb', 10)) * 1_000_000_000
    verify_mode = cfg['verify']['default_mode']

    last_name = {'name': ''}

    def _update_progress(fraction: float, name: str | None = None) -> None:
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

    def http_progress(done: int, total: int, fraction: float, name: str) -> None:
        _update_progress(fraction, name)

    def mtp_progress(progress: CopyProgress) -> None:
        total = progress.total
        fraction = progress.index / total if total else 0.0
        _update_progress(fraction, progress.current_path.name if progress.current_path else None)

    result = import_media_mtp(paths, verify_mode=verify_mode, progress_cb=mtp_progress)

    if result is None:
        metadata_index = MediaMetadataIndex(paths)
        link = prepare_link()
        if not link:
            render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.gopro_connect_failed')))
            _wait_for_home(buttons, dev_mode)
            return
        iface, host_ip = link
        try:
            result = import_media_http(
                paths,
                metadata_index,
                min_free,
                progress_cb=http_progress,
                host=host_ip,
            )
        finally:
            teardown_link(iface)

    if result is None:
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, tr(lang, 'errors.gopro_import_failed')))
        _wait_for_home(buttons, dev_mode)
        return

    if result.errors:
        msg: str
        first = result.errors[0]
        if isinstance(first, str) and first.startswith('low_space:'):
            parts = first.split(':')
            if len(parts) >= 4:
                try:
                    need = int(parts[1])
                    available = int(parts[2])
                    reserve = int(parts[3])
                except ValueError:
                    need = available = reserve = 0
                msg = tr(
                    lang,
                    'errors.gopro_low_space',
                    need=bytes_to_gb(need),
                    available=bytes_to_gb(available),
                    reserve=bytes_to_gb(reserve),
                )
            else:
                msg = tr(lang, 'errors.gopro_low_space', need='0gb', available='0gb', reserve='0gb')
        else:
            base = tr(lang, 'errors.gopro_import_failed')
            detail = first if isinstance(first, str) else ''
            msg = f"{base}\n{detail}" if detail else base
        extras = [err for err in result.errors[1:] if isinstance(err, str) and err]
        if extras:
            msg = "\n".join([msg, *extras])
        render_and_push(disp, ErrorScreen(disp.width, disp.height, lang, msg))
        _wait_for_home(buttons, dev_mode)
        return

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
            background_priority=bool(cfg['previews'].get('background_priority', True)),
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
    hardware_cfg = cfg.get('hardware', {})
    display_mode = (hardware_cfg.get('display') or 'epd2in7_v2').lower()

    use_mock_display = dev_mode or display_mode in {'mock', 'none', 'disabled'}

    if use_mock_display:
        disp = MockDisplay()
    else:
        disp = get_waveshare_display()
    buttons = Buttons(
        pins=hardware_cfg.get('buttons', [5, 6, 13, 19]),
        dev_mode=dev_mode,
        enabled=hardware_cfg.get('buttons_enabled', False),
    )
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
            if _maybe_handle_large_drive_event(disp, cfg, paths, buttons, dev_mode, monitor, lang):
                render_and_push(disp, HomeScreen(disp.width, disp.height, lang, selected=sel))
                continue
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
            if _maybe_handle_large_drive_event(disp, cfg, paths, buttons, dev_mode, monitor, lang):
                render_and_push(disp, HomeScreen(disp.width, disp.height, lang, selected=sel))
                continue
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
            transcription_cfg = cfg.get('transcription') or {}
            transcription_enabled = bool(transcription_cfg.get('enabled', True))
            status_text: Optional[str] = None

            def _render_info() -> None:
                media_stats = collect_trip_media_stats(cfg, paths)
                stats = {
                    'trip_name': media_stats.trip_name,
                    'video_duration': media_stats.video_duration_label,
                    'photo_count': media_stats.photo_count,
                    'free_gb': bytes_to_gb(media_stats.free_bytes),
                    'devices': media_stats.device_names,
                }
                render_and_push(
                    disp,
                    InfoScreen(
                        disp.width,
                        disp.height,
                        lang,
                        stats,
                        status=status_text,
                        show_index_action=transcription_enabled,
                    ),
                )

            if dev_mode:
                _render_info()
                _wait_for_home(buttons, dev_mode)
                continue

            last_status_token: Optional[str] = None

            def _refresh_index_status() -> None:
                nonlocal status_text, last_status_token
                state = _INDEX_NOW_STATE.get('status') or 'idle'
                if state == last_status_token:
                    return
                if state == 'idle':
                    if last_status_token and last_status_token != 'idle' and not _INDEX_NOW_STATE.get('error_code'):
                        # Keep latest status message until user leaves screen.
                        pass
                    last_status_token = 'idle'
                    return
                if state == 'running':
                    status_text = tr(lang, 'info.index_running')
                    last_status_token = 'running'
                    _render_info()
                    return
                if state == 'done':
                    status_text = tr(lang, 'info.index_done')
                    _render_info()
                    _INDEX_NOW_STATE['status'] = 'idle'
                    last_status_token = 'idle'
                    return
                if state == 'error':
                    code = _INDEX_NOW_STATE.get('error_code')
                    if code == 'missing_dependency':
                        status_text = tr(lang, 'info.index_missing_deps')
                    else:
                        status_text = tr(lang, 'info.index_failed')
                    _render_info()
                    _INDEX_NOW_STATE['status'] = 'idle'
                    last_status_token = 'idle'

            _render_info()
            import time as _t
            last_buttons = [False, False, False, False]
            while True:
                _refresh_index_status()
                st = buttons.read() or [False, False, False, False]
                if st[2] and not last_buttons[2]:
                    if not transcription_enabled:
                        status_text = tr(lang, 'info.index_disabled')
                        _render_info()
                    else:
                        existing_thread = _INDEX_NOW_STATE.get('thread')
                        if existing_thread and existing_thread.is_alive():
                            status_text = tr(lang, 'info.index_running')
                            _render_info()
                        else:
                            def _run_index_now():
                                try:
                                    worker = TranscriptionWorker(paths, TranscriptionQueue(paths), cfg)
                                    worker.run_once(ignore_window=True)
                                    _INDEX_NOW_STATE['status'] = 'done'
                                    _INDEX_NOW_STATE['error_code'] = None
                                    _INDEX_NOW_STATE['error_detail'] = None
                                except MissingDependencyError:
                                    _INDEX_NOW_STATE['status'] = 'error'
                                    _INDEX_NOW_STATE['error_code'] = 'missing_dependency'
                                    _INDEX_NOW_STATE['error_detail'] = None
                                except Exception as exc:
                                    _INDEX_NOW_STATE['status'] = 'error'
                                    _INDEX_NOW_STATE['error_code'] = 'error'
                                    _INDEX_NOW_STATE['error_detail'] = str(exc)
                                finally:
                                    _INDEX_NOW_STATE['thread'] = None

                            status_text = tr(lang, 'info.index_started')
                            _INDEX_NOW_STATE['status'] = 'running'
                            _INDEX_NOW_STATE['error_code'] = None
                            _INDEX_NOW_STATE['error_detail'] = None
                            thread = threading.Thread(target=_run_index_now, daemon=True)
                            _INDEX_NOW_STATE['thread'] = thread
                            _render_info()
                            thread.start()
                if st[3] and not last_buttons[3]:
                    break
                last_buttons = st
                _t.sleep(0.05)

        elif sel == 3:
            # Settings flow returns to Home on confirm Yes/No; if canceled, stays in Settings
            run_settings_flow(disp, cfg, buttons, dev_mode)


if __name__ == '__main__':
    # Default to real hardware if available; set BLACKBOX_DEV=1 to force mock mode.
    import os
    dev = os.environ.get('BLACKBOX_DEV') == '1'
    run(dev_mode=dev)
