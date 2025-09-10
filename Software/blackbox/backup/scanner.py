from __future__ import annotations
from pathlib import Path
from typing import Iterable, Optional
import os


DCIM_NAMES = {"DCIM", "dcim"}


def iter_mounts(source_roots: Iterable[str]) -> Iterable[Path]:
    for root in source_roots:
        p = Path(root)
        if not p.exists():
            continue
        # one level deep is enough for typical /media/$USER/* or /Volumes/*
        for child in p.iterdir():
            try:
                if child.is_dir():
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
