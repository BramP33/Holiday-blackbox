from __future__ import annotations

import datetime as dt
import json
import random
import re
import sqlite3
import struct
import subprocess
import threading
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

from .geocode import GeoResolver, GeoResult


_VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}


def _run_ffprobe(path: Path) -> Optional[Dict]:
    """Return parsed JSON metadata from ffprobe for given file."""
    cmd = [
        'ffprobe',
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_entries', 'format=duration:format_tags:stream_tags',
        str(path),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:  # ffprobe missing
        return None
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout or '{}')
    except json.JSONDecodeError:
        return None
    return data


def _run_ffprobe_json(path: Path, args: Iterable[str]) -> Optional[Dict]:
    cmd = ['ffprobe', '-v', 'error', '-print_format', 'json', *args, str(path)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout or '{}')
    except json.JSONDecodeError:
        return None


def _collect_tags(data: Dict) -> Dict[str, str]:
    tags: Dict[str, str] = {}
    if not data:
        return tags
    fmt = data.get('format') or {}
    for key, value in (fmt.get('tags') or {}).items():
        key_lower = key.lower()
        if key_lower not in tags:
            tags[key_lower] = str(value)
    for stream in data.get('streams') or []:
        for key, value in (stream.get('tags') or {}).items():
            key_lower = key.lower()
            if key_lower not in tags:
                tags[key_lower] = str(value)
    return tags


_iso_pattern = re.compile(r'[-+]?[0-9]+(?:\.[0-9]+)?')


def _parse_iso6709(value: str) -> Optional[tuple[float, float, Optional[float]]]:
    matches = _iso_pattern.findall(value)
    if len(matches) >= 2:
        lat = float(matches[0])
        lon = float(matches[1])
        alt = float(matches[2]) if len(matches) >= 3 else None
        return lat, lon, alt
    return None


_dms_pattern = re.compile(r'[0-9]+(?:\.[0-9]+)?')


def _parse_dms(value: str, ref: Optional[str] = None) -> Optional[float]:
    numbers = _dms_pattern.findall(value)
    if not numbers:
        return None
    deg = float(numbers[0])
    minutes = float(numbers[1]) if len(numbers) > 1 else 0.0
    seconds = float(numbers[2]) if len(numbers) > 2 else 0.0
    total = deg + minutes / 60.0 + seconds / 3600.0
    text = (value + ' ' + (ref or '')).upper()
    if 'S' in text or 'W' in text:
        total *= -1
    return total


_fallback_num_pattern = re.compile(r'-?[0-9]+(?:\.[0-9]+)?')


def _as_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        pass
    try:
        return float(Fraction(text))
    except Exception:
        pass
    match = _fallback_num_pattern.search(text)
    if match:
        try:
            return float(match.group(0))
        except ValueError:
            return None
    return None


def _extract_timestamp(tags: Dict[str, str]) -> Optional[str]:
    keys = [
        'creation_time',
        'com.apple.quicktime.creationdate',
        'creationdate',
        'datetimeoriginal',
        'datecreated',
    ]
    raw = None
    for key in keys:
        if key in tags:
            raw = tags[key]
            break
    if not raw:
        return None
    text = raw.strip()
    if not text:
        return None
    text = text.replace('UTC', '').strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        dt_obj = dt.datetime.fromisoformat(text)
        if dt_obj.tzinfo is None:
            return dt_obj.isoformat()
        return dt_obj.astimezone(dt.timezone.utc).isoformat().replace('+00:00', 'Z')
    except ValueError:
        pass
    for fmt in (
        '%Y-%m-%d %H:%M:%S',
        '%Y/%m/%d %H:%M:%S',
        '%Y:%m:%d %H:%M:%S',
    ):
        try:
            dt_obj = dt.datetime.strptime(text, fmt)
            return dt_obj.isoformat()
        except ValueError:
            continue
    return None

@dataclass
class VideoMetadata:
    path: str
    file_mtime: float
    captured_at: Optional[str]
    lat: Optional[float]
    lon: Optional[float]
    alt: Optional[float]
    city: Optional[str]
    admin: Optional[str]
    country_code: Optional[str]
    has_gps: bool
    duration_sec: Optional[float]
    camera_make: Optional[str]
    camera_model: Optional[str]


@dataclass
class LocationSuggestion:
    label: str
    query: str
    count: int
    last_captured: Optional[str]
    last_mtime: float


