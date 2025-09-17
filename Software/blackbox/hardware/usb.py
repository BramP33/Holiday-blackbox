from __future__ import annotations
import json
import subprocess
import re
from typing import Set, List, Dict
import time as _t
import os
from pathlib import Path

from ..gopro.network import gopro_present

try:
    from shutil import which as _which
except Exception:  # pragma: no cover
    _which = lambda x: None


_USB_BASE_RE = re.compile(r"^/dev/sd[a-z]+$")


def _lsblk_usb_bases() -> Set[str]:
    """Return set of base USB disk devices using lsblk -S JSON.

    Filters to TYPE=disk and TRAN=usb, returns like '/dev/sda'.
    """
    bases: Set[str] = set()
    try:
        out = subprocess.check_output(['lsblk', '-S', '-J', '-o', 'NAME,TYPE,TRAN'], text=True)
        data = json.loads(out)
        for dev in data.get('blockdevices', []) or []:
            if (dev.get('tran') or '').lower() == 'usb' and (dev.get('type') or '').lower() == 'disk':
                name = dev.get('name')
                if name:
                    bases.add(f"/dev/{name}")
    except Exception:
        # Fallback to text parsing
        try:
            out = subprocess.check_output(['lsblk', '-S', '-o', 'NAME,TYPE,TRAN'], text=True)
            for line in out.splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 3:
                    name, typ, tran = parts[0], parts[1].lower(), parts[2].lower()
                    if tran == 'usb' and typ == 'disk':
                        bases.add(f"/dev/{name}")
        except Exception:
            pass
    return bases


def current_usb_bases() -> Set[str]:
    return _lsblk_usb_bases()


class UsbDeviceMonitor:
    """Poll-based USB device monitor.

    Tracks mounted USB storage devices (/dev/sdX) and emits insert/remove events.
    Maintains a suppression set so dismissed devices won't re-trigger until removed.
    """

    def __init__(self):
        self.last_devices: Set[str] = current_usb_bases()
        self.suppressed: Set[str] = set()
        self.last_inserted: Set[str] = set()
        self.last_removed: Set[str] = set()
        self.cooldown_until: float = 0.0
        self.last_gopro: bool = gopro_present(force_refresh=True)
        self.gopro_suppressed: bool = False

    def poll(self) -> str | None:
        """Poll for changes. Returns 'insert', 'remove' or None.

        - On insert: considers only devices not in suppressed.
        - On remove: also clears removed devices from suppressed.
        Stores details in last_inserted/last_removed for consumers.
        """
        now = _t.monotonic()
        cur = current_usb_bases()
        inserted = {d for d in cur if d not in self.last_devices}
        removed = {d for d in self.last_devices if d not in cur}
        self.last_devices = cur
        self.last_inserted = inserted
        self.last_removed = removed

        # Always clear suppression for removed devices even during cooldown
        if removed:
            self.suppressed -= removed

        gopro_now = gopro_present(force_refresh=self.last_gopro)
        gopro_inserted = gopro_now and not self.last_gopro
        gopro_removed = (not gopro_now) and self.last_gopro
        self.last_gopro = gopro_now
        if gopro_removed:
            self.gopro_suppressed = False

        if now < self.cooldown_until:
            # Allow removal notifications (including GoPro) during cooldown
            if gopro_removed:
                return 'gopro_remove'
            if removed:
                return 'remove'
            return None

        effective_inserts = inserted - self.suppressed
        if effective_inserts:
            return 'insert'
        if gopro_inserted and not self.gopro_suppressed:
            return 'gopro_insert'
        if gopro_removed:
            return 'gopro_remove'
        if removed:
            return 'remove'
        return None

    def suppress_last_inserts(self) -> None:
        """Suppress currently inserted devices from re-triggering until removal."""
        self.suppressed |= self.last_inserted

    def suppress_gopro(self) -> None:
        self.gopro_suppressed = True

    def enter_cooldown(self, seconds: float = 1.0) -> None:
        self.cooldown_until = max(self.cooldown_until, _t.monotonic() + seconds)

    def resync(self) -> None:
        """Reset baseline to current state and clear transient event sets."""
        self.last_devices = current_usb_bases()
        self.last_inserted = set()
        self.last_removed = set()
        self.last_gopro = gopro_present(force_refresh=True)
        if not self.last_gopro:
            self.gopro_suppressed = False


def _lsblk_tree() -> Dict:
    try:
        out = subprocess.check_output(['lsblk', '-J', '-o', 'NAME,TYPE,TRAN,MOUNTPOINT,FSTYPE,LABEL'], text=True)
        return json.loads(out)
    except Exception:
        return {}


def usb_partitions() -> List[Dict]:
    """Return list of USB partitions with metadata.

    Each item: { 'name': '/dev/sda1', 'mountpoint': '/media/pi/XYZ' or None,
                 'fstype': 'exfat', 'label': 'GOPRO' }
    """
    data = _lsblk_tree()
    parts: List[Dict] = []

    def _collect(dev: Dict, is_usb: bool = False):
        cur_is_usb = is_usb or (dev.get('tran') or '').lower() == 'usb'
        typ = (dev.get('type') or '').lower()
        name = dev.get('name')
        if cur_is_usb and typ == 'part' and name:
            parts.append({
                'name': f"/dev/{name}",
                'mountpoint': dev.get('mountpoint'),
                'fstype': dev.get('fstype'),
                'label': dev.get('label'),
            })
        for ch in (dev.get('children') or []):
            _collect(ch, cur_is_usb)

    for d in (data.get('blockdevices') or []):
        _collect(d, False)
    return parts


def ensure_usb_mounted(base_dir: Path | None = None, readonly: bool = True) -> List[Path]:
    """Ensure USB partitions are mounted; return list of mountpoints.

    Strategy:
      1) If udisksctl is available, run `udisksctl mount -b /dev/XXX`.
      2) Else, if running as root, mkdir -p /media/blackbox/<label|dev> and mount there.
    """
    base = base_dir or Path('/media/blackbox')
    mounted: List[Path] = []
    parts = usb_partitions()
    # First collect already mounted
    for p in parts:
        mp = p.get('mountpoint')
        if mp:
            try:
                mounted.append(Path(mp))
            except Exception:
                pass

    # Then mount the rest
    need_mount = [p for p in parts if not p.get('mountpoint')]
    if not need_mount:
        return mounted

    has_udisks = _which('udisksctl') is not None
    for p in need_mount:
        dev = p['name']
        if has_udisks:
            try:
                rc = subprocess.call(['udisksctl', 'mount', '-b', dev], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if rc == 0:
                    # Refresh mount info for this partition
                    for pp in usb_partitions():
                        if pp['name'] == dev and pp.get('mountpoint'):
                            mounted.append(Path(pp['mountpoint']))
                            break
                    continue
            except Exception:
                pass
        # Fallback to direct mount if root
        try:
            if os.geteuid() != 0:
                continue
        except Exception:
            # assume not root
            continue
        label = p.get('label') or Path(dev).name
        target = base / label
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.mkdir(parents=True, exist_ok=True)
        except Exception:
            continue
        opts = 'ro,nosuid,nodev,noexec' if readonly else 'rw,nosuid,nodev'
        try:
            rc = subprocess.call(['mount', '-o', opts, dev, str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if rc == 0:
                mounted.append(target)
        except Exception:
            continue
    return mounted
