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
from typing import Any, Dict, Iterable, List, Optional, Sequence

try:
    import numpy as _np
except ImportError:  # pragma: no cover - optional dependency
    _np = None

try:
    from annoy import AnnoyIndex as _AnnoyIndex
except ImportError:  # pragma: no cover - optional dependency
    _AnnoyIndex = None

from .geocode import GeoResolver, GeoResult
from ..transcription.queue import TranscriptionQueue
from ..transcription.semantic import SemanticModelUnavailable, available as semantic_available, encode_text


_VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}


_MONTH_ALIASES = {
    'jan': '01', 'january': '01',
    'feb': '02', 'february': '02',
    'mar': '03', 'march': '03',
    'apr': '04', 'april': '04',
    'may': '05',
    'jun': '06', 'june': '06',
    'jul': '07', 'july': '07',
    'aug': '08', 'august': '08',
    'sep': '09', 'sept': '09', 'september': '09',
    'oct': '10', 'october': '10',
    'nov': '11', 'november': '11',
    'dec': '12', 'december': '12',
}


def _tokenize_query(text: str) -> List[str]:
    return [tok for tok in re.split(r'[\s,;]+', text) if tok]


def _split_date_parts(token: str) -> Optional[tuple[str, str, str]]:
    parts = re.split(r'[-_/\\. ]+', token)
    if len(parts) != 3:
        return None
    if len(parts[0]) == 4 and parts[0].isdigit():
        year, month, day = parts
        if len(month) == 1:
            month = f'0{month}'
        if len(day) == 1:
            day = f'0{day}'
        if month.isdigit() and day.isdigit():
            try:
                dt.datetime(int(year), int(month), int(day))
            except ValueError:
                return None
            return year, month, day
    return None


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