class MediaMetadataIndex:
    """Store and query metadata for media files within the active trip."""

    def __init__(self, paths) -> None:  # Paths type hinted in runtime to avoid cycle
        self._paths = paths
        self._root = paths.trip_root()
        self._meta_dir = self._root / '.meta'
        self._meta_dir.mkdir(parents=True, exist_ok=True)
        self._db_path = self._meta_dir / 'media_index.db'
        self._conn_lock = threading.Lock()
        self._conn: Optional[sqlite3.Connection] = None
        self._geo = GeoResolver(self._meta_dir / 'geocode_cache.json')

    # -- database helpers -------------------------------------------------
    def _conn_or_open(self) -> sqlite3.Connection:
        with self._conn_lock:
            if self._conn is None:
                conn = sqlite3.connect(self._db_path, check_same_thread=False)
                conn.execute('PRAGMA journal_mode=WAL;')
                conn.row_factory = sqlite3.Row
                self._migrate(conn)
                self._conn = conn
            return self._conn

    def _migrate(self, conn: sqlite3.Connection) -> None:
        cur = conn.cursor()
        cur.execute(
            'CREATE TABLE IF NOT EXISTS videos ('
            ' path TEXT PRIMARY KEY,'
            ' file_mtime REAL,'
            ' captured_at TEXT,'
            ' lat REAL,'
            ' lon REAL,'
            ' alt REAL,'
            ' city TEXT,'
            ' admin TEXT,'
            ' country_code TEXT,'
            ' duration_sec REAL,'
            ' camera_make TEXT,'
            ' camera_model TEXT,'
            ' has_gps INTEGER NOT NULL DEFAULT 0'
            ')'  # noqa: E122
        )
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_city ON videos(city)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_country ON videos(country_code)')
        conn.commit()

        # Backfill missing columns for older schemas
        cols = {row['name'] for row in cur.execute('PRAGMA table_info(videos)')}
        migrations = []
        if 'duration_sec' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN duration_sec REAL')
        if 'camera_make' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN camera_make TEXT')
        if 'camera_model' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN camera_model TEXT')
        for statement in migrations:
            cur.execute(statement)
        if migrations:
            conn.commit()

    # -- metadata extraction ----------------------------------------------
    def _extract_video(self, path: Path) -> Optional[VideoMetadata]:
        data = _run_ffprobe(path)
        tags = _collect_tags(data or {})
        captured_at = _extract_timestamp(tags)

        duration_sec: Optional[float] = None
        fmt = (data or {}).get('format') or {}
        if fmt:
            raw_duration = fmt.get('duration')
            if raw_duration is not None:
                try:
                    duration_sec = float(raw_duration)
                except (TypeError, ValueError):
                    duration_sec = _as_float(str(raw_duration))

        def _pick(*keys: str) -> Optional[str]:
            for key in keys:
                if key in tags and tags[key]:
                    value = str(tags[key]).strip().strip('\0')
                    if value:
                        return value
            return None

        camera_make = _pick(
            'com.apple.quicktime.make',
            'make',
            'camera_make',
            'com.apple.quicktime.camera.make',
            'com.apple.quicktime.manufacturer',
            'com.android.manufacturer',
            'manufacturer',
        )
        camera_model = _pick(
            'com.apple.quicktime.model',
            'model',
            'camera_model',
            'com.apple.quicktime.camera.model',
            'com.apple.quicktime.device.model',
            'device_model',
            'com.android.model',
            'android_model',
        )

        lat = lon = alt = None
        for key in (
            'com.apple.quicktime.location.iso6709',
            'location-eng',
            'location',
            'com.apple.quicktime.gps.coordinates',
        ):
            if key in tags:
                parsed = _parse_iso6709(tags[key])
                if parsed:
                    lat, lon, alt = parsed
                    break
        if lat is None or lon is None:
            lat_ref = tags.get('gpslatituderef')
            lon_ref = tags.get('gpslongituderef')
            lat_val = tags.get('gpslatitude')
            lon_val = tags.get('gpslongitude')
            lat = _parse_dms(lat_val or '', lat_ref) if lat_val else None
            lon = _parse_dms(lon_val or '', lon_ref) if lon_val else None
            if lat is None and lat_val:
                lat = _as_float(lat_val)
            if lon is None and lon_val:
                lon = _as_float(lon_val)
        if alt is None:
            alt = _as_float(tags.get('gpsaltitude'))

        city = admin = country_code = None
        has_gps = lat is not None and lon is not None
        if has_gps:
            geo = self._resolve_location(lat, lon)
            if geo:
                city, admin, country_code = geo.city, geo.admin, geo.country_code

        if not has_gps:
            gpmf = _extract_gopro_gpmf(path)
            if gpmf:
                lat = gpmf.lat if gpmf.lat is not None else lat
                lon = gpmf.lon if gpmf.lon is not None else lon
                alt = gpmf.alt if gpmf.alt is not None else alt
                captured_at = captured_at or gpmf.captured_at
                has_gps = has_gps or (gpmf.lat is not None and gpmf.lon is not None)
                if has_gps:
                    geo = self._resolve_location(lat, lon)
                    if geo:
                        city, admin, country_code = geo.city, geo.admin, geo.country_code

        return VideoMetadata(
            path=str(path.relative_to(self._root)),
            file_mtime=path.stat().st_mtime,
            captured_at=captured_at,
            lat=lat,
            lon=lon,
            alt=alt,
            city=city,
            admin=admin,
            country_code=country_code,
            has_gps=has_gps,
            duration_sec=duration_sec,
            camera_make=camera_make,
            camera_model=camera_model,
        )

    def _resolve_location(self, lat: float, lon: float) -> Optional[GeoResult]:
        try:
            return self._geo.resolve(lat, lon)
        except Exception:
            return None

    def ensure_for_path(self, path: Path) -> Optional[VideoMetadata]:
        if path.suffix.lower() not in _VIDEO_EXTS:
            return None
        if not path.exists():
            self.remove_path(path)
            return None
        rel = str(path.relative_to(self._root))
        try:
            file_mtime = path.stat().st_mtime
        except FileNotFoundError:
            self.remove_path(path)
            return None
        row = self._fetch(rel)
        row_has_duration = False
        if row is not None:
            try:
                row_has_duration = row['duration_sec'] is not None
            except (KeyError, IndexError):
                row_has_duration = False
        if row and (row['file_mtime'] or 0) >= file_mtime and row_has_duration:
            return self._row_to_meta(row)
        meta = self._extract_video(path)
        if meta:
            self._upsert(meta)
            return meta
        if row:
            return self._row_to_meta(row)
        return None

    def ensure_for_paths(self, paths: Sequence[Path]) -> Dict[str, VideoMetadata]:
        results: Dict[str, VideoMetadata] = {}
        for path in paths:
            meta = self.ensure_for_path(path)
            if meta:
                results[meta.path] = meta
        return results

    def remove_path(self, path: Path | str) -> None:
        if isinstance(path, Path):
            try:
                rel = str(path.relative_to(self._root))
            except ValueError:
                rel = str(path)
        else:
            rel = path
        conn = self._conn_or_open()
        conn.execute('DELETE FROM videos WHERE path=?', (rel,))
        conn.commit()

    def _fetch(self, rel: str) -> Optional[sqlite3.Row]:
        conn = self._conn_or_open()
        cur = conn.execute('SELECT * FROM videos WHERE path=?', (rel,))
        row = cur.fetchone()
        if row is None:
            return None
        return row

    def _row_to_meta(self, row: sqlite3.Row) -> VideoMetadata:
        return VideoMetadata(
            path=row['path'],
            file_mtime=row['file_mtime'] or 0.0,
            captured_at=row['captured_at'],
            lat=row['lat'],
            lon=row['lon'],
            alt=row['alt'],
            city=row['city'],
            admin=row['admin'],
            country_code=row['country_code'],
            has_gps=bool(row['has_gps']),
            duration_sec=row['duration_sec'] if 'duration_sec' in row.keys() else None,
            camera_make=row['camera_make'] if 'camera_make' in row.keys() else None,
            camera_model=row['camera_model'] if 'camera_model' in row.keys() else None,
        )

    def _upsert(self, meta: VideoMetadata) -> None:
        conn = self._conn_or_open()
        conn.execute(
            'INSERT INTO videos (path, file_mtime, captured_at, lat, lon, alt, city, admin, country_code, duration_sec, camera_make, camera_model, has_gps) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(path) DO UPDATE SET '
            ' file_mtime=excluded.file_mtime,'
            ' captured_at=excluded.captured_at,'
            ' lat=excluded.lat,'
            ' lon=excluded.lon,'
            ' alt=excluded.alt,'
            ' city=excluded.city,'
            ' admin=excluded.admin,'
            ' country_code=excluded.country_code,'
            ' duration_sec=excluded.duration_sec,'
            ' camera_make=excluded.camera_make,'
            ' camera_model=excluded.camera_model,'
            ' has_gps=excluded.has_gps',
            (
                meta.path,
                meta.file_mtime,
                meta.captured_at,
                meta.lat,
                meta.lon,
                meta.alt,
                meta.city,
                meta.admin,
                meta.country_code,
                meta.duration_sec,
                meta.camera_make,
                meta.camera_model,
                1 if meta.has_gps else 0,
            ),
        )
        conn.commit()

    # -- queries ----------------------------------------------------------
    def search(self, query: Optional[str], page: int, size: int) -> tuple[List[VideoMetadata], int]:
        conn = self._conn_or_open()
        where = []
        params: List = []
        if query:
            like = f"%{query.lower()}%"
            where.append('('
                         'lower(coalesce(city, "")) LIKE ? OR '
                         'lower(coalesce(admin, "")) LIKE ? OR '
                         'lower(coalesce(country_code, "")) LIKE ? OR '
                         'lower(path) LIKE ?'
                         ')')
            params.extend([like, like, like, like])
        where_clause = ' WHERE ' + ' AND '.join(where) if where else ''
        count_sql = 'SELECT COUNT(*) FROM videos' + where_clause
        total = conn.execute(count_sql, params).fetchone()[0]
        order_sql = ' ORDER BY coalesce(captured_at, "") DESC, file_mtime DESC'
        sql = (
            'SELECT * FROM videos'
            + where_clause
            + order_sql
            + ' LIMIT ? OFFSET ?'
        )
        page = max(page, 1)
        offset = (page - 1) * size
        rows = conn.execute(sql, (*params, size, offset)).fetchall()
        metas = [self._row_to_meta(row) for row in rows]
        # prune entries whose files disappeared
        valid: List[VideoMetadata] = []
        removed = False
        for meta in metas:
            path = self._root / meta.path
            if path.exists():
                valid.append(meta)
            else:
                self.remove_path(meta.path)
                removed = True
        if removed and len(valid) < len(metas) and total > 0:
            total = conn.execute(count_sql, params).fetchone()[0]
        return valid, total

    def location_suggestions(self, limit: int = 4) -> List[LocationSuggestion]:
        """Return location suggestions using recency, popularity and variety."""
        limit = max(0, limit)
        if limit == 0:
            return []

        conn = self._conn_or_open()
        rows = conn.execute(
            'SELECT '
            ' coalesce(trim(city), "") AS city,'
            ' coalesce(trim(admin), "") AS admin,'
            ' coalesce(trim(country_code), "") AS country_code,'
            ' COUNT(*) AS count,'
            ' MAX(coalesce(captured_at, "")) AS last_captured,'
            ' MAX(coalesce(file_mtime, 0)) AS last_mtime '
            'FROM videos '
            'WHERE has_gps = 1 '
            ' AND ('
            '  coalesce(trim(city), "") <> "" OR'
            '  coalesce(trim(admin), "") <> "" OR'
            '  coalesce(trim(country_code), "") <> ""'
            ' ) '
            'GROUP BY city, admin, country_code'
        ).fetchall()

        if not rows:
            return []

        def _compose_label(city: str, admin: str, country_code: str) -> Optional[str]:
            parts = [p for p in (city or None, admin or None) if p]
            cc = country_code or None
            if cc:
                parts.append(cc)
            if not parts:
                return None
            return ', '.join(parts)

        entries: List[LocationSuggestion] = []
        for row in rows:
            city = row['city'] or ''
            admin = row['admin'] or ''
            country_code = row['country_code'] or ''
            label = _compose_label(city, admin, country_code)
            if not label:
                continue
            # Prefer city/admin/country_code for matching search queries.
            query_value = next((value for value in (city, admin, country_code) if value), label)
            last_captured = row['last_captured'] or None
            last_mtime = float(row['last_mtime'] or 0.0)
            entries.append(
                LocationSuggestion(
                    label=label,
                    query=query_value,
                    count=int(row['count'] or 0),
                    last_captured=last_captured,
                    last_mtime=last_mtime,
                )
            )

        if not entries:
            return []

        def _recent_key(item: LocationSuggestion):
            return (
                item.last_captured or '',
                item.last_mtime,
                item.count,
            )

        def _popular_key(item: LocationSuggestion):
            return (
                item.count,
                item.last_mtime,
                item.last_captured or '',
            )

        remaining = entries.copy()
        selected: List[LocationSuggestion] = []

        if remaining:
            top_recent = max(remaining, key=_recent_key)
            selected.append(top_recent)
            remaining.remove(top_recent)

        if remaining and len(selected) < limit:
            top_popular = max(remaining, key=_popular_key)
            selected.append(top_popular)
            remaining.remove(top_popular)

        remaining_slots = limit - len(selected)
        if remaining and remaining_slots > 0:
            sample_count = min(len(remaining), remaining_slots)
            selected.extend(random.sample(remaining, sample_count))

        return selected[:limit]

    def all_for_paths(self, rel_paths: Sequence[str]) -> Dict[str, VideoMetadata]:
        if not rel_paths:
            return {}
        placeholders = ','.join('?' for _ in rel_paths)
        conn = self._conn_or_open()
        rows = conn.execute(
            f'SELECT * FROM videos WHERE path IN ({placeholders})', tuple(rel_paths)
        ).fetchall()
        return {row['path']: self._row_to_meta(row) for row in rows}

    def sync_all(self) -> int:
        """Index all video files under the current trip; returns number processed."""
        files = [p for p in self._root.rglob('*') if p.is_file() and p.suffix.lower() in _VIDEO_EXTS]
        indexed = 0
        for path in files:
            meta = self.ensure_for_path(path)
            if meta:
                indexed += 1
        return indexed


