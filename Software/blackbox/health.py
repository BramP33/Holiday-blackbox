from __future__ import annotations

import datetime as dt
import importlib.util
import os
from pathlib import Path
from typing import Any, Dict

import psutil

from .config import load_config
from .hardware.buttons import Buttons
from .paths import Paths
from .transcription.queue import TranscriptionQueue


def _bytes_to_gb(value: int | float | None) -> float | None:
    if not value:
        return None
    try:
        return round(float(value) / 1_000_000_000, 2)
    except (TypeError, ValueError):
        return None


def _disk_health(paths: Paths, cfg: dict) -> Dict[str, Any]:
    mount = paths.nvme_mount
    info: Dict[str, Any] = {
        'mount': str(mount),
        'exists': mount.exists(),
    }
    if not mount.exists():
        info['status'] = 'missing'
        return info

    try:
        usage = psutil.disk_usage(str(mount))
    except Exception as exc:  # pragma: no cover
        info['status'] = 'error'
        info['error'] = str(exc)
        return info

    min_free_gb = float(cfg.get('limits', {}).get('min_free_gb', 10))
    min_free_bytes = min_free_gb * 1_000_000_000
    status = 'ok'
    if usage.free < min_free_bytes:
        status = 'low'
    elif usage.percent >= 90:
        status = 'warn'

    info.update(
        {
            'status': status,
            'total_bytes': usage.total,
            'used_bytes': usage.used,
            'free_bytes': usage.free,
            'free_gb': _bytes_to_gb(usage.free),
            'total_gb': _bytes_to_gb(usage.total),
            'percent_used': round(usage.percent, 2),
        }
    )
    return info


def _display_health(cfg: Dict[str, Any] | None = None) -> Dict[str, Any]:
    info: Dict[str, Any] = {}
    hardware_cfg: Dict[str, Any] = {}
    if cfg:
        hardware_cfg = cfg.get('hardware', {}) or {}
    requested_mode = (hardware_cfg.get('display') or '').lower()
    driver_present = importlib.util.find_spec('waveshare_epd') is not None
    spidev0 = Path('/dev/spidev0.0').exists()
    spidev1 = Path('/dev/spidev0.1').exists()
    mock_requested = os.environ.get('BLACKBOX_FORCE_MOCK', '').lower() in {'1', 'true', 'yes'}

    if requested_mode in {'mock', 'none', 'disabled'}:
        status = 'disabled'
    elif mock_requested:
        status = 'mock'
    elif driver_present and (spidev0 or spidev1):
        status = 'ok'
    elif driver_present:
        status = 'degraded'
    else:
        status = 'missing'

    info.update(
        {
            'status': status,
            'driver_present': driver_present,
            'spidev0': spidev0,
            'spidev1': spidev1,
            'mock_requested': mock_requested,
            'mode': requested_mode or None,
        }
    )
    return info


def _buttons_health(probe: bool = True, cfg: Dict[str, Any] | None = None) -> Dict[str, Any]:
    spec = importlib.util.find_spec('RPi.GPIO')
    info: Dict[str, Any] = {
        'driver_present': spec is not None,
        'status': 'unavailable',
        'pressed': None,
        'enabled': False,
    }
    if not probe:
        info['status'] = 'skipped'
        return info

    hardware_cfg: Dict[str, Any] = {}
    if cfg:
        hardware_cfg = cfg.get('hardware', {}) or {}

    enabled = bool(hardware_cfg.get('buttons_enabled', False))
    info['enabled'] = enabled
    pins = hardware_cfg.get('buttons')

    if not enabled:
        info['status'] = 'disabled'
        return info

    try:
        buttons = Buttons(pins=pins, enabled=enabled)
        if getattr(buttons, 'disabled', False):
            info['status'] = 'disabled'
        elif buttons.dev_mode:
            info['status'] = 'mock'
        elif getattr(buttons, '_gpio', None) is not None:
            states = buttons.read()
            info['status'] = 'ok'
            info['pressed'] = states
        else:
            info['status'] = 'unknown'
    except Exception as exc:  # pragma: no cover
        info['status'] = 'error'
        info['error'] = str(exc)
    return info


def _transcription_health(paths: Paths) -> Dict[str, Any]:
    queue = TranscriptionQueue(paths)
    counts = queue.state_counts()
    recent = queue.recent_errors()
    return {
        'counts': counts,
        'pending': counts.get('pending', 0),
        'processing': counts.get('processing', 0),
        'errors': counts.get('error', 0),
        'recent_errors': recent,
    }


def collect_health(
    paths: Paths | None = None,
    cfg: dict | None = None,
    *,
    probe_buttons: bool = True,
) -> Dict[str, Any]:
    cfg = cfg or load_config()
    paths = paths or Paths(cfg)
    summary = {
        'generated_at': dt.datetime.utcnow().replace(tzinfo=dt.timezone.utc).isoformat(),
        'nvme': _disk_health(paths, cfg),
        'display': _display_health(cfg),
        'buttons': _buttons_health(probe=probe_buttons, cfg=cfg),
        'transcription': _transcription_health(paths),
    }
    return summary


__all__ = ['collect_health']
