from __future__ import annotations
from flask import Flask, jsonify, send_file, render_template_string, request, render_template, url_for, redirect
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
from ..backup.backup import copy_from_source
from ..backup.backup import VIDEO_EXTS as BACKUP_VIDEO_EXTS
from ..proxies.generate import generate_for_folder
from ..transcription import TranscriptionQueue


def create_app() -> Flask:
    cfg = load_config()
    paths = Paths(cfg).ensure()
    app = Flask(__name__)
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

    @app.post('/trash/purge')
    def trash_purge():
        trash_id = request.form.get('id')
        if not trash_id:
            return 'missing id', 400
        ok = _delete_trash_entry(trash_id)
        if ok:
            return redirect(url_for('trash_page', deleted=trash_id))
        return redirect(url_for('trash_page', error='delete_failed', target=trash_id))

    @app.context_processor
    def inject_i18n():
        cur_cfg = load_config()
        cur_lang = (cur_cfg.get('language') or 'en').lower()
        return {
            'lang': cur_lang,
            't': lambda key, **kwargs: tr(cur_lang, key, **kwargs),
        }

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
        }

    def _serialize_suggestion(suggestion: LocationSuggestion) -> dict:
        return {
            'label': suggestion.label,
            'query': suggestion.query,
        }

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
        transcript = (record.get('transcript') or '').strip()
        if not transcript:
            return 'not found', 404
        filename = Path(canonical).with_suffix('.txt').name
        stream = io.BytesIO(transcript.encode('utf-8'))
        stream.seek(0)
        return send_file(stream, mimetype='text/plain', as_attachment=True, download_name=filename)

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

    return app


if __name__ == '__main__':
    cfg = load_config()
    app = create_app()
    app.run(host=cfg['web']['host'], port=int(cfg['web']['port']))
