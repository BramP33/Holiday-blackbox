from __future__ import annotations

import logging
import os
import shutil
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

from ..paths import Paths
from ..media.metadata import MediaMetadataIndex
from ..backup.backup import PHOTO_EXTS, VIDEO_EXTS
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
    downloaded = skipped = 0
    client = GoProHttp(host or DEFAULT_HOST)
    try:
        media = client.media_list()
    except Exception as exc:
        logger.error("GoPro media list failed: %s", exc)
        return HttpImportResult(0, 0, [f'media list failed: {exc}'], 0)

    items: List[Dict] = []
    for entry in media:
        name = entry.get('filename')
        directory = entry.get('directory') or ''
        if not name:
            continue
        ext = Path(name).suffix.lower()
        if ext not in PHOTO_EXTS | VIDEO_EXTS:
            continue
        # HTTP endpoint expects /videos/DCIM/<dir>/<file>
        remote_rel = f"DCIM/{directory}/{name}"
        size = int(entry.get('size') or 0)
        try:
            ts = float(entry.get('created') or entry.get('mod') or time.time())
        except Exception:
            ts = time.time()
        items.append({'remote': remote_rel, 'name': name, 'ext': ext, 'size': size, 'ts': ts})

    total = len(items)
    logger.info("GoPro media items available: %d", total)

    keep_alive = _KeepAlive(client)
    if total:
        try:
            client.claim_control()
        except Exception as exc:
            logger.debug("claim_control threw: %s", exc)
        keep_alive.start()
    for idx, it in enumerate(items, start=1):
        remote_rel = it['remote']
        name = it['name']
        ext = it['ext']
        size = it['size']
        ts = it['ts']

        logger.info("[%d/%d] downloading %s (%s)", idx, total, name, remote_rel)

        date_str = time.strftime('%Y-%m-%d', time.localtime(ts))
        dest_dir = paths.videos_dir(date_str, 'gopro') if ext in VIDEO_EXTS else paths.photos_dir()
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / name
        if ext in PHOTO_EXTS:
            dest = _unique_destination(dest_dir, name)
        if dest.exists() and size and dest.stat().st_size == size:
            skipped += 1
            if progress_cb:
                progress_cb(idx, total, idx/total if total else 1.0, name)
            continue

        usage = shutil.disk_usage(str(paths.nvme_mount))
        if size and (usage.free - size) < min_free_bytes:
            errors.append('Low space: stopping import')
            break

        temp = dest.with_suffix(dest.suffix + '.part')
        try:
            if temp.exists():
                temp.unlink()
        except Exception:
            pass

        def _chunk(done: int, totalb: int):
            if progress_cb:
                progress_cb(idx, total, idx/total if total else 1.0, name)

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
        try:
            metadata_index.ensure_for_path(dest)
        except Exception as exc:
            logger.debug("metadata index refresh failed for %s: %s", dest, exc)
        if progress_cb:
            progress_cb(idx, total, idx/total if total else 1.0, name)

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
