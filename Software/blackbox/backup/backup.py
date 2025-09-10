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


def sha256sum(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _iterate_media_files(root: Path) -> Iterable[Path]:
    for dirpath, _, files in os.walk(root):
        for fn in files:
            p = Path(dirpath) / fn
            if p.suffix.lower() in PHOTO_EXTS | VIDEO_EXTS:
                yield p


def copy_from_source(source_root: Path, paths: Paths, verify_mode: str = 'fast', progress_cb: Optional[Callable[[int, int], None]] = None) -> CopyResult:
    device_code = classify_device_code(source_root)
    files = list(_iterate_media_files(source_root / 'DCIM')) if (source_root / 'DCIM').exists() else list(_iterate_media_files(source_root))
    total = len(files)
    copied = skipped = replaced = 0
    bytes_copied = 0
    errors: List[str] = []

    cfg = load_config()
    min_free = int(cfg.get('limits', {}).get('min_free_gb', 10)) * 1_000_000_000

    labels = cfg.get('device_labels', {})
    device_label = labels.get(device_code, device_code)

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
                    if progress_cb:
                        progress_cb(i, total)
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

        except Exception as e:  # pragma: no cover
            errors.append(f'Error copying {src}: {e}')
        finally:
            if progress_cb:
                progress_cb(i, total)

    return CopyResult(copied, skipped, replaced, bytes_copied, device_label, errors)
