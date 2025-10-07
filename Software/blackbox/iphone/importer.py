from __future__ import annotations

import os
import subprocess
import logging
from pathlib import Path
from shutil import which
from typing import Callable, Optional

from ..backup.backup import CopyProgress, CopyResult, copy_from_source, VIDEO_EXTS
from ..paths import Paths


Callback = Optional[Callable[[CopyProgress], None]]

_IFUSE = which('ifuse')
_IDEVICEPAIR = which('idevicepair')
_FUSERMOUNT = which('fusermount')
_FUSERMOUNT3 = which('fusermount3')
_UMOUNT = which('umount')
_FUSE_STATIC = which('fusermount-static')


_LOG = logging.getLogger(__name__)


class IphoneImportError(Exception):
    def __init__(self, code: str, detail: str | None = None):
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


def _is_mounted(path: Path) -> bool:
    try:
        return path.exists() and os.path.ismount(path)
    except OSError:
        return False


def _unmount(path: Path) -> bool:
    if not path.exists() or not _is_mounted(path):
        return True
    commands = []
    for cmd in (_FUSERMOUNT, _FUSERMOUNT3, _FUSE_STATIC, _UMOUNT):
        if cmd is None:
            continue
        if 'fusermount' in cmd:
            commands.append([cmd, '-u', str(path)])
        else:
            commands.append([cmd, str(path)])
    # Lazy/force unmount fallbacks
    if _UMOUNT:
        commands.append([_UMOUNT, '-l', str(path)])
    if _FUSERMOUNT:
        commands.append([_FUSERMOUNT, '-u', '-z', str(path)])
    last_error: Optional[Exception] = None
    for command in commands:
        try:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=6.0)
            if not _is_mounted(path):
                return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:  # pragma: no cover
            last_error = exc
    if _is_mounted(path):
        _LOG.warning('Failed to unmount %s: %s', path, last_error)
        return False
    return True


def _prepare_mountpoint(path: Path) -> None:
    if path.exists() and _is_mounted(path):
        if not _unmount(path):
            _LOG.warning('Reusing existing ifuse mount at %s (previous unmount failed)', path)
            return
    path.mkdir(parents=True, exist_ok=True)


def _try_pair_device() -> bool:
    if not _IDEVICEPAIR:
        return False
    try:
        subprocess.run(
            [_IDEVICEPAIR, 'pair'],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=12.0,
        )
        return True
    except subprocess.SubprocessError:
        return False


def _mount_plain(path: Path, *, tried_pair: bool, detail: str | None = None) -> None:
    if _IFUSE is None:
        raise IphoneImportError('tools_missing')
    try:
        subprocess.run(
            [_IFUSE, str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15.0,
        )
    except subprocess.CalledProcessError as exc:
        combined = ((exc.stderr or '') + '\n' + (exc.stdout or '')).strip()
        lower = combined.lower()
        needs_pair = any(token in lower for token in ('unlock', 'trust', 'pair', 'paired'))
        if needs_pair and not tried_pair and _try_pair_device():
            _mount_plain(path, tried_pair=True, detail=combined)
            return
        if needs_pair:
            raise IphoneImportError('pairing_required', combined or detail) from exc
        if 'no device' in lower or 'not found' in lower:
            raise IphoneImportError('device_not_found', combined or detail) from exc
        raise IphoneImportError('mount_failed', detail or combined or None) from exc
    except subprocess.TimeoutExpired as exc:  # pragma: no cover
        raise IphoneImportError('mount_failed', 'timeout') from exc


def _mount_documents(path: Path, *, tried_pair: bool, detail: str | None = None) -> None:
    args = [_IFUSE, str(path), '--documents', 'com.apple.mobileslideshow']
    try:
        subprocess.run(
            args,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15.0,
        )
    except subprocess.CalledProcessError as exc:
        combined = ((exc.stderr or '') + '\n' + (exc.stdout or '')).strip()
        lower = combined.lower()
        needs_pair = any(token in lower for token in ('unlock', 'trust', 'pair', 'paired'))
        if needs_pair and not tried_pair and _try_pair_device():
            _mount_documents(path, tried_pair=True, detail=combined)
            return
        if 'installationlookupfailed' in lower or 'not present on the device' in lower:
            _mount_plain(path, tried_pair=tried_pair, detail=combined)
            return
        if needs_pair:
            raise IphoneImportError('pairing_required', combined or detail) from exc
        raise IphoneImportError('mount_failed', detail or combined or None) from exc
    except subprocess.TimeoutExpired as exc:  # pragma: no cover
        raise IphoneImportError('mount_failed', 'timeout') from exc


def _mount_camera(path: Path, *, tried_pair: bool = False, allow_fallback: bool = True) -> None:
    if _IFUSE is None:
        raise IphoneImportError('tools_missing')
    _prepare_mountpoint(path)
    try:
        subprocess.run(
            [_IFUSE, str(path), '--camera'],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15.0,
        )
    except FileNotFoundError as exc:  # pragma: no cover
        raise IphoneImportError('tools_missing') from exc
    except subprocess.CalledProcessError as exc:
        combined = ((exc.stderr or '') + '\n' + (exc.stdout or '')).strip()
        lower = combined.lower()
        needs_pair = any(token in lower for token in ('unlock', 'trust', 'pair', 'paired'))
        if needs_pair and not tried_pair and _try_pair_device():
            _mount_camera(path, tried_pair=True, allow_fallback=allow_fallback)
            return
        if 'unknown option' in lower and '--camera' in lower and allow_fallback:
            _mount_documents(path, tried_pair=tried_pair, detail=combined)
            return
        if 'installationlookupfailed' in lower and allow_fallback:
            _mount_plain(path, tried_pair=tried_pair, detail=combined)
            return
        if needs_pair:
            raise IphoneImportError('pairing_required', combined or None) from exc
        if 'no device' in lower or 'not found' in lower:
            raise IphoneImportError('device_not_found', combined or None) from exc
        raise IphoneImportError('mount_failed', combined or None) from exc
    except subprocess.TimeoutExpired as exc:  # pragma: no cover
        raise IphoneImportError('mount_failed', 'timeout') from exc


def import_videos_from_iphone(
    paths: Paths,
    *,
    verify_mode: str,
    progress_cb: Callback = None,
    min_timestamp: Optional[float] = None,
) -> CopyResult:
    mount_point = Path('/tmp/blackbox_ifuse')

    _try_pair_device()
    _mount_camera(mount_point)
    try:
        return copy_from_source(
            mount_point,
            paths,
            verify_mode=verify_mode,
            progress_cb=progress_cb,
            allowed_exts=VIDEO_EXTS,
            min_timestamp=min_timestamp,
            device_label_override='iPhone',
        )
    finally:
        if not _unmount(mount_point):
            _LOG.warning('iPhone mount %s could not be cleanly unmounted; continued anyway', mount_point)

        try:
            mount_point.rmdir()
        except OSError:
            pass
