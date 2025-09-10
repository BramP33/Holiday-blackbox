import os
from pathlib import Path
import yaml


DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent.parent / 'config.default.yml'
USER_CONFIG_PATH = Path(__file__).resolve().parent.parent / 'config.yml'


def load_config() -> dict:
    """Load config.yml, falling back to defaults, and write a merged copy on first run."""
    with open(DEFAULT_CONFIG_PATH, 'r', encoding='utf-8') as f:
        default = yaml.safe_load(f) or {}
    if USER_CONFIG_PATH.exists():
        with open(USER_CONFIG_PATH, 'r', encoding='utf-8') as f:
            user = yaml.safe_load(f) or {}
    else:
        user = {}
    cfg = _merge(default, user)
    # ensure user config exists for easy editing
    if not USER_CONFIG_PATH.exists():
        try:
            with open(USER_CONFIG_PATH, 'w', encoding='utf-8') as f:
                yaml.safe_dump(cfg, f, sort_keys=False)
        except Exception:
            pass
    return cfg


def save_config(cfg: dict) -> None:
    USER_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(USER_CONFIG_PATH, 'w', encoding='utf-8') as f:
        yaml.safe_dump(cfg, f, sort_keys=False)


def _merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out