class _SemanticANNIndex:
    """Manage Annoy-based semantic search indexes per embedding model."""

    def __init__(self, meta_dir: Path) -> None:
        self._meta_dir = meta_dir
        self._index_dir = meta_dir / 'semantic_index'
        self._index_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._index_cache: Dict[str, Optional['_AnnoyWrapper']] = {}
        self._paths_cache: Dict[str, List[str]] = {}
        self._meta_cache: Dict[str, Dict[str, Any]] = {}
        self._building: Dict[str, bool] = {}

    def _model_key(self, model_id: str) -> str:
        safe = re.sub(r'[^a-zA-Z0-9]+', '_', model_id or 'default').strip('_')
        return safe or 'default'

    def _index_path(self, key: str) -> Path:
        return self._index_dir / f'{key}.ann'

    def _meta_path(self, key: str) -> Path:
        return self._index_dir / f'{key}.json'

    def _load_meta_from_disk(self, key: str) -> Optional[Dict[str, Any]]:
        path = self._meta_path(key)
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text())
        except Exception:
            return None
        return data

    def _save_meta_to_disk(self, key: str, data: Dict[str, Any]) -> None:
        try:
            self._meta_path(key).write_text(json.dumps(data))
        except Exception:
            pass

    def _load_index_into_cache(self, key: str, dim: int) -> Optional['_AnnoyWrapper']:
        if _AnnoyIndex is None:
            return None
        index_path = self._index_path(key)
        if not index_path.exists():
            return None
        try:
            index = _AnnoyIndex(dim, 'angular')
            index.load(str(index_path))
        except Exception:
            return None
        wrapper = _AnnoyWrapper(index)
        self._index_cache[key] = wrapper
        return wrapper

    def _current_db_mtime(self, queue: TranscriptionQueue) -> float:
        db_path = getattr(queue, '_db_path', None)
        if isinstance(db_path, Path) and db_path.exists():
            try:
                return db_path.stat().st_mtime
            except OSError:
                return 0.0
        return 0.0

    def _ensure_ready(self, queue: TranscriptionQueue, model_id: str) -> Optional['_AnnoyWrapper']:
        if _AnnoyIndex is None:
            return None
        key = self._model_key(model_id)
        db_mtime = self._current_db_mtime(queue)
        with self._lock:
            meta = self._meta_cache.get(key)
            if meta is None:
                meta = self._load_meta_from_disk(key)
                if meta is not None:
                    self._meta_cache[key] = meta
            wrapper = self._index_cache.get(key)
            if meta and wrapper and abs(meta.get('db_mtime', 0.0) - db_mtime) < 0.1:
                return wrapper
            if meta and not wrapper:
                dim = int(meta.get('dim') or 0)
                if dim > 0:
                    wrapper = self._load_index_into_cache(key, dim)
                    if wrapper:
                        self._paths_cache[key] = list(meta.get('paths') or [])
            if meta and wrapper and abs(meta.get('db_mtime', 0.0) - db_mtime) < 0.1:
                return wrapper
            if self._building.get(key):
                return wrapper
            self._building[key] = True
        thread = threading.Thread(
            target=self._build_index,
            args=(queue, model_id, key, db_mtime),
            daemon=True,
        )
        thread.start()
        with self._lock:
            return self._index_cache.get(key)

    def _build_index(self, queue: TranscriptionQueue, model_id: str, key: str, db_mtime: float) -> None:
        if _np is None or _AnnoyIndex is None:
            with self._lock:
                self._index_cache[key] = None
                self._paths_cache[key] = []
                self._meta_cache[key] = {
                    'model_id': model_id,
                    'db_mtime': db_mtime,
                    'dim': 0,
                    'paths': [],
                }
                self._building[key] = False
            self._save_meta_to_disk(key, self._meta_cache[key])
            return
        try:
            embeddings: List[tuple[str, _np.ndarray]] = []
            for rel_path, blob, model in queue.iter_embeddings(model=model_id):
                if blob is None:
                    continue
                if model and model != model_id:
                    continue
                try:
                    vec = _np.frombuffer(blob, dtype=_np.float32)
                except Exception:
                    continue
                if vec.size == 0:
                    continue
                embeddings.append((rel_path, vec.copy()))
        except Exception:
            embeddings = []

        if not embeddings:
            with self._lock:
                self._index_cache[key] = None
                self._paths_cache[key] = []
                self._meta_cache[key] = {
                    'model_id': model_id,
                    'db_mtime': db_mtime,
                    'dim': 0,
                    'paths': [],
                }
                self._building[key] = False
            self._save_meta_to_disk(key, self._meta_cache[key])
            return

        dim = embeddings[0][1].size
        index = _AnnoyIndex(dim, 'angular')
        paths: List[str] = []
        for idx, (rel_path, vec) in enumerate(embeddings):
            try:
                index.add_item(idx, vec.tolist())
            except Exception:
                continue
            paths.append(rel_path)

        try:
            index.build(20)
            index.save(str(self._index_path(key)))
        except Exception:
            pass

        wrapper = _AnnoyWrapper(index)
        meta = {
            'model_id': model_id,
            'db_mtime': db_mtime,
            'dim': dim,
            'paths': paths,
        }
        self._save_meta_to_disk(key, meta)
        with self._lock:
            self._index_cache[key] = wrapper
            self._paths_cache[key] = paths
            self._meta_cache[key] = meta
            self._building[key] = False

    def query(self, queue: TranscriptionQueue, model_id: str, query_vec: _np.ndarray, top_k: int = 50) -> List[tuple[str, float]]:
        if _AnnoyIndex is None or _np is None:
            return []
        wrapper = self._ensure_ready(queue, model_id)
        if wrapper is None:
            return []
        key = self._model_key(model_id)
        with self._lock:
            paths = self._paths_cache.get(key, [])
        if not paths:
            return []
        try:
            idxs, distances = wrapper.get_nns(query_vec, top_k)
        except Exception:
            return []
        results: List[tuple[str, float]] = []
        for idx, dist in zip(idxs, distances):
            if 0 <= idx < len(paths):
                cosine = max(-1.0, min(1.0, 1.0 - 0.5 * (dist ** 2)))
                results.append((paths[idx], cosine))
        return results


