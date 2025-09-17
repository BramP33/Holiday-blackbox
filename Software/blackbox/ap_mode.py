from __future__ import annotations
import subprocess
from .config import load_config
import shutil
import re


def start_ap() -> int:
    cfg = load_config()
    ssid = cfg['ap']['ssid']
    pwd = cfg['ap']['password']
    # Validate WPA2 PSK length (8..63)
    if not isinstance(pwd, str) or len(pwd) < 8 or len(pwd) > 63:
        return 400  # invalid password
    # Ensure nmcli exists
    if not shutil.which('nmcli'):
        return 127
    # If already active, treat as success
    try:
        out = subprocess.check_output(['nmcli', '-t', '-f', 'NAME', 'con', 'show', '--active'], text=True)
        if any(line.strip() == 'Hotspot' for line in out.splitlines()):
            return 0
    except Exception:
        pass
    # Prefer NetworkManager hotspot (Bookworm default)
    cmd = ['nmcli', 'dev', 'wifi', 'hotspot', 'ifname', 'wlan0', 'ssid', ssid, 'password', pwd]
    p = subprocess.run(cmd, capture_output=True, text=True)
    rc = p.returncode
    if rc != 0:
        out = f"{p.stdout}\n{p.stderr}".lower()
        if 'not authorized' in out or 'not authorised' in out:
            return 401  # auth error
        if 'not valid wpa psk' in out or 'invalid password' in out:
            return 400  # invalid password
        # Try cleaning up and retry once
        try:
            subprocess.call(['nmcli', 'con', 'down', 'Hotspot'])
            subprocess.call(['nmcli', 'con', 'delete', 'Hotspot'])
        except Exception:
            pass
        p = subprocess.run(cmd, capture_output=True, text=True)
        rc = p.returncode
        if rc != 0:
            out = f"{p.stdout}\n{p.stderr}".lower()
            if 'not authorized' in out or 'not authorised' in out:
                return 401
            if 'not valid wpa psk' in out or 'invalid password' in out:
                return 400
    return rc


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
