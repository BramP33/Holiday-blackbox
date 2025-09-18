from __future__ import annotations

from Software.blackbox.config import load_config
from Software.blackbox.paths import Paths
from Software.blackbox.stats import collect_trip_media_stats


def main() -> None:
    cfg = load_config()
    stats = collect_trip_media_stats(cfg, Paths(cfg).ensure())
    print(f"Trip: {stats.trip_name or '-'}")
    print(f"Total video duration: {stats.video_duration_label}")
    print(f"Photos: {stats.photo_count}")
    print("Devices:")
    for name in stats.device_names:
        print(f" - {name}")


if __name__ == '__main__':
    main()