__all__ = ['MediaMetadataIndex', 'VideoMetadata', 'LocationSuggestion']


# -- GoPro GPMF parsing -----------------------------------------------------


@dataclass
class _GPMFGPS:
    lat: Optional[float] = None
    lon: Optional[float] = None
    alt: Optional[float] = None
    captured_at: Optional[str] = None


def _extract_gopro_gpmf(path: Path) -> Optional[_GPMFGPS]:
    stream_idx = _find_gpmd_stream(path)
    if stream_idx is None:
        return None
    raw = _dump_gpmd_stream(path, stream_idx)
    if not raw:
        return None
    return _parse_gpmf_gps(raw)


def _find_gpmd_stream(path: Path) -> Optional[int]:
    data = _run_ffprobe_json(path, ['-show_entries', 'stream=index,codec_type,codec_tag_string'])
    if not data:
        return None
    streams = data.get('streams') or []
    for stream in streams:
        if (stream.get('codec_type') or '').lower() == 'data' and (stream.get('codec_tag_string') or '').lower() == 'gpmd':
            try:
                return int(stream['index'])
            except Exception:
                continue
    return None


def _dump_gpmd_stream(path: Path, stream_index: int) -> Optional[bytes]:
    cmd = [
        'ffmpeg',
        '-loglevel', 'error',
        '-i', str(path),
        '-codec', 'copy',
        '-map', f'0:{stream_index}',
        '-f', 'rawvideo',
        '-',
    ]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def _parse_gpmf_gps(raw: bytes) -> Optional[_GPMFGPS]:
    if not raw:
        return None

    result = _parse_gpmf_block(raw)
    if result:
        return result
    # Some streams may contain padding or multiple packets concatenated
    marker = b'DEVC'
    idx = raw.find(marker, 1)
    while idx != -1:
        result = _parse_gpmf_block(raw[idx:])
        if result:
            return result
        idx = raw.find(marker, idx + 4)
    return None