class _AnnoyWrapper:
    """Small wrapper to isolate Annoy-specific calls for typing."""

    def __init__(self, index: Any) -> None:
        self._index = index

    def get_nns(self, vector: _np.ndarray, top_k: int) -> tuple[List[int], List[float]]:
        ids, distances = self._index.get_nns_by_vector(vector.tolist(), top_k, include_distances=True)
        return ids, distances

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
        trip_name = str(((paths.cfg or {}).get('trip') or {}).get('name', '')).strip()
        self._trip_words = {w.lower() for w in re.split(r'\W+', trip_name) if w}
        self._transcription_queue: Optional[TranscriptionQueue] = None
        self._parts_cache: Dict[str, Dict[str, Optional[str]]] = {}
        self._fts_checked = False
        self._fts_supported = True
        self._semantic_ann = _SemanticANNIndex(self._meta_dir)

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
            ' has_gps INTEGER NOT NULL DEFAULT 0,'
            ' captured_date TEXT,'
            ' captured_year TEXT,'
            ' captured_month TEXT,'
            ' captured_day TEXT,'
            ' path_date TEXT,'
            ' path_year TEXT,'
            ' path_month TEXT,'
            ' path_day TEXT,'
            ' location_slug TEXT,'
            ' filename TEXT,'
            ' path_tokens TEXT'
            ')'  # noqa: E122
        )
        # Backfill missing columns for older schemas
        cols = {row['name'] for row in cur.execute('PRAGMA table_info(videos)')}
        migrations = []
        if 'duration_sec' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN duration_sec REAL')
        if 'camera_make' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN camera_make TEXT')
        if 'camera_model' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN camera_model TEXT')
        if 'captured_date' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN captured_date TEXT')
        if 'captured_year' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN captured_year TEXT')
        if 'captured_month' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN captured_month TEXT')
        if 'captured_day' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN captured_day TEXT')
        if 'path_date' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN path_date TEXT')
        if 'path_year' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN path_year TEXT')
        if 'path_month' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN path_month TEXT')
        if 'path_day' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN path_day TEXT')
        if 'location_slug' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN location_slug TEXT')
        if 'filename' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN filename TEXT')
        if 'path_tokens' not in cols:
            migrations.append('ALTER TABLE videos ADD COLUMN path_tokens TEXT')
        for statement in migrations:
            cur.execute(statement)
        if migrations:
            conn.commit()

        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_city ON videos(city)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_country ON videos(country_code)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_captured_date ON videos(captured_date)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_captured_year ON videos(captured_year)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_captured_month ON videos(captured_month)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_captured_day ON videos(captured_day)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_path_date ON videos(path_date)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_path_year ON videos(path_year)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_path_month ON videos(path_month)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_path_day ON videos(path_day)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_location_slug ON videos(location_slug)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_videos_filename ON videos(filename)')
        conn.commit()

        try:
            cur.execute(
                'CREATE VIRTUAL TABLE IF NOT EXISTS videos_fts USING fts5('
                'path UNINDEXED,'
                'city,'
                'admin,'
                'country_code,'
                'camera_make,'
                'camera_model,'
                'filename,'
                'path_tokens,'
                'location_slug,'
                "content=''"
                ')'
            )
        except sqlite3.OperationalError:
            self._fts_supported = False
        except sqlite3.Error:
            self._fts_supported = False

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

    def _transcription_index(self) -> TranscriptionQueue:
        if self._transcription_queue is None:
            self._transcription_queue = TranscriptionQueue(self._paths)
        return self._transcription_queue

    def _resolve_location(self, lat: float, lon: float) -> Optional[GeoResult]:
        try:
            return self._geo.resolve(lat, lon)
        except Exception:
            return None

    def _clear_parts_cache(self, rel_path: str) -> None:
        self._parts_cache.pop(rel_path, None)

    def _date_parts(self, meta: VideoMetadata) -> Dict[str, Optional[str]]:
        cached = self._parts_cache.get(meta.path)
        if cached is not None:
            return cached
        captured_year = captured_month = captured_day = captured_date = None
        captured_ts: Optional[float] = None
        if meta.captured_at:
            text = meta.captured_at.replace('Z', '+00:00')
            try:
                dt_obj = dt.datetime.fromisoformat(text)
            except ValueError:
                dt_obj = None
            if dt_obj:
                captured_year = f'{dt_obj.year:04d}'
                captured_month = f'{dt_obj.month:02d}'
                captured_day = f'{dt_obj.day:02d}'
                captured_date = f'{dt_obj.year:04d}-{dt_obj.month:02d}-{dt_obj.day:02d}'
                captured_ts = dt_obj.timestamp()
        path_year = path_month = path_day = path_date = None
        segments = meta.path.split('/', 1)
        if segments:
            date_segment = segments[0]
            if re.match(r'^\d{4}-\d{2}-\d{2}$', date_segment):
                path_year, path_month, path_day = date_segment.split('-')
                path_date = date_segment
        parts = {
            'captured_year': captured_year,
            'captured_month': captured_month,
            'captured_day': captured_day,
            'captured_date': captured_date,
            'captured_ts': captured_ts,
            'path_year': path_year,
            'path_month': path_month,
            'path_day': path_day,
            'path_date': path_date,
        }
        self._parts_cache[meta.path] = parts
        return parts

    def _normalized_fields(self, meta: VideoMetadata) -> Dict[str, Optional[str]]:
        parts = self._date_parts(meta)
        filename = Path(meta.path).name.lower()
        sanitized_path = re.sub(r'[^a-z0-9]+', ' ', meta.path.lower()).strip()
        location_parts = [
            (meta.city or '').strip().lower(),
            (meta.admin or '').strip().lower(),
            (meta.country_code or '').strip().lower(),
        ]
        location_parts = [p for p in location_parts if p]
        location_slug = ' '.join(location_parts) if location_parts else None
        return {
            'captured_date': parts.get('captured_date'),
            'captured_year': parts.get('captured_year'),
            'captured_month': parts.get('captured_month'),
            'captured_day': parts.get('captured_day'),
            'path_date': parts.get('path_date'),
            'path_year': parts.get('path_year'),
            'path_month': parts.get('path_month'),
            'path_day': parts.get('path_day'),
            'location_slug': location_slug,
            'filename': filename,
            'path_tokens': sanitized_path or None,
        }

    def _update_fts(self, conn: sqlite3.Connection, meta: VideoMetadata, normalized: Dict[str, Optional[str]]) -> None:
        if not self._fts_supported:
            return
        try:
            conn.execute('DELETE FROM videos_fts WHERE path = ?', (meta.path,))
            conn.execute(
                'INSERT INTO videos_fts (path, city, admin, country_code, camera_make, camera_model, filename, path_tokens, location_slug) '
                'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                (
                    meta.path,
                    (meta.city or '').lower(),
                    (meta.admin or '').lower(),
                    (meta.country_code or '').lower(),
                    (meta.camera_make or '').lower() if meta.camera_make else '',
                    (meta.camera_model or '').lower() if meta.camera_model else '',
                    (normalized.get('filename') or Path(meta.path).name).lower(),
                    (normalized.get('path_tokens') or meta.path.lower()),
                    normalized.get('location_slug') or '',
                ),
            )
        except sqlite3.Error:
            pass

    def _ensure_fts_populated(self) -> None:
        if not self._fts_supported:
            self._fts_checked = True
            return
        if self._fts_checked:
            return
        conn = self._conn_or_open()
        try:
            total = conn.execute('SELECT COUNT(*) FROM videos').fetchone()[0]
            fts_total = conn.execute('SELECT COUNT(*) FROM videos_fts').fetchone()[0]
        except sqlite3.Error:
            self._fts_checked = True
            return
        if total and fts_total != total:
            try:
                conn.execute('DELETE FROM videos_fts')
                rows = conn.execute(
                    'SELECT path, city, admin, country_code, camera_make, camera_model, '
                    'coalesce(filename, "") AS filename, '
                    'coalesce(path_tokens, "") AS path_tokens, '
                    'coalesce(location_slug, "") AS location_slug '
                    'FROM videos'
                ).fetchall()
                for row in rows:
                    conn.execute(
                        'INSERT INTO videos_fts (path, city, admin, country_code, camera_make, camera_model, filename, path_tokens, location_slug) '
                        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                        (
                            row['path'],
                            (row['city'] or '').lower(),
                            (row['admin'] or '').lower(),
                            (row['country_code'] or '').lower(),
                            (row['camera_make'] or '').lower(),
                            (row['camera_model'] or '').lower(),
                            (row['filename'] or '').lower(),
                            (row['path_tokens'] or '').lower(),
                            (row['location_slug'] or '').lower(),
                        ),
                    )
                conn.commit()
            except sqlite3.Error:
                pass
        self._fts_checked = True

    def _fts_query_from_terms(self, terms: Sequence[str]) -> Optional[str]:
        prepared: List[str] = []
        for raw in terms:
            term = (raw or '').strip().lower()
            if not term:
                continue
            term = term.replace('"', ' ')
            term = re.sub(r'\s+', ' ', term).strip()
            if not term:
                continue
            if ' ' in term:
                prepared.append(f'"{term}"')
                continue
            token = term
            if len(token) >= 3 and token[-1].isalnum():
                token = f'{token}*'
            prepared.append(token)
        if not prepared:
            return None
        return ' AND '.join(prepared)

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
        needs_refresh = False
        if row is not None:
            try:
                row_has_duration = row['duration_sec'] is not None
            except (KeyError, IndexError):
                row_has_duration = False
            try:
                keys = set(row.keys())
            except Exception:
                keys = set()
            required = {
                'captured_date', 'captured_year', 'captured_month', 'captured_day',
                'path_date', 'path_year', 'path_month', 'path_day',
                'location_slug', 'filename', 'path_tokens',
            }
            if not required.issubset(keys):
                needs_refresh = True
            else:
                for field in ('filename', 'path_tokens'):
                    value = row[field] if field in keys else None
                    if not value:
                        needs_refresh = True
                        break
        if row and (row['file_mtime'] or 0) >= file_mtime and row_has_duration and not needs_refresh:
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
        try:
            conn.execute('DELETE FROM videos_fts WHERE path=?', (rel,))
        except sqlite3.Error:
            pass
        conn.commit()
        self._clear_parts_cache(rel)

    def _fetch(self, rel: str) -> Optional[sqlite3.Row]:
        conn = self._conn_or_open()
        cur = conn.execute('SELECT * FROM videos WHERE path=?', (rel,))
        row = cur.fetchone()
        if row is None:
            return None
        return row

    def latest_with_location(self) -> Optional[tuple[VideoMetadata, Dict[str, Optional[str]]]]:
        """Return the newest video that has usable GPS coordinates."""
        conn = self._conn_or_open()
        try:
            row = conn.execute(
                'SELECT * FROM videos '
                'WHERE has_gps = 1 '
                'ORDER BY '
                'CASE WHEN captured_at IS NULL OR captured_at = "" THEN 0 ELSE 1 END DESC, '
                'captured_at DESC, '
                'file_mtime DESC '
                'LIMIT 1'
            ).fetchone()
        except sqlite3.Error:
            row = None
        if row is None:
            return None
        meta = self._row_to_meta(row)
        path = self._root / meta.path
        if not path.exists():
            try:
                self.remove_path(path)
            except Exception:
                pass
            return None
        try:
            row_dict = dict(row)
        except Exception:
            row_dict = {}
        return meta, row_dict

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
        normalized = self._normalized_fields(meta)
        self._clear_parts_cache(meta.path)
        conn.execute(
            'INSERT INTO videos ('
            ' path, file_mtime, captured_at, lat, lon, alt, city, admin, country_code,'
            ' duration_sec, camera_make, camera_model, has_gps,'
            ' captured_date, captured_year, captured_month, captured_day,'
            ' path_date, path_year, path_month, path_day,'
            ' location_slug, filename, path_tokens'
            ' ) VALUES ('
            ' ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?'
            ' ) ON CONFLICT(path) DO UPDATE SET '
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
            ' has_gps=excluded.has_gps,'
            ' captured_date=excluded.captured_date,'
            ' captured_year=excluded.captured_year,'
            ' captured_month=excluded.captured_month,'
            ' captured_day=excluded.captured_day,'
            ' path_date=excluded.path_date,'
            ' path_year=excluded.path_year,'
            ' path_month=excluded.path_month,'
            ' path_day=excluded.path_day,'
            ' location_slug=excluded.location_slug,'
            ' filename=excluded.filename,'
            ' path_tokens=excluded.path_tokens',
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
                normalized.get('captured_date'),
                normalized.get('captured_year'),
                normalized.get('captured_month'),
                normalized.get('captured_day'),
                normalized.get('path_date'),
                normalized.get('path_year'),
                normalized.get('path_month'),
                normalized.get('path_day'),
                normalized.get('location_slug'),
                normalized.get('filename'),
                normalized.get('path_tokens'),
            ),
        )
        self._update_fts(conn, meta, normalized)
        conn.commit()

    # -- queries ----------------------------------------------------------
    def search(self, query: Optional[str], page: int, size: int) -> tuple[List[VideoMetadata], int]:
        conn = self._conn_or_open()
        page = max(page, 1)
        size = max(size, 1)

        raw_query = (query or '').strip()
        if not raw_query:
            count_sql = 'SELECT COUNT(*) FROM videos'
            total = conn.execute(count_sql).fetchone()[0]
            order_sql = ' ORDER BY coalesce(captured_date, "") DESC, coalesce(captured_at, "") DESC, file_mtime DESC'
            sql = 'SELECT * FROM videos' + order_sql + ' LIMIT ? OFFSET ?'
            offset = (page - 1) * size
            rows = conn.execute(sql, (size, offset)).fetchall()
            metas = [self._row_to_meta(row) for row in rows]
            results: List[VideoMetadata] = []
            for meta in metas:
                path = self._root / meta.path
                if path.exists():
                    results.append(meta)
            return results, total

        trip_words = getattr(self, '_trip_words', set())
        tokens_raw = _tokenize_query(raw_query)

        text_terms: List[str] = []
        where_terms: List[str] = []
        where_params: List[str] = []

        for token in tokens_raw:
            norm = token.strip().lower()
            if not norm or norm in trip_words:
                continue

            full_date = _split_date_parts(norm)
            if full_date:
                date_value = f'{full_date[0]}-{full_date[1]}-{full_date[2]}'
                where_terms.append('(captured_date = ? OR path_date = ?)')
                where_params.extend([date_value, date_value])
                continue

            if norm.isdigit() and len(norm) == 4:
                where_terms.append('(captured_year = ? OR path_year = ?)')
                where_params.extend([norm, norm])
                continue

            if '-' in norm and not full_date:
                pieces = [p for p in norm.split('-') if p]
                if len(pieces) == 2 and pieces[0].isdigit() and pieces[1].isdigit():
                    year, month = pieces
                    if len(year) == 4:
                        if len(month) == 1:
                            month = f'0{month}'
                        if month.isdigit() and 1 <= int(month) <= 12:
                            where_terms.append('((captured_year = ? AND captured_month = ?) OR (path_year = ? AND path_month = ?))')
                            where_params.extend([year, month, year, month])
                            continue

            month_value = _MONTH_ALIASES.get(norm)
            if month_value:
                where_terms.append('(captured_month = ? OR path_month = ?)')
                where_params.extend([month_value, month_value])
                continue

            if norm.isdigit() and 1 <= len(norm) <= 2:
                try:
                    day_int = int(norm)
                except ValueError:
                    day_int = -1
                if 1 <= day_int <= 31:
                    day_value = f'{day_int:02d}'
                    where_terms.append('(captured_day = ? OR path_day = ?)')
                    where_params.extend([day_value, day_value])
                    continue

            text_terms.append(norm)

        if not text_terms and not where_terms:
            text_terms.append(raw_query.lower())

        def _row_text_values(row: sqlite3.Row) -> List[str]:
            values: List[str] = []
            for key in (
                'city', 'admin', 'country_code',
                'camera_make', 'camera_model',
                'location_slug', 'filename', 'path_tokens',
            ):
                try:
                    value = row[key]
                except (KeyError, IndexError):
                    value = None
                if not value:
                    continue
                values.append(str(value).lower())
            return values

        scored: Dict[str, Dict[str, object]] = {}

        fts_rows: List[sqlite3.Row] = []
        if self._fts_supported and text_terms:
            self._ensure_fts_populated()
            fts_query = self._fts_query_from_terms(text_terms)
            if fts_query:
                sql_from = ' FROM videos v JOIN videos_fts ON v.path = videos_fts.path'
                where_clauses = list(where_terms)
                params: List[str] = list(where_params)
                where_clauses.insert(0, 'videos_fts MATCH ?')
                params.insert(0, fts_query)
                where_sql = ''
                if where_clauses:
                    where_sql = ' WHERE ' + ' AND '.join(where_clauses)
                order_sql = ' ORDER BY bm25(videos_fts) ASC, coalesce(v.captured_date, "") DESC, v.file_mtime DESC'
                try:
                    fts_rows = conn.execute('SELECT v.*, bm25(videos_fts) AS fts_rank' + sql_from + where_sql + order_sql, tuple(params)).fetchall()
                except sqlite3.Error:
                    fts_rows = []

        for row in fts_rows:
            meta = self._row_to_meta(row)
            path_obj = self._root / meta.path
            if not path_obj.exists():
                self.remove_path(meta.path)
                continue
            base_rank = float(row['fts_rank']) if 'fts_rank' in row.keys() else 0.0
            base_score = 1.0 / (1.0 + max(base_rank, 0.0))
            existing = scored.get(meta.path)
            if existing:
                existing['base'] = max(float(existing.get('base', 0.0)), base_score)
            else:
                scored[meta.path] = {'meta': meta, 'base': base_score, 'semantic': 0.0}

        needs_fallback = not self._fts_supported or not text_terms or not scored
        if needs_fallback:
            fallback_clauses = list(where_terms)
            fallback_params = list(where_params)
            for term in text_terms:
                like_value = f'%{term}%'
                fallback_clauses.append(
                    '('
                    'lower(coalesce(city, "")) LIKE ? OR '
                    'lower(coalesce(admin, "")) LIKE ? OR '
                    'lower(coalesce(country_code, "")) LIKE ? OR '
                    'lower(coalesce(camera_make, "")) LIKE ? OR '
                    'lower(coalesce(camera_model, "")) LIKE ? OR '
                    'lower(coalesce(location_slug, "")) LIKE ? OR '
                    'lower(coalesce(filename, "")) LIKE ? OR '
                    'lower(coalesce(path_tokens, "")) LIKE ?'
                    ')'
                )
                fallback_params.extend([like_value] * 8)

            where_sql = ''
            if fallback_clauses:
                where_sql = ' WHERE ' + ' AND '.join(fallback_clauses)
            fallback_sql = 'SELECT * FROM videos' + where_sql + ' ORDER BY coalesce(captured_date, "") DESC, file_mtime DESC'
            try:
                fallback_rows = conn.execute(fallback_sql, tuple(fallback_params)).fetchall()
            except sqlite3.Error:
                fallback_rows = []

            for row in fallback_rows:
                meta = self._row_to_meta(row)
                path_obj = self._root / meta.path
                if not path_obj.exists():
                    self.remove_path(meta.path)
                    continue
                text_values = _row_text_values(row)
                match_count = 0
                if text_terms:
                    for term in text_terms:
                        if any(term in value for value in text_values):
                            match_count += 1
                existing = scored.get(meta.path)
                base_score = float(match_count)
                if existing:
                    existing['base'] = max(float(existing.get('base', 0.0)), base_score)
                else:
                    scored[meta.path] = {'meta': meta, 'base': base_score, 'semantic': 0.0}

        cfg = self._paths.cfg or {}
        transcription_cfg = cfg.get('transcription') or {}
        semantic_cfg = transcription_cfg.get('semantic') or {}
        semantic_enabled = bool(semantic_cfg.get('enabled', True))
        semantic_model_id = semantic_cfg.get('model') or 'sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2'
        semantic_device = semantic_cfg.get('device', 'cpu')
        min_similarity = float(semantic_cfg.get('min_similarity', 0.25))
        semantic_weight = float(semantic_cfg.get('weight', 1.0))
        ann_top_k_default = int(semantic_cfg.get('ann_top_k', 100))

        if raw_query and semantic_enabled and semantic_available() and _np is not None:
            try:
                query_vector = encode_text(
                    raw_query,
                    model_id=semantic_model_id,
                    device=semantic_device,
                    normalize=True,
                )
                query_vec = _np.asarray(query_vector, dtype=_np.float32)
            except (SemanticModelUnavailable, ValueError):
                query_vec = None
            except Exception:
                query_vec = None

            if query_vec is not None:
                queue = self._transcription_index()
                ann_top_k = max(ann_top_k_default, len(scored) * 2 or ann_top_k_default)
                ann_results = self._semantic_ann.query(queue, semantic_model_id, query_vec, top_k=ann_top_k)

                if not ann_results:
                    ann_results = []
                    for rel_path, blob, model in queue.iter_embeddings(model=semantic_model_id):
                        if blob is None:
                            continue
                        if model and model != semantic_model_id:
                            continue
                        try:
                            vec = _np.frombuffer(blob, dtype=_np.float32)
                        except Exception:
                            continue
                        if vec.size == 0:
                            continue
                        similarity = float(_np.dot(vec, query_vec))
                        ann_results.append((rel_path, similarity))

                for rel_path, similarity in ann_results:
                    if similarity < min_similarity:
                        continue
                    entry = scored.get(rel_path)
                    if entry is None:
                        meta = self.ensure_for_path(self._root / rel_path)
                        if not meta:
                            continue
                        entry = {'meta': meta, 'base': 0.0, 'semantic': 0.0}
                        scored[rel_path] = entry
                    entry['semantic'] = max(float(entry.get('semantic', 0.0)), float(similarity))
            else:
                semantic_weight = 0.0
        else:
            semantic_weight = 0.0

        if not scored:
            return [], 0

        def _sort_key(entry: Dict[str, object]):
            meta = entry['meta']  # type: ignore[assignment]
            base = float(entry.get('base', 0))
            semantic_val = float(entry.get('semantic', 0.0))
            combined = base + semantic_weight * semantic_val
            parts = self._date_parts(meta)
            captured_ts = parts.get('captured_ts') or 0.0
            return (-combined, -semantic_val, -(captured_ts or 0.0), -meta.file_mtime, meta.path)

        sorted_entries = sorted(scored.values(), key=_sort_key)
        offset = (page - 1) * size
        page_items = [entry['meta'] for entry in sorted_entries[offset:offset + size]]
        total = len(sorted_entries)
        return page_items, total

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
