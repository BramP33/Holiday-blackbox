from __future__ import annotations

from .config import load_config
from .paths import Paths
from .hardware.display import get_waveshare_display
from .ui.screens import InfoScreen
from .ui.screens import TripPowerOffScreen
from .i18n import t as tr
from .stats import collect_trip_media_stats


def bytes_to_gb(n: int) -> str:
    return f"{n/1_000_000_000:.0f}gb"


def main():
    cfg = load_config()
    paths = Paths(cfg).ensure()
    disp = get_waveshare_display()
    mode = cfg.get('power_off_screen', 'trip').lower()
    if mode == 'weather':
        mode = 'trip'
    lang = cfg.get('language', 'en')

    try:
        if mode == 'clear':
            disp.clear()
            return
        if mode == 'trip':
            trip = cfg.get('trip', {}) or {}
            name = trip.get('name') or ''
            begin = trip.get('begin_date') or ''
            end = trip.get('end_date') or ''
            places = trip.get('places') or []
            screen = TripPowerOffScreen(disp.width, disp.height, lang, name, begin, end, places)
            disp.render(screen.draw())
            return
        # Default: info
        media_stats = collect_trip_media_stats(cfg, paths)
        stats = {
            'trip_name': media_stats.trip_name,
            'video_duration': media_stats.video_duration_label,
            'photo_count': media_stats.photo_count,
            'free_gb': bytes_to_gb(media_stats.free_bytes),
            'devices': media_stats.device_names,
        }
        screen = InfoScreen(disp.width, disp.height, lang, stats)
        disp.render(screen.draw())
    except Exception:
        try:
            disp.clear()
        except Exception:
            pass


if __name__ == '__main__':
    main()