def _parse_gpmf_block(raw: bytes) -> Optional[_GPMFGPS]:
    for key, typ, size, repeat, payload in _iter_gpmf_atoms(raw):
        if key == 'STRM':
            gps = _parse_gpmf_stream(payload)
            if gps:
                return gps
        if typ == 0 or chr(typ) in {'J', 'G'}:  # container
            nested = _parse_gpmf_block(payload)
            if nested:
                return nested
    return None


def _iter_gpmf_atoms(data: bytes):
    offset = 0
    length = len(data)
    while offset + 8 <= length:
        key = data[offset:offset + 4]
        if key == b'\0\0\0\0':
            break
        key_s = key.decode('ascii', errors='ignore')
        typ = data[offset + 4]
        size = data[offset + 5]
        repeat = int.from_bytes(data[offset + 6:offset + 8], 'big')
        payload_size = size * repeat
        payload_start = offset + 8
        payload_end = payload_start + payload_size
        if payload_end > length or payload_size < 0:
            break
        payload = data[payload_start:payload_end]
        pad = (-payload_size) % 4
        offset = payload_end + pad
        yield key_s, typ, size, repeat, payload


def _parse_gpmf_stream(payload: bytes) -> Optional[_GPMFGPS]:
    entries = list(_iter_gpmf_atoms(payload))
    if not any(key == 'GPS5' for key, *_ in entries):
        return None

    scal_entry = next((entry for entry in entries if entry[0] == 'SCAL'), None)
    gps_entry = next((entry for entry in entries if entry[0] == 'GPS5'), None)
    if not scal_entry or not gps_entry:
        return None

    scal_values = _unpack_values(*scal_entry[1:])
    gps_values = _unpack_values(*gps_entry[1:])
    if not isinstance(scal_values, (tuple, list)) or not isinstance(gps_values, (tuple, list)):
        return None
    if not scal_values or not gps_values:
        return None

    components = len(scal_values)
    if components == 0:
        return None

    samples: List[tuple] = []
    step = components
    total_components = len(gps_values)
    for i in range(0, total_components, step):
        chunk = gps_values[i:i + step]
        if len(chunk) < components:
            break
        samples.append(tuple(chunk[:components]))

    if not samples:
        return None

    fix_entry = next((entry for entry in entries if entry[0] == 'GPSF'), None)
    fix_values = _unpack_values(*fix_entry[1:]) if fix_entry else None
    gpsu_entry = next((entry for entry in entries if entry[0] == 'GPSU'), None)
    gpsu_text = _unpack_values(*gpsu_entry[1:]) if gpsu_entry else None

    timestamp_iso = _parse_gpsu_timestamp(gpsu_text if isinstance(gpsu_text, str) else None)

    lat = lon = alt = None
    for idx, sample in enumerate(samples):
        fix_ok = True
        if isinstance(fix_values, (tuple, list)) and fix_values:
            fix_val = fix_values[idx] if idx < len(fix_values) else fix_values[0]
            fix_ok = bool(fix_val)
        if not fix_ok:
            continue
        lat = sample[0] / scal_values[0] if scal_values[0] else None
        lon = sample[1] / scal_values[1] if len(scal_values) > 1 and scal_values[1] else None
        alt = sample[2] / scal_values[2] if len(scal_values) > 2 and scal_values[2] else None
        if lat is not None and lon is not None:
            break

    if lat is None or lon is None:
        return None

    return _GPMFGPS(lat=lat, lon=lon, alt=alt, captured_at=timestamp_iso)


