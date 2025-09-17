from __future__ import annotations

import argparse
import sys
from pathlib import Path

from ..config import load_config
from ..paths import Paths
from .metadata import MediaMetadataIndex


def _default_trip_root() -> Path:
    cfg = load_config()
    return Paths(cfg).ensure().trip_root()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Rebuild the Holiday Blackbox media metadata index.',
    )
    parser.add_argument(
        '--trip-root',
        type=Path,
        default=None,
        help='Override trip root; defaults to the configured trip directory.',
    )
    parser.add_argument(
        '--quiet',
        action='store_true',
        help='Suppress per-file output (only final summary).',
    )
    args = parser.parse_args(argv)

    trip_root = args.trip_root or _default_trip_root()
    trip_root.mkdir(parents=True, exist_ok=True)

    cfg = load_config()
    cfg_paths = {**(cfg.get('paths') or {})}
    if args.trip_root:
        cfg_paths['trip_root'] = str(trip_root)
    cfg = {**cfg, 'paths': cfg_paths}
    paths = Paths(cfg).ensure()

    index = MediaMetadataIndex(paths)
    videos = [
        p for p in trip_root.rglob('*')
        if p.is_file() and p.suffix.lower() in {'.mp4', '.mov', '.m4v'}
    ]
    videos.sort()

    processed = 0
    for path in videos:
        meta = index.ensure_for_path(path)
        if not args.quiet:
            if meta and meta.has_gps:
                loc_parts = [part for part in [meta.city, meta.country_code] if part]
                loc = ', '.join(loc_parts) if loc_parts else 'GPS available'
            else:
                loc = 'no GPS metadata'
            print(f'Indexed {path.relative_to(trip_root)} -> {loc}')
        if meta:
            processed += 1

    print(f'Updated metadata for {processed} video(s).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
