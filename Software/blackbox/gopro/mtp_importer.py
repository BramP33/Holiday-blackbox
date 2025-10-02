from __future__ import annotations

import logging
import os
import shutil
import subprocess
from pathlib import Path
from typing import Callable, Optional

from ..backup.backup import copy_from_source
from ..paths import Paths
from .http_importer import HttpImportResult


logger = logging.getLogger(__name__)

_SIMPLE_MTPFS = shutil.which('simple-mtpfs')
_FUSERMOUNT = shutil.which('fusermount')
_FUSERMOUNT3 = shutil.which('fusermount3')
_UMOUNT = shutil.which('umount')


def _is_mounted(path: Path) -> bool:
    try:
        return path.exists() and os.path.ismount(path)
    except OSError:
        return False


def _unmount(path: Path) -> None:
    if not path.exists() or not _is_mounted(path):
        return
    commands: list[list[str]] = []
    for cmd in (_FUSERMOUNT, _FUSERMOUNT3, _UMOUNT):
        if not cmd:
            continue
        if 'fusermount' in cmd:
            commands.append([cmd, '-u', '-z', str(path)])
        else:
            commands.append([cmd, str(path)])
    # Fallback lazy unmounts
    if _UMOUNT:
        commands.append([_UMOUNT, '-l', str(path)])
    last_error: Optional[Exception] = None
    for command in commands:
        try:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=6.0)
            if not _is_mounted(path):
                return
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            last_error = exc
    if _is_mounted(path):
        logger.warning('Failed to unmount %s: %s', path, last_error)


def _prepare_mountpoint(path: Path) -> bool:
    if path.exists() and _is_mounted(path):
        _unmount(path)
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.warning('Unable to create GoPro MTP mountpoint %s: %s', path, exc)
        return False
    return True


def _list_simple_mtpfs_devices() -> list[tuple[int, str]]:
    if not _SIMPLE_MTPFS:
        return []
    try:
        out = subprocess.check_output([_SIMPLE_MTPFS, '-l'], text=True, timeout=6.0)
    except subprocess.SubprocessError:
        return []
    devices: list[tuple[int, str]] = []
    for line in out.splitlines():
        line = line.strip()
        if not line or ':' not in line:
            continue
        if line.lower().startswith('available'):
            continue
        idx_part, label = line.split(':', 1)
        idx_part = idx_part.strip()
        label = label.strip()
        if not idx_part.isdigit():
            continue
        devices.append((int(idx_part), label))
    return devices


def _pick_gopro_device() -> Optional[int]:
    devices = _list_simple_mtpfs_devices()
    if not devices:
        return None
    for idx, label in devices:
        if 'gopro' in label.lower():
            return idx
    if len(devices) == 1:
        return devices[0][0]
    return None


def import_media_mtp(
    paths: Paths,
    *,
    verify_mode: str,
    progress_cb: Optional[Callable[[int, int], None]] = None,
) -> Optional[HttpImportResult]:
    """Return HttpImportResult if MTP import was performed, else None to allow fallback."""

    if not _SIMPLE_MTPFS:
        return None

    device_idx = _pick_gopro_device()
    if device_idx is None:
        return None

    mount_point = Path('/tmp/blackbox_gopro_mtp')
    if not _prepare_mountpoint(mount_point):
        return None

    mount_cmd = [_SIMPLE_MTPFS, '--device', str(device_idx), str(mount_point)]
    try:
        subprocess.run(
            mount_cmd,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20.0,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or '').strip()
        logger.warning('simple-mtpfs mount failed: %s', stderr or exc)
        return None
    except subprocess.TimeoutExpired:
        logger.warning('simple-mtpfs mount timed out')
        return None

    try:
        copy_result = copy_from_source(
            mount_point,
            paths,
            verify_mode=verify_mode,
            progress_cb=progress_cb,
            device_label_override='gopro',
        )
    except Exception as exc:  # pragma: no cover
        logger.exception('GoPro MTP import failed')
        return HttpImportResult(0, 0, [f'mtp_copy_failed: {exc}'], 0)
    finally:
        _unmount(mount_point)

    total_files = copy_result.copied_files + copy_result.skipped_files + copy_result.replaced_files
    downloaded = copy_result.copied_files + copy_result.replaced_files
    return HttpImportResult(downloaded, copy_result.skipped_files, copy_result.errors, total_files)

