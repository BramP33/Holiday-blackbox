from __future__ import annotations
from flask import Flask, jsonify, send_file, render_template_string, request, render_template, url_for, redirect
from flask_cors import CORS
from pathlib import Path
import datetime as dt
import io
import json
import os
import shutil
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from ..config import load_config, save_config
from ..paths import Paths
from ..i18n import t as tr
from ..media.metadata import LocationSuggestion, MediaMetadataIndex, VideoMetadata, _run_ffprobe, _collect_tags, _extract_timestamp
from ..backup.backup import CopyProgress, copy_from_source
from ..backup.backup import VIDEO_EXTS as BACKUP_VIDEO_EXTS
from ..proxies.generate import generate_for_folder
from ..transcription import TranscriptionQueue
from ..stats import collect_trip_media_stats
from ..backup.scanner import find_source_mounts
from ..hardware.usb import ensure_usb_mounted
from ..health import collect_health
from ..ap_mode import start_ap, stop_ap, get_ap_address

def create_app() -> Flask:
    cfg = load_config()
    paths = Paths(cfg).ensure()
    app = Flask(__name__)
    
    # Enable CORS for all routes
    CORS(app)
    
    metadata_index = MediaMetadataIndex(paths)
    transcription_queue = TranscriptionQueue(paths)
    proxy_executor = ThreadPoolExecutor(max_workers=1)
    proxy_lock = threading.Lock()
    trip_root = paths.trip_root().resolve()
    incoming_root = trip_root / '.incoming'
    incoming_root.mkdir(parents=True, exist_ok=True)
    trash_root = paths.trash_dir().resolve()
    trash_meta_dir = trash_root / '.meta'
    trash_meta_dir.mkdir(parents=True, exist_ok=True)

    backup_lock = threading.Lock()
    backup_state: dict[str, object] = {
        'phase': 'idle',
        'progress': 0.0,
        'copied_files': 0,
        'total_files': 0,
        'bytes_copied': 0,
        'device_label': None,
        'eta': None,
        'speed': None,
        'message': None,
        'errors': [],
        'updated_at': dt.datetime.utcnow().replace(tzinfo=dt.timezone.utc).isoformat(),
        'can_cancel': False,
        'skipped_files': 0,
        'replaced_files': 0,
        'previews_done': 0,
        'previews_total': 0,
        'current_file': None,
    }
    backup_thread = None

    def _now_iso() -> str:
        return dt.datetime.utcnow().replace(tzinfo=dt.timezone.utc).isoformat()

    def _set_backup_state(**updates) -> None:
        errors = updates.pop('errors', None)
        with backup_lock:
            if errors is not None:
                backup_state['errors'] = list(errors)
            for key, value in updates.items():
                if key == 'device_label' and value is not None:
                    backup_state[key] = str(value)
                else:
                    backup_state[key] = value
            backup_state['updated_at'] = _now_iso()

    def _get_backup_state() -> dict:
        with backup_lock:
            data = dict(backup_state)
            data['errors'] = list(backup_state.get('errors') or [])

        try:
            previews_done = int(data.get('previews_done') or 0)
        except (TypeError, ValueError):
            previews_done = 0
        try:
            previews_total = int(data.get('previews_total') or 0)
        except (TypeError, ValueError):
            previews_total = 0
        proxy_progress = (
            max(min(previews_done / previews_total, 1.0), 0.0)
            if previews_total > 0
            else 0.0
        )
        proxy_state = 'idle'
        if previews_total > 0:
            proxy_state = 'done' if previews_done >= previews_total else 'running'
        else:
            phase = str(data.get('phase') or '').lower()
            if phase == 'verifying':
                proxy_state = 'running'
            elif phase == 'error':
                proxy_state = 'error'
            elif phase == 'done':
                proxy_state = 'done'

        data.update({
            'proxy_jobs_done': previews_done,
            'proxy_jobs_total': previews_total,
            'proxy_progress': proxy_progress,
            'proxy_state': proxy_state,
        })

        try:
            raw_counts = transcription_queue.state_counts()
        except Exception:
            raw_counts = {}

        transcription_counts = {
            (key or '').strip().lower(): int(value or 0)
            for key, value in raw_counts.items()
        }

        def _count(*names: str) -> int:
            return sum(transcription_counts.get(name, 0) for name in names)

        transcription_pending = _count('pending', 'queued')
        transcription_processing = _count('processing', 'running')
        transcription_done = _count('done', 'completed')
        transcription_error = _count('error', 'failed')
        other_states = sum(
            value
            for key, value in transcription_counts.items()
            if key not in {'pending', 'queued', 'processing', 'running', 'done', 'completed', 'error', 'failed'}
        )
        transcription_total = (
            transcription_pending
            + transcription_processing
            + transcription_done
            + transcription_error
            + other_states
        )
        transcription_progress = (
            max(min(transcription_done / transcription_total, 1.0), 0.0)
            if transcription_total > 0
            else 0.0
        )
        transcription_state = 'idle'
        if transcription_processing > 0:
            transcription_state = 'processing'
        elif transcription_pending > 0:
            transcription_state = 'pending'
        elif transcription_error > 0 and transcription_done < transcription_total:
            transcription_state = 'error'
        elif transcription_total > 0 and transcription_done >= transcription_total:
            transcription_state = 'done'

        data.update({
            'transcription_total': transcription_total,
            'transcription_done': transcription_done,
            'transcription_pending': transcription_pending,
            'transcription_processing': transcription_processing,
            'transcription_error': transcription_error,
            'transcription_progress': transcription_progress,
            'transcription_state': transcription_state,
            'transcription_updated_at': _now_iso(),
        })

        return data

    def _format_srt_timestamp(seconds: float) -> str:
        total_ms = int(round(max(seconds, 0.0) * 1000))
        hours, remainder = divmod(total_ms, 3600_000)
        minutes, remainder = divmod(remainder, 60_000)
        secs, millis = divmod(remainder, 1000)
        return f'{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}'

    def _render_srt_from_record(record: dict) -> str | None:
        segments = record.get('segments') or []
        lines: list[str] = []
        index = 1
        for segment in segments:
            try:
                start = float(segment.get('start') or 0.0)
            except Exception:
                start = 0.0
            try:
                end = float(segment.get('end') or start)
            except Exception:
                end = start
            text = str(segment.get('text') or '').strip()
            if not text:
                continue
            if end <= start:
                end = start + 0.5
            lines.append(str(index))
            lines.append(f'{_format_srt_timestamp(start)} --> {_format_srt_timestamp(end)}')
            lines.append(text)
            lines.append('')
            index += 1
        if lines:
            return '\n'.join(lines).strip()
        transcript = (record.get('transcript') or '').strip()
        if transcript:
            return transcript
        return None

    def _trip_begin_timestamp(cur_cfg: dict | None = None) -> float | None:
        cfg_local = cur_cfg or load_config()
        raw_begin = (cfg_local.get('trip') or {}).get('begin_date')
        if isinstance(raw_begin, dt.datetime):
            begin = raw_begin.date().isoformat()
        elif isinstance(raw_begin, dt.date):
            begin = raw_begin.isoformat()
        elif isinstance(raw_begin, str):
            begin = raw_begin.strip()
        else:
            begin = ''
        if not begin:
            return None
        try:
            dt_obj = dt.datetime.strptime(begin, '%Y-%m-%d')
        except ValueError:
            return None
        return dt_obj.replace(tzinfo=dt.timezone.utc).timestamp()

    def _ffprobe_capture_epoch(path: Path) -> float | None:
        data = _run_ffprobe(path)
        if not data:
            return None
        tags = _collect_tags(data)
        iso_ts = _extract_timestamp(tags)
        if not iso_ts:
            return None
        text = iso_ts.strip()
        if text.endswith('Z'):
            text = text[:-1] + '+00:00'
        try:
            dt_obj = dt.datetime.fromisoformat(text)
        except ValueError:
            return None
        if dt_obj.tzinfo is None:
            dt_obj = dt_obj.replace(tzinfo=dt.timezone.utc)
        else:
            dt_obj = dt_obj.astimezone(dt.timezone.utc)
        return dt_obj.timestamp()

    def _kickoff_proxy_generation() -> None:
        cfg_local = load_config()
        previews = (cfg_local.get('previews') or {})
        if not previews.get('enabled', True):
            return
        max_cache_bytes = previews.get('max_cache_gb', 50) * 1_000_000_000
        height = previews.get('video_height', 480)
        bitrate = str(previews.get('video_bitrate', '1200k'))
        encoder = str(previews.get('video_encoder', 'auto') or 'auto')

        def _run():
            with proxy_lock:
                try:
                    generate_for_folder(
                        paths.trip_root(),
                        paths.proxies_dir(),
                        max_cache_bytes,
                        prefer_gopro_thm=True,
                        height=height,
                        bitrate=bitrate,
                        encoder=encoder,
                        progress_cb=None,
                    )
                except Exception:
                    pass

        proxy_executor.submit(_run)

    def _resolve_trip_path(rel: str) -> tuple[Path, str]:
        rel = (rel or '').strip()
        if not rel:
            raise ValueError('empty path')
        candidate = (trip_root / rel).resolve()
        try:
            canonical = candidate.relative_to(trip_root).as_posix()
        except ValueError as exc:
            raise ValueError('path outside trip root') from exc
        return candidate, canonical

    def _resolve_trash_path(rel: str) -> Path:
        rel = (rel or '').strip()
        if not rel:
            raise ValueError('empty path')
        candidate = (trash_root / rel).resolve()
        try:
            candidate.relative_to(trash_root)
        except ValueError as exc:
            raise ValueError('path outside trash root') from exc
        return candidate

    def _is_inside_trash(path: Path) -> bool:
        try:
            rel = path.relative_to(trip_root)
        except ValueError:
            return False
        return len(rel.parts) > 0 and rel.parts[0] == '.trash'

    def _trash_meta_path(trash_id: str) -> Path:
        return trash_meta_dir / f'{trash_id}.json'

    def _infer_kind(path: Path) -> str:
        suffix = path.suffix.lower()
        if suffix in PHOTO_EXTS:
            return 'photo'
        if suffix in VIDEO_EXTS:
            return 'video'
        return 'file'

    def _format_size(num: int | None) -> str | None:
        if num is None:
            return None
        units = ['B', 'KB', 'MB', 'GB', 'TB']
        value = float(num)
        for unit in units:
            if value < 1024 or unit == units[-1]:
                if unit == 'B':
                    return f'{int(value)} {unit}'
                return f'{value:.1f} {unit}'
            value = value / 1024.0
        return f'{num} B'

    def _cleanup_empty_dirs(start: Path, boundary: Path) -> None:
        try:
            boundary_resolved = boundary.resolve()
        except Exception:
            return
        cur = start
        while True:
            try:
                cur_resolved = cur.resolve()
            except FileNotFoundError:
                break
            if cur_resolved == boundary_resolved:
                break
            if not cur.exists() or not cur.is_dir():
                break
            try:
                cur.rmdir()
            except OSError:
                break
            cur = cur.parent
            try:
                cur.resolve().relative_to(boundary_resolved)
            except ValueError:
                break

    def _move_file_to_trash(path: Path, original_rel: str) -> dict:
        original_rel = Path(original_rel).as_posix()
        stored_path = trash_root / original_rel
        original_rel_path = Path(original_rel)
        counter = 1
        while stored_path.exists():
            suffix = original_rel_path.suffix
            base_name = original_rel_path.stem
            new_name = f"{base_name}-trash{counter}{suffix}"
            candidate_rel = original_rel_path.with_name(new_name).as_posix()
            stored_path = trash_root / candidate_rel
            counter += 1
        stored_path.parent.mkdir(parents=True, exist_ok=True)
        original_parent = path.parent
        shutil.move(str(path), str(stored_path))
        trash_id = uuid.uuid4().hex
        try:
            size = stored_path.stat().st_size
        except OSError:
            size = None
        meta = {
            'original_rel': original_rel,
            'stored_rel': stored_path.relative_to(trash_root).as_posix(),
            'trashed_at': dt.datetime.utcnow().replace(microsecond=0).isoformat() + 'Z',
            'size': size,
            'kind': _infer_kind(stored_path),
        }
        _trash_meta_path(trash_id).write_text(json.dumps(meta))
        _cleanup_empty_dirs(original_parent, trip_root)
        return {'id': trash_id, **meta}

    def _restore_trash_entry(trash_id: str) -> tuple[bool, str | None]:
        meta_path = _trash_meta_path(trash_id)
        if not meta_path.exists():
            return False, 'not_found'
        try:
            data = json.loads(meta_path.read_text())
        except Exception:
            data = {}
        stored_rel = data.get('stored_rel')
        original_rel = data.get('original_rel') or stored_rel
        if not stored_rel or not original_rel:
            return False, 'invalid'
        try:
            stored_path = _resolve_trash_path(stored_rel)
        except Exception:
            stored_path = None
        if not stored_path or not stored_path.exists():
            try:
                meta_path.unlink()
            except Exception:
                pass
            return False, 'missing'
        try:
            dest_path, canonical_rel = _resolve_trip_path(original_rel)
        except ValueError:
            return False, 'invalid'
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        if dest_path.exists():
            return False, 'exists'
        shutil.move(str(stored_path), str(dest_path))
        _cleanup_empty_dirs(stored_path.parent, trash_root)
        try:
            meta_path.unlink()
        except Exception:
            pass
        return True, canonical_rel

    def _delete_trash_entry(trash_id: str) -> bool:
        meta_path = _trash_meta_path(trash_id)
        if not meta_path.exists():
            return False
        try:
            data = json.loads(meta_path.read_text())
        except Exception:
            data = {}
        stored_rel = data.get('stored_rel')
        try:
            stored_path = _resolve_trash_path(stored_rel)
        except Exception:
            stored_path = None
        if stored_path and stored_path.exists():
            try:
                if stored_path.is_file():
                    stored_path.unlink()
                else:
                    shutil.rmtree(stored_path)
            except Exception:
                pass
            _cleanup_empty_dirs(stored_path.parent, trash_root)
        try:
            meta_path.unlink()
        except Exception:
            return False
        return True

    def _load_trash_entries() -> list[dict]:
        entries: list[dict] = []
        for meta_path in sorted(trash_meta_dir.glob('*.json')):
            trash_id = meta_path.stem
            try:
                data = json.loads(meta_path.read_text())
            except Exception:
                continue
            stored_rel = data.get('stored_rel')
            original_rel = data.get('original_rel') or stored_rel
            if not stored_rel:
                continue
            try:
                stored_path = _resolve_trash_path(stored_rel)
            except Exception:
                try:
                    meta_path.unlink()
                except Exception:
                    pass
                continue
            if not stored_path.exists():
                try:
                    meta_path.unlink()
                except Exception:
                    pass
                continue
            try:
                size = data.get('size') or stored_path.stat().st_size
            except OSError:
                size = data.get('size')
            entry = {
                'id': trash_id,
                'stored_rel': stored_path.relative_to(trash_root).as_posix(),
                'original_rel': Path(original_rel).as_posix() if original_rel else stored_rel,
                'trashed_at': data.get('trashed_at'),
                'kind': data.get('kind') or _infer_kind(stored_path),
                'size': size,
                'size_display': _format_size(size),
                'filename': Path(original_rel or stored_rel).name,
            }
            entries.append(entry)
        entries.sort(key=lambda e: e.get('trashed_at') or '', reverse=True)
        return entries

    @app.get('/trash')
    def trash_page():
        entries = _load_trash_entries()
        for entry in entries:
            folder = Path(entry['original_rel']).parent.as_posix()
            entry['folder'] = folder if folder and folder != '.' else None
            entry['trashed_at_display'] = _format_timestamp(entry.get('trashed_at'))
        status = {
            'restored': request.args.get('restored'),
            'deleted': request.args.get('deleted'),
            'error': request.args.get('error'),
        }
        if status['error']:
            cur_cfg = load_config()
            lang = (cur_cfg.get('language') or 'en').lower()
            key = f"web.trash.error_{status['error']}"
            message = tr(lang, key)
            if message == key:
                message = tr(lang, 'web.trash.notice_error', code=status['error'])
            status['error_message'] = message
        else:
            status['error_message'] = None
        return render_template('trash.html', entries=entries, status=status)

    @app.get('/api/trash')
    def api_trash_list():
        entries = _load_trash_entries()
        result = []
        for entry in entries:
            folder = Path(entry['original_rel']).parent.as_posix()
            result.append({
                'id': entry['id'],
                'stored_rel': entry['stored_rel'],
                'original_rel': entry['original_rel'],
                'folder': folder if folder and folder != '.' else None,
                'trashed_at': entry.get('trashed_at'),
                'trashed_at_display': _format_timestamp(entry.get('trashed_at')),
                'kind': entry.get('kind'),
                'size': entry.get('size'),
                'size_display': entry.get('size_display'),
                'filename': entry.get('filename'),
            })
        return jsonify({'entries': result})

    @app.get('/trash/download')
    def trash_download():
        trash_id = request.args.get('id')
        if not trash_id:
            return 'missing id', 400
        meta_path = _trash_meta_path(trash_id)
        if not meta_path.exists():
            return 'not found', 404
        try:
            data = json.loads(meta_path.read_text())
        except Exception:
            return 'not found', 404
        stored_rel = data.get('stored_rel')
        original_rel = data.get('original_rel') or stored_rel
        if not stored_rel:
            return 'not found', 404
        try:
            stored_path = _resolve_trash_path(stored_rel)
        except Exception:
            return 'not found', 404
        if not stored_path.exists():
            return 'not found', 404
        download_name = Path(original_rel or stored_path.name).name
        return send_file(stored_path, as_attachment=True, download_name=download_name)

    @app.post('/trash/restore')
    def trash_restore():
        trash_id = request.form.get('id')
        if not trash_id:
            return 'missing id', 400
        ok, reason = _restore_trash_entry(trash_id)
        if ok:
            return redirect(url_for('trash_page', restored=trash_id))
        return redirect(url_for('trash_page', error=reason or 'error', target=trash_id))

    @app.post('/api/trash/restore')
    def api_trash_restore():
        payload = request.get_json(silent=True) or {}
        trash_id = (payload.get('id') or '').strip()
        if not trash_id:
            return jsonify({'error': 'missing_id'}), 400
        ok, reason = _restore_trash_entry(trash_id)
        if ok:
            return jsonify({'status': 'restored'})
        return jsonify({'error': reason or 'restore_failed'}), 400

    @app.post('/trash/purge')
    def trash_purge():
        trash_id = request.form.get('id')
        if not trash_id:
            return 'missing id', 400
        ok = _delete_trash_entry(trash_id)
        if ok:
            return redirect(url_for('trash_page', deleted=trash_id))
        return redirect(url_for('trash_page', error='delete_failed', target=trash_id))

    @app.post('/api/trash/purge')
    def api_trash_purge():
        payload = request.get_json(silent=True) or {}
        trash_id = (payload.get('id') or '').strip()
        if not trash_id:
            return jsonify({'error': 'missing_id'}), 400
        ok = _delete_trash_entry(trash_id)
        if ok:
            return jsonify({'status': 'deleted'})
        return jsonify({'error': 'delete_failed'}), 400

    @app.context_processor
    def inject_i18n():
        cur_cfg = load_config()
        cur_lang = (cur_cfg.get('language') or 'en').lower()
        return {
            'lang': cur_lang,
            't': lambda key, **kwargs: tr(cur_lang, key, **kwargs),
        }

    # Serve Flutter web app
    @app.get('/flutter')
    def flutter_app():
        flutter_build_dir = Path(__file__).parent.parent.parent / 'flutter_frontend' / 'build' / 'web'
        index_path = flutter_build_dir / 'index.html'
        if index_path.exists():
            return send_file(index_path)
        return 'Flutter app not found', 404
    
    @app.get('/flutter/<path:filename>')
    def flutter_static(filename):
        flutter_build_dir = Path(__file__).parent.parent.parent / 'flutter_frontend' / 'build' / 'web'
        file_path = flutter_build_dir / filename
        if file_path.exists() and file_path.is_file():
            return send_file(file_path)
        return 'File not found', 404

    @app.get('/')
    def home():
        # Photo of the day: latest photo if available
        root = paths.photos_dir()
        photos = [p for p in _iter_media(root, PHOTO_EXTS)]
        latest = None
        if photos:
            latest = max(photos, key=lambda p: p.stat().st_mtime)
        potd_url = None
        potd_download = None
        if latest:
            rel = str(latest.relative_to(paths.trip_root()))
            potd_url = url_for('preview_photo', p=rel)
            potd_download = url_for('download', p=rel)
        # Camping fact of the day (static file, offline, per language)
        fact = ''
        cfg = load_config()
        lang = (cfg.get('language') or 'en').lower()
        base_dir = Path(__file__).parent
        candidates = [
            base_dir / f'camping_facts.{lang}.txt',
            base_dir / 'camping_facts.en.txt',
            base_dir / 'camping_facts.txt',
        ]
        facts_file = next((p for p in candidates if p.exists()), base_dir / 'camping_facts.txt')
        try:
            import random
            lines = [l.strip() for l in facts_file.read_text().splitlines() if l.strip()]
            if lines:
                fact = random.choice(lines)
        except Exception:
            fact = ''
        return render_template('home.html', potd_url=potd_url, potd_download=potd_download, camping_fact=fact)

    def _iter_media(root: Path, suffixes: set[str]):
        for dp, dirnames, files in os.walk(root):
            base = Path(dp)
            if _is_inside_trash(base):
                dirnames[:] = []
                continue
            clean_dirs = []
            for dirname in dirnames:
                candidate = base / dirname
                if not _is_inside_trash(candidate):
                    clean_dirs.append(dirname)
            dirnames[:] = clean_dirs
            for fn in files:
                p = base / fn
                if _is_inside_trash(p):
                    continue
                if p.suffix.lower() in suffixes:
                    yield p

    PHOTO_EXTS = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.rw2', '.cr2', '.nef', '.raf', '.dng', '.arw'}
    VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}

    def _attach_transcript_metadata(records: list[dict]) -> None:
        if not records:
            return
        rel_paths = [rec.get('path') for rec in records if rec.get('path')]
        if not rel_paths:
            for rec in records:
                rec['transcript_available'] = False
                rec['transcript_state'] = None
                rec['transcript_language'] = None
            return
        try:
            transcript_map = transcription_queue.get_many(rel_paths)
        except Exception:
            transcript_map = {}
        for rec in records:
            status = transcript_map.get(rec.get('path') or '') or {}
            transcript_text = status.get('transcript') if isinstance(status, dict) else None
            rec['transcript_available'] = bool(transcript_text)
            rec['transcript_state'] = status.get('state') if isinstance(status, dict) else None
            rec['transcript_language'] = status.get('language') if isinstance(status, dict) else None

    def _format_timestamp(ts: str | None) -> str | None:
        if not ts:
            return None
        text = ts.strip()
        if text.endswith('Z'):
            text = text[:-1] + '+00:00'
        try:
            dt_obj = dt.datetime.fromisoformat(text)
        except ValueError:
            return ts
        if dt_obj.tzinfo is not None:
            dt_obj = dt_obj.astimezone(dt.timezone.utc)
        return dt_obj.strftime('%Y-%m-%d %H:%M')

    def _serialize_meta(meta: VideoMetadata | None, fallback_path: str | None = None) -> dict:
        path = meta.path if meta else fallback_path
        location_parts = []
        if meta and meta.city:
            location_parts.append(meta.city)
        if meta and meta.country_code:
            location_parts.append(meta.country_code)
        location_label = ', '.join(location_parts) if location_parts else None
        filename = Path(path).name if path else None
        parent = Path(path).parent.as_posix() if path else None
        if parent == '.':
            parent = None
        size_bytes: int | None = None
        size_display: str | None = None
        if path:
            try:
                file_path = paths.trip_root() / path
                size_bytes = file_path.stat().st_size
                size_display = _format_size(size_bytes)
            except OSError:
                size_bytes = None
                size_display = None
        return {
            'path': path,
            'filename': filename,
            'folder': parent,
            'captured_at': meta.captured_at if meta else None,
            'captured_at_display': _format_timestamp(meta.captured_at if meta else None),
            'lat': meta.lat if meta else None,
            'lon': meta.lon if meta else None,
            'alt': meta.alt if meta else None,
            'city': meta.city if meta else None,
            'admin': meta.admin if meta else None,
            'country_code': meta.country_code if meta else None,
            'has_gps': meta.has_gps if meta else False,
            'location_label': location_label,
            'duration_sec': meta.duration_sec if meta else None,
            'size_bytes': size_bytes,
            'size_display': size_display,
        }

    def _serialize_suggestion(suggestion: LocationSuggestion) -> dict:
        return {
            'label': suggestion.label,
            'query': suggestion.query,
        }

    @app.get('/api/stats')
    def api_stats():
        cfg_local = load_config()
        stats = collect_trip_media_stats(cfg_local, paths)
        return jsonify({
            'trip_name': stats.trip_name,
            'video_seconds': stats.video_seconds,
            'video_duration_label': stats.video_duration_label,
            'photo_count': stats.photo_count,
            'free_bytes': stats.free_bytes,
            'device_names': stats.device_names,
            'generated_at': _now_iso(),
        })

    @app.get('/api/health')
    def api_health():
        cfg_local = load_config()
        probe_buttons_arg = (request.args.get('probe_buttons') or '1').lower()
        probe_buttons = probe_buttons_arg not in {'0', 'false', 'no'}
        summary = collect_health(paths, cfg_local, probe_buttons=probe_buttons)
        return jsonify(summary)

    @app.get('/api/backup/status')
    def api_backup_status():
        return jsonify(_get_backup_state())

    @app.post('/api/backup/start')
    def api_backup_start():
        nonlocal backup_thread
        with backup_lock:
            if backup_thread and backup_thread.is_alive():
                return jsonify({'status': 'running', 'state': _get_backup_state()}), 409

        cfg_local = load_config()
        ensure_usb_mounted()
        matches = find_source_mounts(cfg_local.get('paths', {}).get('source_roots', []))
        filtered: list[Path] = []
        for candidate in matches:
            try:
                if candidate.resolve() == paths.nvme_mount.resolve():
                    continue
            except Exception:
                pass
            filtered.append(candidate)
        matches = filtered

        if not matches:
            _set_backup_state(
                phase='idle',
                progress=0.0,
                copied_files=0,
                total_files=0,
                bytes_copied=0,
                message='No source detected',
                can_cancel=False,
                errors=[],
                skipped_files=0,
                replaced_files=0,
                previews_done=0,
                previews_total=0,
                eta=None,
                speed=None,
                current_file=None,
            )
            return jsonify({'status': 'error', 'reason': 'no_source'}), 400
        if len(matches) > 1:
            _set_backup_state(
                phase='idle',
                message='Multiple sources detected',
                can_cancel=False,
                errors=[],
                copied_files=0,
                total_files=0,
                bytes_copied=0,
                skipped_files=0,
                replaced_files=0,
                previews_done=0,
                previews_total=0,
                eta=None,
                speed=None,
                current_file=None,
            )
            return jsonify({
                'status': 'error',
                'reason': 'multiple_sources',
                'candidates': [str(m) for m in matches],
            }), 409

        source = matches[0]
        _set_backup_state(
            phase='preparing',
            progress=0.0,
            copied_files=0,
            total_files=0,
            bytes_copied=0,
            device_label=source.name,
            message=f'Preparing backup from {source.name}',
            errors=[],
            can_cancel=False,
            skipped_files=0,
            replaced_files=0,
            eta=None,
            speed=None,
            previews_done=0,
            previews_total=0,
            current_file=None,
        )

        def _worker() -> None:
            nonlocal backup_thread
            cfg_thread = load_config()
            total_tracker = {'total': 0}
            start_ts = time.monotonic()

            def _format_rate(bytes_per_second: float) -> str | None:
                if bytes_per_second <= 0:
                    return None
                units = ['B/s', 'KB/s', 'MB/s', 'GB/s', 'TB/s']
                value = bytes_per_second
                unit = units[0]
                for candidate in units[1:]:
                    if value >= 1024:
                        value /= 1024
                        unit = candidate
                    else:
                        break
                precision = 1 if value < 100 else 0
                return f"{value:.{precision}f} {unit}"

            def _format_eta(seconds: float | None) -> str | None:
                if seconds is None or seconds <= 0:
                    return None
                minutes, sec = divmod(int(seconds + 0.5), 60)
                hours, minutes = divmod(minutes, 60)
                if hours > 0:
                    return f"{hours}h {minutes:02}m"
                if minutes > 0:
                    return f"{minutes}m {sec:02}s"
                return f"{sec}s"

            def progress_cb(progress: CopyProgress) -> None:
                total_tracker['total'] = max(total_tracker['total'], progress.total)
                fraction = progress.index / progress.total if progress.total else 0.0
                elapsed = max(time.monotonic() - start_ts, 0.1)
                speed = progress.bytes_copied / elapsed if progress.bytes_copied > 0 else 0.0
                effective_copied = max(progress.copied_files + progress.replaced_files, 0)
                avg_bytes = (progress.bytes_copied / effective_copied) if effective_copied > 0 else None
                remaining_files = max(progress.total - progress.index, 0)
                remaining_bytes = (avg_bytes * remaining_files) if (avg_bytes and remaining_files) else None
                eta_seconds = (remaining_bytes / speed) if (remaining_bytes and speed > 0) else None
                _set_backup_state(
                    phase='copying',
                    progress=fraction,
                    copied_files=progress.copied_files,
                    total_files=progress.total,
                    bytes_copied=progress.bytes_copied,
                    device_label=source.name,
                    message=(
                        f"Copying files ({progress.copied_files}/{progress.total})"
                        if progress.total
                        else 'Copying files'
                    ),
                    speed=_format_rate(speed),
                    eta=_format_eta(eta_seconds),
                    skipped_files=progress.skipped_files,
                    replaced_files=progress.replaced_files,
                    current_file=(progress.current_path.name if progress.current_path else None),
                )

            try:
                # Ensure all necessary directories exist with correct permissions
                paths.ensure()
                
                verify_mode = (cfg_thread.get('verify') or {}).get('default_mode', 'fast')
                result = copy_from_source(
                    source,
                    paths,
                    verify_mode=verify_mode,
                    progress_cb=progress_cb,
                )
                total_files = max(total_tracker['total'], result.copied_files + result.skipped_files + result.replaced_files)
                if result.errors:
                    _set_backup_state(
                        phase='error',
                        progress=1.0 if total_files else 0.0,
                        copied_files=result.copied_files,
                        total_files=total_files,
                        bytes_copied=result.bytes_copied,
                        device_label=result.device_name,
                        message=result.errors[0] if result.errors else 'Backup failed',
                        errors=result.errors,
                        can_cancel=False,
                        skipped_files=result.skipped_files,
                        replaced_files=result.replaced_files,
                        speed=None,
                        eta=None,
                        current_file=None,
                        previews_done=0,
                        previews_total=0,
                    )
                    return

                _set_backup_state(
                    phase='verifying',
                    progress=0.95,
                    copied_files=result.copied_files,
                    total_files=total_files,
                    bytes_copied=result.bytes_copied,
                    device_label=result.device_name,
                    message='Generating previews',
                    can_cancel=False,
                    skipped_files=result.skipped_files,
                    replaced_files=result.replaced_files,
                    speed=None,
                    eta=None,
                    current_file=None,
                    previews_done=0,
                    previews_total=0,
                )

                previews_cfg = cfg_thread.get('previews') or {}
                if previews_cfg.get('enabled', True):
                    max_cache_bytes = previews_cfg.get('max_cache_gb', 50) * 1_000_000_000
                    height = previews_cfg.get('video_height', 480)
                    bitrate = str(previews_cfg.get('video_bitrate', '1200k'))
                    encoder = str(previews_cfg.get('video_encoder', 'auto') or 'auto')
                    background_priority = bool(previews_cfg.get('background_priority', True))

                    def proxy_progress(done: int, total: int, _path: Path, _kind: str) -> None:
                        fraction = done / total if total else 1.0
                        _set_backup_state(
                            phase='verifying',
                            progress=0.95 + 0.05 * fraction,
                            message=f'Generating previews ({done}/{total})' if total else 'Generating previews',
                            previews_done=done,
                            previews_total=total,
                        )

                    try:
                        generate_for_folder(
                            paths.trip_root(),
                            paths.proxies_dir(),
                            max_cache_bytes,
                            prefer_gopro_thm=True,
                            height=height,
                            bitrate=bitrate,
                            encoder=encoder,
                            background_priority=background_priority,
                            progress_cb=proxy_progress,
                        )
                    except Exception as exc:
                        _set_backup_state(
                            phase='error',
                            message=f'Preview generation failed: {exc}',
                            errors=[f'Preview generation failed: {exc}'],
                            can_cancel=False,
                            previews_done=0,
                            previews_total=0,
                            current_file=None,
                        )
                        return

                _set_backup_state(
                    phase='done',
                    progress=1.0,
                    copied_files=result.copied_files,
                    total_files=total_files,
                    bytes_copied=result.bytes_copied,
                    device_label=result.device_name,
                    message=f'Backup complete ({result.copied_files} new files)',
                    can_cancel=False,
                    skipped_files=result.skipped_files,
                    replaced_files=result.replaced_files,
                    previews_done=result.copied_files + result.replaced_files,
                    previews_total=result.copied_files + result.replaced_files,
                )
            except Exception as exc:
                _set_backup_state(
                    phase='error',
                    message=f'Backup failed: {exc}',
                    errors=[str(exc)],
                    can_cancel=False,
                    current_file=None,
                )
            finally:
                with backup_lock:
                    backup_thread = None

        thread = threading.Thread(target=_worker, name='backup-worker', daemon=True)
        with backup_lock:
            backup_thread = thread
        thread.start()
        return jsonify({'status': 'running'})

    @app.post('/api/backup/cancel')
    def api_backup_cancel():
        state = _get_backup_state()
        if state.get('phase') not in {'preparing', 'copying', 'verifying', 'cancelling'}:
            return jsonify({'status': 'idle'})
        return jsonify({'status': 'not_supported'})

    @app.post('/api/transcription/start')
    def api_transcription_start():
        try:
            # Queue all video files for transcription
            root = paths.trip_root()
            video_files = list(_iter_media(root, VIDEO_EXTS))
            
            queued_count = 0
            for video_file in video_files:
                rel_path = str(video_file.relative_to(paths.trip_root()))
                try:
                    # Check if already transcribed
                    existing = transcription_queue.get(rel_path)
                    if existing and existing.get('transcript'):
                        continue  # Skip already transcribed files
                    
                    # Queue for transcription (pass Path object, not string)
                    transcription_queue.enqueue(video_file)
                    queued_count += 1
                except Exception as e:
                    print(f"Failed to queue {rel_path}: {e}")
                    continue  # Skip files that can't be queued
            
            return jsonify({
                'status': 'started',
                'queued_files': queued_count,
                'total_files': len(video_files),
                'message': f'Queued {queued_count} videos for transcription'
            })
        except Exception as exc:
            return jsonify({
                'status': 'error',
                'message': f'Failed to start transcription: {exc}'
            }), 500

    @app.post('/api/transcription/delete')
    def api_transcription_delete():
        rel = request.form.get('p') or request.json.get('p') if request.is_json else None
        if not rel:
            return jsonify({'error': 'missing p'}), 400
        try:
            _, canonical = _resolve_trip_path(rel)
        except ValueError:
            return jsonify({'error': 'invalid path'}), 400
        
        deleted = transcription_queue.delete_transcript(canonical)
        if deleted:
            return jsonify({'status': 'deleted', 'path': canonical})
        return jsonify({'status': 'not_found', 'path': canonical}), 404

    @app.get('/api/photos')
    def api_photos():
        root = paths.photos_dir()
        items = [str(p.relative_to(paths.trip_root())) for p in _iter_media(root, PHOTO_EXTS)]
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        start = (page - 1) * size
        end = start + size
        return jsonify({
            'page': page,
            'page_size': size,
            'total': len(items),
            'items': items[start:end],
        })

    @app.get('/api/videos')
    def api_videos():
        q = (request.args.get('q') or '').strip()
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        suggestions = metadata_index.location_suggestions()
        if q:
            records, total = metadata_index.search(q, page, size)
            payload = [_serialize_meta(meta) for meta in records]
            _attach_transcript_metadata(payload)
            return jsonify({
                'page': page,
                'page_size': size,
                'total': total,
                'items': [meta['path'] for meta in payload],
                'records': payload,
                'query': q,
                'suggestions': [_serialize_suggestion(s) for s in suggestions],
            })

        root = paths.trip_root()
        files = [p for p in _iter_media(root, VIDEO_EXTS)]
        files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        total = len(files)
        start = max(0, (page - 1) * size)
        end = start + size
        page_files = files[start:end]
        meta_map = metadata_index.ensure_for_paths(page_files)
        items: list[str] = []
        payload: list[dict] = []
        for file in page_files:
            rel = str(file.relative_to(paths.trip_root()))
            items.append(rel)
            payload.append(_serialize_meta(meta_map.get(rel), rel))
        _attach_transcript_metadata(payload)
        return jsonify({
            'page': page,
            'page_size': size,
            'total': total,
            'items': items,
            'records': payload,
            'query': q,
            'suggestions': [_serialize_suggestion(s) for s in suggestions],
        })

    @app.get('/photos')
    def photos():
        root = paths.photos_dir()
        items = [str(p.relative_to(paths.trip_root())) for p in _iter_media(root, PHOTO_EXTS)]
        items.sort(key=lambda s: (paths.trip_root()/s).stat().st_mtime, reverse=True)
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        start = (page - 1) * size
        end = start + size
        page_items = items[start:end]
        return render_template('photos.html', items=page_items, page=page)

    @app.post('/upload')
    def upload():
        # Accept multiple files from mobile photo picker
        allowed = {'.jpg', '.jpeg', '.png', '.heic', '.heif'}
        from werkzeug.utils import secure_filename
        dest = paths.photos_dir()
        files = request.files.getlist('files') or []
        saved = 0
        for f in files:
            if not f or not getattr(f, 'filename', ''):
                continue
            name = secure_filename(f.filename)
            ext = (Path(name).suffix or '').lower()
            if ext not in allowed:
                continue
            base = Path(name).stem
            target = dest / (base + ext)
            # Ensure unique filename if conflict
            counter = 1
            while target.exists():
                target = dest / (f"{base}-{counter}{ext}")
                counter += 1
            try:
                f.save(target)
                saved += 1
            except Exception:
                # Skip on failure of a file, continue others
                pass
        # Redirect back to the photos page
        ref = request.headers.get('Referer')
        return redirect(ref or url_for('photos'))

    @app.post('/videos/upload')
    def upload_videos():
        from werkzeug.utils import secure_filename
        cfg_local = load_config()
        verify_mode = cfg_local['verify']['default_mode']
        upload_label = (cfg_local.get('web', {}) or {}).get('upload_device_label', 'Uploads')
        begin_ts = _trip_begin_timestamp(cfg_local)
        allowed_exts = set(BACKUP_VIDEO_EXTS)
        max_size_mb = int((cfg_local.get('web', {}) or {}).get('upload_max_mb', 8192))
        size_limit = max_size_mb * 1_000_000 if max_size_mb > 0 else None
        files = request.files.getlist('files') or []
        if not files:
            return jsonify({'status': 'error', 'message': 'no_files'}), 400

        results: list[dict] = []
        for storage in files:
            if not storage or not getattr(storage, 'filename', ''):
                results.append({'filename': '', 'status': 'error', 'reason': 'empty'})
                continue
            name = secure_filename(storage.filename)
            ext = (Path(name).suffix or '').lower()
            if ext not in allowed_exts:
                results.append({'filename': name, 'status': 'error', 'reason': 'unsupported'})
                continue
            try:
                storage.stream.seek(0, os.SEEK_END)
                size = storage.stream.tell()
                storage.stream.seek(0)
            except Exception:
                size = None
            if size_limit and size and size > size_limit:
                results.append({'filename': name, 'status': 'error', 'reason': 'too_large'})
                continue

            temp_dir = Path(tempfile.mkdtemp(prefix='upload_', dir=incoming_root))
            temp_path = temp_dir / name
            try:
                storage.save(temp_path)
            except Exception:
                shutil.rmtree(temp_dir, ignore_errors=True)
                results.append({'filename': name, 'status': 'error', 'reason': 'save_failed'})
                continue

            capture_epoch = _ffprobe_capture_epoch(temp_path)
            target_epoch = capture_epoch or temp_path.stat().st_mtime
            if begin_ts is not None and capture_epoch is not None and capture_epoch < begin_ts:
                shutil.rmtree(temp_dir, ignore_errors=True)
                results.append({'filename': name, 'status': 'skipped', 'reason': 'before_trip'})
                continue
            try:
                os.utime(temp_path, (target_epoch, target_epoch))
            except Exception:
                pass

            try:
                copy_res = copy_from_source(
                    temp_dir,
                    paths,
                    verify_mode=verify_mode,
                    allowed_exts=BACKUP_VIDEO_EXTS,
                    min_timestamp=begin_ts,
                    device_label_override=upload_label,
                )
            except Exception:
                copy_res = None

            shutil.rmtree(temp_dir, ignore_errors=True)

            if not copy_res:
                results.append({'filename': name, 'status': 'error', 'reason': 'copy_failed'})
                continue
            if copy_res.errors:
                results.append({'filename': name, 'status': 'error', 'reason': copy_res.errors[0]})
                continue
            if copy_res.copied_files or copy_res.replaced_files:
                _kickoff_proxy_generation()
                results.append({'filename': name, 'status': 'uploaded'})
                continue
            if copy_res.skipped_files:
                results.append({'filename': name, 'status': 'skipped', 'reason': 'duplicate'})
                continue
            results.append({'filename': name, 'status': 'skipped', 'reason': 'filtered'})

        return jsonify({'status': 'ok', 'results': results})

    @app.get('/videos')
    def videos():
        q = (request.args.get('q') or '').strip()
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        suggestions = metadata_index.location_suggestions()

        if q:
            records, total = metadata_index.search(q, page, size)
            items = [_serialize_meta(meta) for meta in records]
        else:
            root = paths.trip_root()
            files = [p for p in _iter_media(root, VIDEO_EXTS)]
            files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            total = len(files)
            start = max(0, (page - 1) * size)
            end = start + size
            page_files = files[start:end]
            meta_map = metadata_index.ensure_for_paths(page_files)
            items = []
            for file in page_files:
                rel = str(file.relative_to(paths.trip_root()))
                items.append(_serialize_meta(meta_map.get(rel), rel))

        _attach_transcript_metadata(items)

        page_count = max(1, (total + size - 1) // size) if total else 1
        has_prev = page > 1
        has_next = page < page_count

        return render_template(
            'videos.html',
            items=items,
            page=page,
            page_size=size,
            total=total,
            page_count=page_count,
            has_prev=has_prev,
            has_next=has_next,
            query=q,
            suggestions=[_serialize_suggestion(s) for s in suggestions],
        )

    @app.get('/preview/photo')
    def preview_photo():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        from ..proxies.generate import thumb_name_for
        path = paths.trip_root() / rel
        thumb = thumb_name_for(path, paths.proxies_dir())
        if thumb.exists():
            return send_file(thumb)
        # fallback to original
        if path.exists():
            return send_file(path)
        return 'not found', 404

    @app.get('/preview/video')
    def preview_video():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        from ..proxies.generate import proxy_name_for
        path = paths.trip_root() / rel
        proxy = proxy_name_for(path, paths.proxies_dir())
        if proxy.exists():
            return send_file(proxy)
        return 'not found', 404

    @app.get('/preview/video_thumb')
    def preview_video_thumb():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        from ..proxies.generate import thumb_name_for
        path = paths.trip_root() / rel
        thumb = thumb_name_for(path, paths.proxies_dir())
        if thumb.exists():
            return send_file(thumb)
        return 'not found', 404

    @app.get('/download')
    def download():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        path = paths.trip_root() / rel
        if not path.exists():
            return 'not found', 404
        return send_file(path, as_attachment=True)

    @app.get('/transcript')
    def download_transcript():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        try:
            _, canonical = _resolve_trip_path(rel)
        except ValueError:
            return 'invalid path', 400
        try:
            record = transcription_queue.get(canonical)
        except Exception:
            record = None
        if not record:
            return 'not found', 404
        content = _render_srt_from_record(record)
        if not content:
            return 'not found', 404
        filename = Path(canonical).with_suffix('.srt').name
        stream = io.BytesIO(content.encode('utf-8'))
        stream.seek(0)
        return send_file(stream, mimetype='application/x-subrip', as_attachment=True, download_name=filename)

    def _render_settings_form(cfg: dict) -> str:
        return render_template('settings.html', cfg=cfg)

    def _apply_flat_updates(cfg: dict, updates: dict) -> dict:
        for k, v in updates.items():
            path = k.split('.')
            cur = cfg
            for key in path[:-1]:
                cur = cur.setdefault(key, {})
            # try int cast for known numeric fields
            if path[-1] in {'page_size', 'max_cache_gb'}:
                try:
                    v = int(v)
                except Exception:
                    pass
            # parse comma-separated list for trip.places
            if k == 'trip.places':
                items = [p.strip() for p in (v or '').split(',') if p.strip()]
                v = items
            cur[path[-1]] = v
        return cfg

    def _deep_merge(base: dict, updates: dict) -> dict:
        result = dict(base)
        for key, value in (updates or {}).items():
            if isinstance(value, dict) and isinstance(result.get(key), dict):
                result[key] = _deep_merge(result.get(key, {}), value)
            else:
                result[key] = value
        return result

    @app.get('/api/config')
    def api_get_config():
        cfg_local = load_config()
        return jsonify(cfg_local)

    @app.route('/api/config', methods=['PUT', 'PATCH'])
    def api_update_config():
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify({'error': 'invalid JSON payload'}), 400
        cfg_local = load_config()
        merged = _deep_merge(cfg_local, payload)
        save_config(merged)
        return jsonify(merged)

    @app.get('/api/media/last-location')
    def api_last_media_location():
        latest = metadata_index.latest_with_location()
        if not latest:
            return jsonify({'error': 'not found'}), 404
        meta, row = latest
        return jsonify({
            'path': meta.path,
            'captured_at': meta.captured_at,
            'latitude': meta.lat,
            'longitude': meta.lon,
            'altitude': meta.alt,
            'city': meta.city,
            'admin': meta.admin,
            'country_code': meta.country_code,
            'location_slug': (row or {}).get('location_slug'),
        })

    @app.route('/settings', methods=['GET', 'POST'])
    def settings_page():
        cfg = load_config()
        if request.method == 'POST':
            if request.is_json:
                cfg.update(request.json or {})
            else:
                updates = {k: v for k, v in request.form.items()}
                cfg = _apply_flat_updates(cfg, updates)
            save_config(cfg)
            return redirect(url_for('settings_page'))
        return _render_settings_form(cfg)

    @app.post('/delete')
    def delete_file():
        rel = request.form.get('p')
        if not rel:
            return 'missing p', 400
        try:
            path, canonical_rel = _resolve_trip_path(rel)
        except ValueError:
            return 'invalid path', 400
        if not path.exists() or not path.is_file():
            ref = request.headers.get('Referer')
            return redirect(ref or url_for('photos'))
        try:
            _move_file_to_trash(path, canonical_rel)
        except Exception as exc:
            return f'error: {exc}', 500
        # Redirect back to referrer or photos
        ref = request.headers.get('Referer')
        return redirect(ref or url_for('photos'))

    # Access Point API endpoints
    @app.get('/api/ap/status')
    def api_ap_status():
        """Get current AP status"""
        try:
            import subprocess
            # Check if hotspot is active
            result = subprocess.run(['nmcli', '-t', '-f', 'NAME', 'con', 'show', '--active'], 
                                  capture_output=True, text=True)
            is_active = 'Hotspot' in result.stdout
            
            # Get AP configuration
            cfg_local = load_config()
            ap_config = cfg_local.get('ap', {})
            
            ap_address = None
            if is_active:
                ap_address = get_ap_address()
            
            return jsonify({
                'active': is_active,
                'ssid': ap_config.get('ssid', 'Blackbox'),
                'address': ap_address,
                'generated_at': dt.datetime.now().isoformat()
            })
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    @app.post('/api/ap/start')
    def api_ap_start():
        """Start Access Point mode"""
        try:
            result_code = start_ap()
            if result_code == 0:
                return jsonify({
                    'success': True,
                    'address': get_ap_address(),
                    'message': 'Access Point started successfully'
                })
            else:
                error_msg = 'Failed to start Access Point'
                if result_code == 127:
                    error_msg = 'NetworkManager (nmcli) not available'
                elif result_code == 400:
                    error_msg = 'Invalid AP password configuration'
                elif result_code == 401:
                    error_msg = 'Not authorized to create hotspot'
                
                return jsonify({
                    'success': False,
                    'error': error_msg,
                    'code': result_code
                }), 400
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)}), 500

    @app.post('/api/ap/stop')
    def api_ap_stop():
        """Stop Access Point mode"""
        try:
            result_code = stop_ap()
            return jsonify({
                'success': True,
                'message': 'Access Point stopped successfully'
            })
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)}), 500

    # Bluetooth scanning endpoints
    @app.get('/api/bluetooth/scan')
    def api_bluetooth_scan():
        """Discover nearby Bluetooth devices using PyBluez"""
        try:
            import bluetooth
            print("Starting Bluetooth scan...")
            # Discover devices with 8 second duration
            nearby_devices = bluetooth.discover_devices(
                duration=8, 
                lookup_names=True, 
                flush_cache=True, 
                lookup_class=False
            )
            
            devices = []
            for addr, name in nearby_devices:
                devices.append({
                    'address': addr,
                    'name': name or 'Unknown Device',
                    'rssi': None  # PyBluez doesn't provide RSSI in basic mode
                })
            
            print(f"Found {len(devices)} devices")
            return jsonify({
                'success': True,
                'devices': devices
            })
        except ImportError:
            return jsonify({
                'success': False,
                'error': 'PyBluez not installed'
            }), 500
        except Exception as e:
            print(f"Bluetooth scan error: {e}")
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500

    @app.post('/api/bluetooth/pair')
    def api_bluetooth_pair():
        """Pair with a Bluetooth device"""
        try:
            data = request.json
            address = data.get('address')
            
            if not address:
                return jsonify({
                    'success': False,
                    'error': 'Device address required'
                }), 400
            
            import subprocess
            # Use bluetoothctl to pair
            result = subprocess.run(
                ['bluetoothctl', 'pair', address],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            success = result.returncode == 0
            return jsonify({
                'success': success,
                'message': 'Paired successfully' if success else 'Pairing failed',
                'output': result.stdout
            })
        except Exception as e:
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500

    @app.post('/api/bluetooth/connect')
    def api_bluetooth_connect():
        """Connect to a paired Bluetooth device"""
        try:
            data = request.json
            address = data.get('address')
            
            if not address:
                return jsonify({
                    'success': False,
                    'error': 'Device address required'
                }), 400
            
            import subprocess
            # Use bluetoothctl to connect
            result = subprocess.run(
                ['bluetoothctl', 'connect', address],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            success = result.returncode == 0
            return jsonify({
                'success': success,
                'message': 'Connected successfully' if success else 'Connection failed',
                'output': result.stdout
            })
        except Exception as e:
            return jsonify({
                'success': False,
                'error': str(e)
            }), 500

    return app


if __name__ == '__main__':
    cfg = load_config()
    app = create_app()
    app.run(host=cfg['web']['host'], port=int(cfg['web']['port']))
