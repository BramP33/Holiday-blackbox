from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
import hashlib
import shutil
import os
import time
from typing import Callable, Iterable, List, Optional, Tuple

from ..paths import Paths
from ..config import load_config
from ..media.metadata import MediaMetadataIndex
from ..transcription.queue import TranscriptionQueue
import shutil as _shutil
from .scanner import classify_device_code


PHOTO_EXTS = {'.jpg', '.jpeg', '.png', '.rw2', '.cr2', '.nef', '.raf', '.dng', '.arw'}
VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}


@dataclass
class CopyResult:
    copied_files: int
    skipped_files: int
    replaced_files: int
    bytes_copied: int
    device_name: str
    errors: List[str]


@dataclass
class CopyProgress:
    index: int
    total: int
    copied_files: int
    skipped_files: int
    replaced_files: int
    bytes_copied: int
    current_path: Path | None = None


def sha256sum(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _iterate_media_files(
    root: Path,
    allowed_exts: Optional[Iterable[str]] = None,
    min_timestamp: Optional[float] = None,
) -> Iterable[Path]:
    if allowed_exts is None:
        allowed: set[str] = PHOTO_EXTS | VIDEO_EXTS
    else:
        allowed = {ext.lower() for ext in allowed_exts}
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if fn.startswith('._'):
                continue  # Skip macOS resource fork sidecars
            p = Path(dirpath) / fn
            suffix = p.suffix.lower()
            if suffix not in allowed:
                continue
            if min_timestamp is not None:
                try:
                    if p.stat().st_mtime < min_timestamp:
                        continue
                except FileNotFoundError:
                    continue
            yield p


def copy_from_source(
    source_root: Path,
    paths: Paths,
    verify_mode: str = 'fast',
    progress_cb: Optional[Callable[[CopyProgress], None]] = None,
    *,
    allowed_exts: Optional[Iterable[str]] = None,
    min_timestamp: Optional[float] = None,
    device_label_override: Optional[str] = None,
) -> CopyResult:
    device_code = classify_device_code(source_root, device_label_override)
    # Prefer DCIM folder if present (case-insensitive)
    dcim_dir = None
    for dn in ('DCIM', 'dcim'):
        cand = source_root / dn
        if cand.exists() and cand.is_dir():
            dcim_dir = cand
            break
    iterator_root = dcim_dir if dcim_dir is not None else source_root
    files = list(
        _iterate_media_files(
            iterator_root,
            allowed_exts=allowed_exts,
            min_timestamp=min_timestamp,
        )
    )
    total = len(files)
    copied = skipped = replaced = 0
    bytes_copied = 0
    errors: List[str] = []

    cfg = load_config()
    metadata_index = MediaMetadataIndex(paths)
    transcription_cfg = cfg.get('transcription') or {}
    transcription_enabled = bool(transcription_cfg.get('enabled', True))
    transcription_queue = TranscriptionQueue(paths) if transcription_enabled else None
    min_free = int(cfg.get('limits', {}).get('min_free_gb', 10)) * 1_000_000_000

    labels = cfg.get('device_labels', {})
    device_label = device_label_override or labels.get(device_code, device_code)

    for i, src in enumerate(files, 1):
        try:
            # Date folder from modification time
            date_str = time.strftime('%Y-%m-%d', time.localtime(src.stat().st_mtime))
            if src.suffix.lower() in PHOTO_EXTS:
                dst_dir = paths.photos_dir()
            else:
                dst_dir = paths.videos_dir(date_str, device_label)
            dst = dst_dir / src.name

            # free space check: keep min_free_gb
            usage = _shutil.disk_usage(str(paths.nvme_mount))
            if usage.free - src.stat().st_size < min_free:
                errors.append('Low space: stopping backup')
                break

            if dst.exists():
                # Dedup: compute SHA256 both sides
                if sha256sum(src) == sha256sum(dst):
                    skipped += 1
                    if metadata_index and src.suffix.lower() in VIDEO_EXTS:
                        try:
                            metadata_index.ensure_for_path(dst)
                        except Exception:
                            pass
                    continue
                # replace
                shutil.copy2(src, dst)
                replaced += 1
            else:
                # copy new
                shutil.copy2(src, dst)
                copied += 1

            bytes_copied += dst.stat().st_size

            # Post copy verify with one retry if mismatch
            def _verify() -> bool:
                if verify_mode == 'sha256':
                    return sha256sum(src) == sha256sum(dst)
                return src.stat().st_size == dst.stat().st_size

            if not _verify():
                try:
                    dst.unlink(missing_ok=True)
                except Exception:
                    pass
                shutil.copy2(src, dst)
                if not _verify():
                    errors.append(f'Verify failed: {src}')
                    break

            if metadata_index and src.suffix.lower() in VIDEO_EXTS:
                try:
                    metadata_index.ensure_for_path(dst)
                except Exception:
                    pass
                if transcription_queue:
                    try:
                        transcription_queue.enqueue(dst)
                    except Exception:
                        pass

        except Exception as e:  # pragma: no cover
            errors.append(f'Error copying {src}: {e}')
        finally:
            if progress_cb:
                progress_cb(
                    CopyProgress(
                        index=i,
                        total=total,
                        copied_files=copied,
                        skipped_files=skipped,
                        replaced_files=replaced,
                        bytes_copied=bytes_copied,
                        current_path=src,
                    )
                )

    return CopyResult(copied, skipped, replaced, bytes_copied, device_label, errors)
