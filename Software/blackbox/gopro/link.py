from __future__ import annotations

import shutil
import subprocess
import time
from pathlib import Path
from typing import List, Optional, Tuple

from . import GOPRO_VENDOR_ID, GOPRO_PRODUCT_IDS

INTERFACE_ROOT = Path('/sys/class/net')
DEFAULT_HOST_CANDIDATES: Tuple[str, ...] = ('172.23.0.51', '10.5.5.9')


def _read_text(p: Path) -> Optional[str]:
    try:
        return p.read_text().strip()
    except Exception:
        return None


def _norm_usb_id(v: Optional[str]) -> str:
    if not v:
        return ''
    v = v.strip().lower()
    return v[2:] if v.startswith('0x') else v


def _serial_suffix_for(dev: Path) -> Optional[str]:
    """Return the last three numeric characters of a USB device serial if available."""
    try:
        resolved = dev.resolve()
    except Exception:
        resolved = dev
    checked: set[Path] = set()

    def _read_serial(candidate: Path) -> Optional[str]:
        if candidate in checked:
            return None
        checked.add(candidate)
        try:
            text = candidate.read_text().strip()
        except Exception:
            return None
        digits = ''.join(ch for ch in text if ch.isdigit())
        if len(digits) >= 3:
            return digits[-3:]
        return None

    cur = resolved
    for _ in range(8):
        cand = cur / 'serial'
        if cand.exists():
            suffix = _read_serial(cand)
            if suffix:
                return suffix
        cand = cur / 'iSerial'
        if cand.exists():
            suffix = _read_serial(cand)
            if suffix:
                return suffix
        if cur == cur.parent:
            break
        cur = cur.parent

    try:
        for depth, cand in enumerate(resolved.glob('**/serial')):
            if depth > 200:  # guard against runaway globbing on unusual systems
                break
            suffix = _read_serial(cand)
            if suffix:
                return suffix
    except Exception:
        pass
    return None


def _host_from_suffix(suffix: str) -> Optional[str]:
    digits = ''.join(ch for ch in suffix if ch.isdigit())
    if len(digits) < 3:
        return None
    xyz = digits[-3:]
    try:
        second = 20 + int(xyz[0])
        third = 100 + int(xyz[1:])
    except ValueError:
        return None
    return f'172.{second}.{third}.51'


def _collect_host_candidates(dev: Path) -> List[str]:
    candidates: List[str] = []
    suffix = _serial_suffix_for(dev)
    if suffix:
        host = _host_from_suffix(suffix)
        if host:
            candidates.append(host)
    candidates.extend(DEFAULT_HOST_CANDIDATES)
    return candidates


def find_interface() -> Optional[tuple[str, List[str]]]:
    if not INTERFACE_ROOT.exists():
        return None
    for iface in INTERFACE_ROOT.iterdir():
        if not iface.is_dir():
            continue
        dev = iface / 'device'
        if not dev.exists():
            continue
        vid = _norm_usb_id(_read_text(dev / 'idVendor'))
        pid = _norm_usb_id(_read_text(dev / 'idProduct'))
        if vid == GOPRO_VENDOR_ID and pid in GOPRO_PRODUCT_IDS:
            return iface.name, _collect_host_candidates(dev)
    # Fallback: common name 'usb0'
    usb0 = INTERFACE_ROOT / 'usb0'
    if usb0.exists():
        return 'usb0', _collect_host_candidates(usb0 / 'device')
    return None


def _run(cmd: list[str]) -> int:
    try:
        return subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        return 1


def bring_up(iface: str) -> bool:
    return _run(['ip', 'link', 'set', iface, 'up']) == 0


def _has_cmd(name: str) -> bool:
    return shutil.which(name) is not None


def dhcp(iface: str, timeout: float = 8.0) -> bool:
    if not _has_cmd('dhclient'):
        return False
    pidfile = f'/tmp/blackbox-dhclient-{iface}.pid'
    leasefile = f'/tmp/blackbox-dhclient-{iface}.lease'
    try:
        proc = subprocess.Popen(['dhclient', '-1', '-pf', pidfile, '-lf', leasefile, iface], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        return False
    start = time.monotonic()
    while time.monotonic() - start <= timeout:
        if proc.poll() is not None:
            return proc.returncode == 0
        time.sleep(0.2)
    try:
        proc.terminate(); proc.wait(timeout=1.0)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    return False


def _network_from_host(host: str) -> Optional[str]:
    parts = host.split('.')
    if len(parts) != 4:
        return None
    return '.'.join(parts[:3])


def assign_static(iface: str, host: Optional[str] = None) -> bool:
    _run(['ip', 'addr', 'flush', 'dev', iface])
    target_host = host or DEFAULT_HOST_CANDIDATES[0]
    network = _network_from_host(target_host)
    local_ip = f'{network}.2' if network else '172.23.0.2'
    cidr = f'{local_ip}/24'
    if _run(['ip', 'addr', 'add', cidr, 'dev', iface]) != 0:
        return False
    # Ensure host route exists
    _run(['ip', 'route', 'replace', target_host, 'dev', iface])
    return True


def reachable(host: str, timeout: float = 3.0) -> bool:
    import urllib.request
    url = f'http://{host}:8080/gopro/camera/state'
    start = time.monotonic()
    while time.monotonic() - start <= timeout:
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(0.3)
    return False


def _local_ipv4_for(iface: str) -> Optional[str]:
    try:
        out = subprocess.check_output(['ip', '-4', 'addr', 'show', iface], text=True)
    except Exception:
        return None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('inet '):
            try:
                addr = line.split()[1].split('/')[0]
                return addr
            except Exception:
                return None
    return None


def _derive_host_from_local(ip: str) -> Optional[str]:
    parts = ip.split('.')
    if len(parts) != 4:
        return None
    # GoPro typically uses .51 on the same /24
    return '.'.join(parts[:3] + ['51'])


def _enable_wired_usb(host: str) -> None:
    import urllib.request

    try:
        urllib.request.urlopen(
            f'http://{host}:8080/gopro/camera/control/wired_usb?p=1',
            timeout=1.0,
        ).read()
    except Exception:
        pass


def prepare_link() -> Optional[tuple[str, str]]:
    """Bring up the GoPro USB network and return (iface, host_ip)."""
    found = find_interface()
    if not found:
        return None
    iface, host_candidates = found
    bring_up(iface)
    # Try DHCP; if not, assign static in the common subnet 172.23.0.0/24
    if not dhcp(iface):
        for candidate in host_candidates:
            if assign_static(iface, candidate):
                break
    # Determine host based on local address
    local_ip = _local_ipv4_for(iface)
    preferred: List[str] = []
    if local_ip:
        cand = _derive_host_from_local(local_ip)
        if cand:
            preferred.append(cand)
    for cand in host_candidates:
        if cand not in preferred:
            preferred.append(cand)

    for cand in preferred:
        _enable_wired_usb(cand)
        if reachable(cand):
            return iface, cand

    if preferred:
        _enable_wired_usb(preferred[0])
        return iface, preferred[0]
    return None


def teardown_link(iface: str) -> None:
    if _has_cmd('dhclient'):
        pidfile = f'/tmp/blackbox-dhclient-{iface}.pid'
        try:
            subprocess.run(['dhclient', '-r', '-pf', pidfile, iface], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    _run(['ip', 'addr', 'flush', 'dev', iface])
