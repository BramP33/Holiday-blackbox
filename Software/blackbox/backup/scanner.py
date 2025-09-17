from __future__ import annotations
from pathlib import Path
from typing import Iterable, Optional
import os
import subprocess
import json


DCIM_NAMES = {"DCIM", "dcim"}
MEDIA_EXTS = {'.jpg', '.jpeg', '.png', '.rw2', '.cr2', '.nef', '.raf', '.dng', '.arw', '.mp4', '.mov', '.m4v'}


def iter_mounts(source_roots: Iterable[str]) -> Iterable[Path]:
    """Iterate likely mount points under common roots.

    - /Volumes/* (macOS): one level deep
    - /mnt/*: one level deep
    - /media/<user>/* and /run/media/<user>/* (Linux desktops): two levels
    """
    for root in source_roots:
        p = Path(root)
        if not p.exists():
            continue
        try:
            for child in p.iterdir():
                if not child.is_dir():
                    continue
                # Typical Linux automount path: /media/<user>/<LABEL> or /run/media/<user>/<LABEL>
                # If the root folder itself ends with 'media', handle both patterns:
                #   - /media/<user>/<LABEL>
                #   - /media/<LABEL>
                if p.name == 'media':
                    yielded = False
                    # First yield grandchildren like /media/<user>/<LABEL>
                    try:
                        for grand in child.iterdir():
                            if grand.is_dir():
                                yield grand
                                yielded = True
                    except Exception:
                        pass
                    # If child itself is a mountpoint or we didn't yield any grandchildren,
                    # also consider child as a candidate (covers /media/<LABEL>).
                    try:
                        if os.path.ismount(child) or not yielded:
                            yield child
                    except Exception:
                        pass
                else:
                    # Straight one-level mounts (e.g., /Volumes/*, /mnt/*)
                    yield child
        except Exception:
            continue


def find_dcim_mounts(source_roots: Iterable[str]) -> list[Path]:
    matches: list[Path] = []
    for m in iter_mounts(source_roots):
        for dn in DCIM_NAMES:
            dcim = m / dn
            if dcim.exists() and dcim.is_dir():
                matches.append(m)
                break
    return matches

def find_first_dcim(source_roots: Iterable[str]) -> Optional[Path]:
    matches = find_dcim_mounts(source_roots)
    return matches[0] if matches else None


def _has_media_quick(root: Path, max_files: int = 20000) -> bool:
    """Return True if any file under root looks like a photo/video.

    Limits work by stopping after max_files entries.
    """
    seen = 0
    for dirpath, _, files in os.walk(root):
        for fn in files:
            seen += 1
            if seen > max_files:
                return False
            if Path(fn).suffix.lower() in MEDIA_EXTS:
                return True
    return False


def find_source_mounts(source_roots: Iterable[str]) -> list[Path]:
    """Find candidate source mounts.

    Priority:
    1) Mounts with a DCIM folder
    2) If none, and exactly one mount exists, use it
    3) Else, mounts that contain media files (quick heuristic)
    """
    mounts = list(iter_mounts(source_roots))
    def _has_dcim(path: Path) -> bool:
        for dn in DCIM_NAMES:
            try:
                if (path / dn).is_dir():
                    return True
            except PermissionError:
                continue
            except OSError:
                continue
        return False

    dcims = [m for m in mounts if _has_dcim(m)]
    if dcims:
        return dcims
    if len(mounts) == 1:
        return mounts
    matches: list[Path] = []
    for m in mounts:
        try:
            if _has_media_quick(m):
                matches.append(m)
        except Exception:
            continue
    if matches:
        return matches

    # Fallback: query lsblk for mounted partitions belonging to USB disks.
    # This helps when automounts live outside of the typical roots we scan.
    try:
        out = subprocess.check_output(['lsblk', '-J', '-o', 'NAME,TYPE,TRAN,MOUNTPOINT'], text=True)
        data = json.loads(out)
    except Exception:
        data = {}

    usb_mounts: list[Path] = []

    def _collect_mounts(dev: dict, is_usb: bool = False):
        cur_is_usb = is_usb or (dev.get('tran') or '').lower() == 'usb'
        mp = dev.get('mountpoint')
        if mp and cur_is_usb:
            try:
                usb_mounts.append(Path(mp))
            except Exception:
                pass
        for ch in (dev.get('children') or []):
            _collect_mounts(ch, cur_is_usb)

    for d in (data.get('blockdevices') or []):
        _collect_mounts(d, False)

    # De-duplicate while preserving order
    seen = set()
    usb_mounts = [m for m in usb_mounts if not (str(m) in seen or seen.add(str(m)))]

    # Apply the same DCIM/media priority on these mountpoints
    dcims = [m for m in usb_mounts if any((m / dn).is_dir() for dn in DCIM_NAMES)]
    if dcims:
        return dcims
    medias = [m for m in usb_mounts if _has_media_quick(m)]
    return medias


def classify_device_code(root: Path) -> str:
    """Return a device code: gopro|drone|360|lumix_g7|camera"""
    name = root.name.lower()
    if 'gopro' in name:
        return 'gopro'
    # DJI
    if (root / 'DCIM' / '100MEDIA').exists() or 'dji' in name:
        return 'drone'
    # 360
    if any(s in name for s in ('360', 'max', 'fusion')):
        return '360'
    # Lumix G7 hints
    if any(s in name for s in ('lumix', 'panasonic', 'g7')):
        return 'lumix_g7'
    return 'camera'
