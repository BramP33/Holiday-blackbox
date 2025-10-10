from __future__ import annotations
from pathlib import Path
import subprocess
import os
from typing import Callable, Optional

VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}
PHOTO_EXTS = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.rw2', '.cr2', '.nef', '.raf', '.dng', '.arw'}

_FAILED_ENCODERS: set[str] = set()


def _run(cmd: list[str], background_priority: bool = False) -> int:
    """Run command with configurable priority to avoid overwhelming the system."""
    import subprocess
    
    # Use nice to lower the process priority (higher nice value = lower priority)
    # Normal: nice 10, Background: nice 19 (lowest priority)
    nice_value = '19' if background_priority else '10'
    nice_cmd = ['nice', '-n', nice_value] + cmd
    
    try:
        # Also set additional process limits
        return subprocess.call(
            nice_cmd, 
            # Redirect stderr to avoid cluttering logs during normal operation
            stderr=subprocess.DEVNULL if not os.environ.get('DEBUG_FFMPEG') else None
        )
    except FileNotFoundError:
        # Fallback if 'nice' command is not available
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


def _video_proxy_cmd(src: Path, dst: Path, height: int, bitrate: str, encoder: str, background_priority: bool = False) -> list[str]:
    cmd = ['ffmpeg', '-y', '-i', str(src), '-vf', f"scale=-2:{height}"]
    
    # Adjust thread limits based on priority mode
    if background_priority:
        # Background: use only 1 thread to minimize CPU impact
        max_threads = 1
    else:
        # Normal: use up to half the available cores
        max_threads = min(3, max(1, os.cpu_count() // 2)) if os.cpu_count() else 2
    
    if encoder == 'libx264':
        preset = 'ultrafast' if not background_priority else 'veryfast'
        cmd.extend([
            '-c:v', 'libx264', 
            '-b:v', bitrate, 
            '-preset', preset,
            '-threads', str(max_threads)
        ])
    elif encoder == 'libx265':
        preset = 'ultrafast' if not background_priority else 'fast'
        cmd.extend([
            '-c:v', 'libx265', 
            '-b:v', bitrate, 
            '-preset', preset,
            '-x265-params', f'pools={max_threads}:threads={max_threads}'
        ])
    else:
        cmd.extend(['-c:v', encoder, '-b:v', bitrate, '-pix_fmt', 'yuv420p'])
    
    cmd.extend(['-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-movflags', '+faststart', str(dst)])
    return cmd


def build_video_proxy(
    src: Path,
    dst: Path,
    height: int = 480,
    bitrate: str = '1200k',
    encoder: Optional[str] = None,
    background_priority: bool = False,
) -> int:
    """
    Build a video proxy with configurable CPU usage.
    
    Args:
        src: Source video file
        dst: Destination proxy file
        height: Target height in pixels
        bitrate: Target bitrate (e.g. '1200k')
        encoder: Specific encoder to use, or None for auto-selection
        background_priority: If True, use minimal CPU to avoid interfering with UI
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    preferred: list[str] = []

    if encoder is not None:
        raw = encoder.strip()
        normalized = raw.lower()
        if not raw or normalized == 'auto':
            # Try H.264 hardware first, then H.265 hardware, then CPU
            preferred.extend(['h264_v4l2m2m', 'hevc_v4l2m2m', 'libx264'])
        elif normalized in {'cpu', 'software', 'none', 'disabled', 'off'}:
            preferred.append('libx264')
        elif normalized in {'h265', 'hevc'}:
            # H.265 specific request
            preferred.extend(['hevc_v4l2m2m', 'libx265'])
        else:
            preferred.append(raw)
    else:
        # Default: try H.264 hardware, then H.265 hardware, then CPU fallback
        preferred.extend(['h264_v4l2m2m', 'hevc_v4l2m2m', 'libx264'])

    # Always ensure we have a CPU fallback
    if 'libx264' not in preferred and 'libx265' not in preferred:
        preferred.append('libx264')

    exit_code = 1
    seen: set[str] = set()
    for current in preferred:
        if current in seen:
            continue
        seen.add(current)
        if current not in {'libx264', 'libx265'} and current in _FAILED_ENCODERS:
            continue
        cmd = _video_proxy_cmd(src, dst, height, bitrate, current, background_priority)
        exit_code = _run(cmd, background_priority)
        if exit_code == 0:
            return 0
        if current not in {'libx264', 'libx265'}:
            _FAILED_ENCODERS.add(current)
            try:
                dst.unlink()
            except OSError:
                pass

    return exit_code


def build_video_thumb(src: Path, dst: Path, size: int = 720, background_priority: bool = False) -> int:
    dst.parent.mkdir(parents=True, exist_ok=True)
    # Use ffmpeg to extract a representative frame and scale to the requested size.
    cmd = [
        'ffmpeg', '-y', '-i', str(src), '-vf', f"thumbnail,scale={size}:-2",
        '-frames:v', '1', '-qscale:v', '4', str(dst)
    ]
    return _run(cmd, background_priority)


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
    encoder: Optional[str] = None,
    background_priority: bool = False,
    progress_cb: Optional[Callable[[int, int, Path, str], None]] = None,
) -> None:
    """Generate proxies/thumbs for media under folder.

    Args:
        folder: Source folder to scan for media
        cache_dir: Directory to store generated proxies/thumbs
        max_cache_bytes: Maximum cache size in bytes
        prefer_gopro_thm: Whether to prefer GoPro THM files for thumbnails
        height: Target height for video proxies
        bitrate: Target bitrate for video proxies
        encoder: Specific encoder to use for video proxies
        background_priority: If True, use minimal CPU to avoid interfering with UI
        progress_cb: Callback function called after each item

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
            build_video_proxy(src, dst, height=height, bitrate=bitrate, encoder=encoder, background_priority=background_priority)
        elif kind == 'photo':
            build_photo_thumb(src, dst)
        else:
            build_video_thumb(src, dst, background_priority=background_priority)
        done += 1
        if progress_cb:
            try:
                progress_cb(done, total, src, kind)
            except Exception:
                pass

    ensure_cache_limit(cache_dir, max_cache_bytes)
