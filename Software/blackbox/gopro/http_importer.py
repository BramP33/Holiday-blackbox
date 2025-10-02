from __future__ import annotations

import logging
import os
import shutil
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

from ..config import load_config
from ..paths import Paths
from ..media.metadata import MediaMetadataIndex
from ..backup.backup import PHOTO_EXTS, VIDEO_EXTS
from ..transcription.queue import TranscriptionQueue
from .http_client import DEFAULT_HOST, GoProHttp

logger = logging.getLogger(__name__)
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter('[GoProImport] %(message)s'))
    logger.addHandler(_handler)
logger.setLevel(logging.INFO)
logger.propagate = False

ProgressCallback = Callable[[int, int, float, str], None]


@dataclass
class HttpImportResult:
    downloaded: int
    skipped: int
    errors: List[str]
    total: int


def import_media_http(
    paths: Paths,
    metadata_index: MediaMetadataIndex,
    min_free_bytes: int,
    progress_cb: Optional[ProgressCallback] = None,
    host: Optional[str] = None,
) -> HttpImportResult:
    errors: List[str] = []
    cfg = load_config()
    transcription_cfg = cfg.get('transcription') or {}
    transcription_queue = TranscriptionQueue(paths) if transcription_cfg.get('enabled', True) else None
    downloaded = skipped = 0
    client = GoProHttp(host or DEFAULT_HOST)
    try:
        media = client.media_list()
    except Exception as exc:
        logger.error("GoPro media list failed: %s", exc)
        return HttpImportResult(0, 0, [f'media list failed: {exc}'], 0)

    plan: List[Dict] = []
    needed_bytes = 0
    for entry in media:
        name = entry.get('filename')
        directory = entry.get('directory') or ''
        if not name:
            continue
        ext = Path(name).suffix.lower()
        if ext not in PHOTO_EXTS | VIDEO_EXTS:
            continue
        remote_rel = f"DCIM/{directory}/{name}"
        size = int(entry.get('size') or 0)
        try:
            ts = float(entry.get('created') or entry.get('mod') or time.time())
        except Exception:
            ts = time.time()

        date_str = time.strftime('%Y-%m-%d', time.localtime(ts))
        if ext in VIDEO_EXTS:
            dest_dir = paths.videos_dir(date_str, 'gopro')
            dest = dest_dir / name
        else:
            dest_dir = paths.photos_dir()
            dest = _unique_destination(dest_dir, name)

        skip = False
        if ext in VIDEO_EXTS and size:
            try:
                if dest.exists() and dest.stat().st_size == size:
                    skip = True
            except (FileNotFoundError, OSError):
                skip = False

        if not skip and size:
            needed_bytes += size

        plan.append({
            'remote': remote_rel,
            'name': name,
            'ext': ext,
            'size': size,
            'ts': ts,
            'dest': dest,
            'skip': skip,
        })

    total = len(plan)
    logger.info("GoPro media items available: %d", total)

    if plan and needed_bytes:
        usage = shutil.disk_usage(str(paths.nvme_mount))
        usable_free = max(usage.free - min_free_bytes, 0)
        if needed_bytes > usable_free:
            errors.append(f'low_space:{needed_bytes}:{usable_free}:{min_free_bytes}')
            logger.warning(
                "Insufficient space for GoPro import: need %d bytes, usable %d bytes (reserve %d)",
                needed_bytes,
                usable_free,
                min_free_bytes,
            )
            return HttpImportResult(0, 0, errors, total)

    total_bytes = sum(it['size'] for it in plan if not it['skip'] and it['size'] > 0)
    total_items_for_fraction = total if total else 1
    processed_bytes = 0
    processed_items = 0

    def _emit_progress(idx: int, name: str, *, done_bytes: int = 0, partial: float = 0.0) -> None:
        if not progress_cb:
            return
        clamped_partial = min(max(partial, 0.0), 1.0)
        if total_bytes > 0:
            numerator = processed_bytes + max(done_bytes, 0)
            fraction = min(max(numerator / total_bytes, 0.0), 1.0)
        else:
            fraction = min(max((processed_items + clamped_partial) / total_items_for_fraction, 0.0), 1.0)
        progress_cb(idx, total, fraction, name)

    keep_alive = _KeepAlive(client)
    if total:
        try:
            client.claim_control()
        except Exception as exc:
            logger.debug("claim_control threw: %s", exc)
        keep_alive.start()
    for idx, it in enumerate(plan, start=1):
        remote_rel = it['remote']
        name = it['name']
        ext = it['ext']
        size = it['size']
        ts = it['ts']
        dest = Path(it['dest'])
        skip = it['skip']

        logger.info("[%d/%d] downloading %s (%s)", idx, total, name, remote_rel)

        if skip:
            skipped += 1
            if size > 0:
                processed_bytes += size
            processed_items += 1
            if metadata_index and ext in VIDEO_EXTS:
                try:
                    metadata_index.ensure_for_path(dest)
                except Exception as exc:
                    logger.debug("metadata index refresh failed for %s: %s", dest, exc)
            _emit_progress(idx, name)
            continue

        usage = shutil.disk_usage(str(paths.nvme_mount))
        if size and (usage.free - size) < min_free_bytes:
            errors.append('Low space: stopping import')
            logger.warning("Aborting GoPro import due to low space before %s", name)
            break

        temp = dest.with_suffix(dest.suffix + '.part')
        try:
            if temp.exists():
                temp.unlink()
        except Exception:
            pass

        base_bytes = processed_bytes

        def _chunk(done: int, totalb: int):
            done_bytes = 0
            partial = 0.0
            if size > 0:
                done_bytes = min(max(done, 0), size)
                if size:
                    partial = done_bytes / size
            elif totalb > 0:
                done_bytes = 0
                partial = min(max(done / totalb, 0.0), 1.0)
            _emit_progress(idx, name, done_bytes=done_bytes, partial=partial)

        try:
            client.download(remote_rel, temp, progress=_chunk)
        except Exception as exc:
            logger.error("download failed for %s: %s", remote_rel, exc)
            errors.append(f'download failed for {remote_rel}: {exc}')
            try:
                temp.unlink(missing_ok=True)  # type: ignore
            except Exception:
                pass
            continue

        try:
            os.utime(temp, (ts, ts))
        except Exception:
            pass
        try:
            temp.rename(dest)
        except Exception as exc:
            errors.append(f'move failed for {dest}: {exc}')
            continue
        downloaded += 1
        if size > 0:
            processed_bytes += size
        processed_items += 1
        try:
            metadata_index.ensure_for_path(dest)
        except Exception as exc:
            logger.debug("metadata index refresh failed for %s: %s", dest, exc)
        if transcription_queue and ext in VIDEO_EXTS:
            try:
                transcription_queue.enqueue(dest)
            except Exception as exc:
                logger.debug("transcription enqueue failed for %s: %s", dest, exc)
        _emit_progress(idx, name)

    keep_alive.stop()

    if errors:
        logger.warning("GoPro import completed with %d errors", len(errors))
    else:
        logger.info("GoPro import completed: %d downloaded, %d skipped", downloaded, skipped)

    return HttpImportResult(downloaded, skipped, errors, total)


def _unique_destination(base: Path, filename: str) -> Path:
    target = base / filename
    if not target.exists():
        return target
    stem = Path(filename).stem
    suffix = Path(filename).suffix
    counter = 1
    while True:
        candidate = base / f"{stem}-{counter}{suffix}"
        if not candidate.exists():
            return candidate
        counter += 1


class _KeepAlive:
    def __init__(self, client: GoProHttp, interval: float = 1.0):
        self._client = client
        self._interval = interval
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        if self._thread is not None:
            return
        logger.debug("Starting GoPro keep-alive thread (interval %.2fs)", self._interval)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread and thread.is_alive():
            thread.join(timeout=self._interval + 1.0)
        logger.debug("Stopped GoPro keep-alive thread")

    def _run(self) -> None:
        while not self._stop.wait(self._interval):
            try:
                self._client.keep_alive()
            except Exception:
                # Swallow network errors; importer will surface failures separately
                pass
