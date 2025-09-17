from __future__ import annotations
from pathlib import Path
import subprocess
import shutil
import os
from typing import Iterable, Callable, Optional

VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}
PHOTO_EXTS = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.rw2', '.cr2', '.nef', '.raf', '.dng', '.arw'}


def _run(cmd: list[str]) -> int:
    return subprocess.call(cmd)


def ensure_cache_limit(cache_dir: Path, max_bytes: int) -> None:
    """Delete oldest files until total size <= max_bytes."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    items = [(p, p.stat().st_mtime, p.stat().st_size) for p in cache_dir.glob('**/*') if p.is_file()]
    total = sum(sz for _, _, sz in items)
    if total <= max_bytes:
        return
    items.sort(key=lambda t: t[1])  # oldest first
    for p, _, sz in items:
        try:
            p.unlink()
            total -= sz
            if total <= max_bytes:
                break
        except Exception:
            pass


def proxy_name_for(src: Path, cache_dir: Path) -> Path:
    safe = src.relative_to(src.anchor).as_posix().replace('/', '_')
    return cache_dir / f"{safe}.mp4"


def thumb_name_for(src: Path, cache_dir: Path) -> Path:
    safe = src.relative_to(src.anchor).as_posix().replace('/', '_')
    return cache_dir / f"{safe}.jpg"


def build_video_proxy(src: Path, dst: Path, height: int = 480, bitrate: str = '1200k') -> int:
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        'ffmpeg', '-y', '-i', str(src), '-vf', f"scale=-2:{height}",
        '-c:v', 'libx264', '-b:v', bitrate, '-preset', 'veryfast', '-movflags', '+faststart',
        '-an', str(dst)
    ]
    return _run(cmd)


def build_video_thumb(src: Path, dst: Path, size: int = 720) -> int:
    dst.parent.mkdir(parents=True, exist_ok=True)
    # Use ffmpeg to extract a representative frame and scale to the requested size.
    cmd = [
        'ffmpeg', '-y', '-i', str(src), '-vf', f"thumbnail,scale={size}:-2",
        '-frames:v', '1', '-qscale:v', '4', str(dst)
    ]
    return _run(cmd)


def build_photo_thumb(src: Path, dst: Path, size: int = 720) -> int:
    try:
        from PIL import Image
        img = Image.open(src)
        img.thumbnail((size, size))
        dst.parent.mkdir(parents=True, exist_ok=True)
        img.save(dst, quality=85)
        return 0
    except Exception:
        return 1


def generate_for_folder(
    folder: Path,
    cache_dir: Path,
    max_cache_bytes: int,
    prefer_gopro_thm: bool = True,
    height: int = 480,
    bitrate: str = '1200k',
    progress_cb: Optional[Callable[[int, int, Path, str], None]] = None,
) -> None:
    """Generate proxies/thumbs for media under folder.

    Calls progress_cb(done, total, path, kind) after each item, where kind is
    'video'|'photo'|'video_thumb'.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)

    # Build task list first to know total
    tasks: list[tuple[str, Path, Path]] = []  # (kind, src, dst)
    for dirpath, _, files in os.walk(folder):
        for fn in files:
            p = Path(dirpath) / fn
            ext = p.suffix.lower()
            if ext in VIDEO_EXTS:
                proxy = proxy_name_for(p, cache_dir)
                if not proxy.exists():
                    tasks.append(('video', p, proxy))
                thumb = thumb_name_for(p, cache_dir)
                if not thumb.exists():
                    tasks.append(('video_thumb', p, thumb))
            elif ext in PHOTO_EXTS:
                thumb = thumb_name_for(p, cache_dir)
                if not thumb.exists():
                    tasks.append(('photo', p, thumb))

    total = len(tasks)
    done = 0
    if progress_cb:
        try:
            progress_cb(done, total, Path(''), '')
        except Exception:
            pass

    # Execute tasks
    for kind, src, dst in tasks:
        if kind == 'video':
            build_video_proxy(src, dst, height=height, bitrate=bitrate)
        elif kind == 'photo':
            build_photo_thumb(src, dst)
        else:
            build_video_thumb(src, dst)
        done += 1
        if progress_cb:
            try:
                progress_cb(done, total, src, kind)
            except Exception:
                pass

    ensure_cache_limit(cache_dir, max_cache_bytes)