def _unpack_values(typ: int, size: int, repeat: int, payload: bytes):
    char = chr(typ) if 32 <= typ <= 126 else ''
    if not payload:
        return () if char else None
    try:
        if char == 'l':
            return struct.unpack('>' + 'i' * (len(payload) // 4), payload)
        if char == 'L':
            return struct.unpack('>' + 'I' * (len(payload) // 4), payload)
        if char == 's':
            return struct.unpack('>' + 'h' * (len(payload) // 2), payload)
        if char == 'S':
            return struct.unpack('>' + 'H' * (len(payload) // 2), payload)
        if char == 'f':
            return struct.unpack('>' + 'f' * (len(payload) // 4), payload)
        if char == 'd':
            return struct.unpack('>' + 'd' * (len(payload) // 8), payload)
        if char in {'c', 'C', 'U', 'u'}:
            return payload.decode('utf-8', errors='ignore').rstrip('\0')
    except Exception:
        return None
    return None


def _parse_gpsu_timestamp(text: Optional[str]) -> Optional[str]:
    if not text:
        return None
    raw = text.strip()
    if not raw:
        return None
    # Format: DDMMYYHHMMSS.sss
    try:
        day = int(raw[0:2])
        month = int(raw[2:4])
        year = int(raw[4:6]) + 2000
        hour = int(raw[6:8])
        minute = int(raw[8:10])
        sec = float(raw[10:]) if len(raw) > 10 else 0.0
        second = int(sec)
        micro = int(round((sec - second) * 1_000_000))
        dt_obj = dt.datetime(year, month, day, hour, minute, second, micro, tzinfo=dt.timezone.utc)
        return dt_obj.isoformat().replace('+00:00', 'Z')
    except Exception:
        return None
