from __future__ import annotations

import psutil
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Mapping, Sequence

from .backup.backup import PHOTO_EXTS, VIDEO_EXTS
from .media.metadata import MediaMetadataIndex, VideoMetadata
from .paths import Paths


_DATE_FOLDER_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')


@dataclass
class TripMediaStats:
    trip_name: str
    video_seconds: float
    video_duration_label: str
    photo_count: int
    free_bytes: int
    device_names: list[str]


def _iter_media(root: Path, extensions: Iterable[str]) -> Iterator[tuple[Path, tuple[str, ...]]]:
    exts = {ext.lower() for ext in extensions}
    if not root.exists():
        return
    for path in root.rglob('*'):
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        if suffix not in exts:
            continue
        try:
            rel_parts = path.relative_to(root).parts
        except ValueError:
            continue
        if any(part.startswith('.') for part in rel_parts):
            continue
        yield path, rel_parts


def _format_video_duration(seconds: float) -> str:
    if seconds <= 0:
        return '0m'
    total_minutes = int(seconds // 60)
    leftover = seconds % 60
    if leftover >= 30:
        total_minutes += 1
    if total_minutes == 0:
        total_minutes = 1
    hours = total_minutes // 60
    minutes = total_minutes % 60
    if hours > 0:
        if minutes > 0:
            return f"{hours}h {minutes:02d}m"
        return f"{hours}h"
    return f"{minutes}m"


def _collect_video_metadata(
    metadata_index: MediaMetadataIndex,
    videos: Mapping[Path, str],
) -> Sequence[VideoMetadata]:
    if not videos:
        return []
    metas = metadata_index.ensure_for_paths(list(videos.keys()))
    missing = [rel for rel in videos.values() if rel not in metas]
    if missing:
        metas.update(metadata_index.all_for_paths(missing))
    return list(metas.values())


def collect_trip_media_stats(cfg: dict, paths: Paths) -> TripMediaStats:
    trip_cfg = (cfg.get('trip') or {})
    trip_name = str(trip_cfg.get('name') or '').strip()

    trip_root = paths.trip_root()
    metadata_index = MediaMetadataIndex(paths)

    video_map: dict[Path, str] = {}
    device_names: set[str] = set()
    for path, parts in _iter_media(trip_root, VIDEO_EXTS):
        rel = '/'.join(parts)
        video_map[path] = rel
        if len(parts) >= 2 and _DATE_FOLDER_RE.match(parts[0]):
            device_label = parts[1].strip()
            if device_label:
                device_names.add(device_label)

    video_metas = _collect_video_metadata(metadata_index, video_map)
    total_seconds = 0.0
    for meta in video_metas:
        if meta.duration_sec is not None and meta.duration_sec > 0:
            total_seconds += meta.duration_sec

    photos_dir = trip_root / 'photos'
    photo_count = 0
    if photos_dir.exists():
        for _path, _parts in _iter_media(photos_dir, PHOTO_EXTS):
            photo_count += 1

    free_bytes = psutil.disk_usage(str(paths.nvme_mount)).free

    devices = sorted({name.strip() for name in device_names if name.strip()}, key=str.lower)

    return TripMediaStats(
        trip_name=trip_name,
        video_seconds=total_seconds,
        video_duration_label=_format_video_duration(total_seconds),
        photo_count=photo_count,
        free_bytes=free_bytes,
        device_names=devices,
    )


__all__ = ['TripMediaStats', 'collect_trip_media_stats']
