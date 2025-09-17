from __future__ import annotations
from pathlib import Path
import yaml
from functools import lru_cache


_ROOT = Path(__file__).resolve().parent


@lru_cache(maxsize=4)
def _load_lang(lang: str) -> dict:
    lang = (lang or 'en').lower()
    filename = f'strings_{lang}.yml'
    path = _ROOT / filename
    if not path.exists():
        # Fallback to English file if requested language file is missing
        path = _ROOT / 'strings_en.yml'
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        data = {}
    return data


@lru_cache(maxsize=1)
def _load_en() -> dict:
    return _load_lang('en')


def _get_from_dict(d: dict, key: str):
    cur = d
    for part in key.split('.'):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
        if cur is None:
            return None
    return cur


def t(lang: str, key: str, **kwargs) -> str:
    """Translate dotted key for lang, fallback to English, then key.

    Example: t('nl', 'home.settings') -> 'Instellingen'
    Supports simple str.format style placeholders.
    """
    val = _get_from_dict(_load_lang(lang), key)
    if val is None:
        val = _get_from_dict(_load_en(), key)
    if not isinstance(val, str):
        # As a last resort, return the key itself
        val = key
    try:
        if kwargs:
            return val.format(**kwargs)
    except Exception:
        # If formatting fails, return the raw string
        pass
    return val

