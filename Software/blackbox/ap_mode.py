from __future__ import annotations
import subprocess
from .config import load_config
import re


def start_ap() -> int:
    cfg = load_config()
    ssid = cfg['ap']['ssid']
    pwd = cfg['ap']['password']
    # Prefer NetworkManager hotspot (Bookworm default)
    cmd = ['nmcli', 'dev', 'wifi', 'hotspot', 'ifname', 'wlan0', 'ssid', ssid, 'password', pwd]
    return subprocess.call(cmd)


def stop_ap() -> int:
    # Stop hotspot by deleting the connection named 'Hotspot' if exists
    try:
        subprocess.call(['nmcli', 'con', 'down', 'Hotspot'])
        subprocess.call(['nmcli', 'con', 'delete', 'Hotspot'])
    except Exception:
        pass
    return 0


def get_ap_address() -> str:
    """Return a usable URL for the AP web server.

    Prefer mDNS hostname, else wlan0 IPv4.
    """
    # Try mDNS
    try:
        host = 'http://blackbox.local:8080'
    except Exception:
        host = None
    # Try interface IP
    try:
        out = subprocess.check_output(['ip', '-4', 'addr', 'show', 'wlan0'], text=True)
        m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", out)
        if m:
            return f"http://{m.group(1)}:8080"
    except Exception:
        pass
    return host or 'http://10.42.0.1:8080'
