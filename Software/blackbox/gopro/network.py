from __future__ import annotations

import socket
import subprocess
import time
from typing import Iterable

from . import GOPRO_VENDOR_ID, GOPRO_PRODUCT_IDS
from .link import DEFAULT_HOST_CANDIDATES, find_interface

_PRESENT_CACHE_TTL = 0.3
_NETWORK_CACHE_TTL = 5.0
_NETWORK_TIMEOUT = 0.2

_last_present_check: float = 0.0
_last_present_result: bool = False
_last_network_check: float = 0.0
_last_network_result: bool = False


def _present_via_lsusb() -> bool:
    try:
        out = subprocess.check_output(['lsusb'], text=True)
    except Exception:
        return False
    for line in out.splitlines():
        parts = line.split()
        for idx, part in enumerate(parts):
            if part.lower() == 'id' and idx + 1 < len(parts):
                vid_pid = parts[idx + 1].lower().split(':')
                if len(vid_pid) == 2:
                    vid = vid_pid[0].lstrip('0x')
                    pid = vid_pid[1].lstrip('0x')
                    if vid == GOPRO_VENDOR_ID and pid in GOPRO_PRODUCT_IDS:
                        return True
    return False


def _reachable_hosts(candidates: Iterable[str], timeout: float = 0.4) -> bool:
    for host in candidates:
        try:
            with socket.create_connection((host, 8080), timeout=timeout):
                return True
        except OSError:
            continue
    return False


def _reachable_hosts_cached(candidates: Iterable[str], *, force_refresh: bool = False) -> bool:
    global _last_network_check, _last_network_result
    now = time.monotonic()
    cache_ttl = _PRESENT_CACHE_TTL if _last_network_result else _NETWORK_CACHE_TTL
    if not force_refresh and (now - _last_network_check) <= cache_ttl:
        return _last_network_result
    result = _reachable_hosts(candidates, timeout=_NETWORK_TIMEOUT)
    _last_network_check = now
    _last_network_result = result
    return result


def _compute_presence(force_refresh: bool) -> bool:
    if find_interface():
        return True
    if _present_via_lsusb():
        return True
    return _reachable_hosts_cached(DEFAULT_HOST_CANDIDATES, force_refresh=force_refresh)


def gopro_present(*, force_refresh: bool = False) -> bool:
    """Best-effort presence check for a connected GoPro using USB or network hints."""

    global _last_present_check, _last_present_result
    now = time.monotonic()
    if not force_refresh and (now - _last_present_check) <= _PRESENT_CACHE_TTL:
        return _last_present_result
    result = _compute_presence(force_refresh=force_refresh)
    _last_present_check = now
    _last_present_result = result
    return result
