from __future__ import annotations
from pathlib import Path
from typing import Iterable, Optional
import os
import subprocess
import json
import logging


logger = logging.getLogger(__name__)


DCIM_NAMES = {"DCIM", "dcim"}
MEDIA_EXTS = {'.jpg', '.jpeg', '.png', '.rw2', '.cr2', '.nef', '.raf', '.dng', '.arw', '.mp4', '.mov', '.m4v'}
VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}


def iter_mounts(source_roots: Iterable[str]) -> Iterable[Path]:
    """Iterate likely mount points under common roots.

    - /Volumes/* (macOS): one level deep
    - /mnt/*: one level deep
    - /media/<user>/* and /run/media/<user>/* (Linux desktops): two levels
    """
    for root in source_roots:
        p = Path(root)
        if not p.exists():
            continue
        try:
            for child in p.iterdir():
                if not child.is_dir():
                    continue
                # Typical Linux automount path: /media/<user>/<LABEL> or /run/media/<user>/<LABEL>
                # If the root folder itself ends with 'media', handle both patterns:
                #   - /media/<user>/<LABEL>
                #   - /media/<LABEL>
                if p.name == 'media':
                    yielded = False
                    # First yield grandchildren like /media/<user>/<LABEL>
                    try:
                        for grand in child.iterdir():
                            if grand.is_dir():
                                yield grand
                                yielded = True
                    except Exception:
                        pass
                    # If child itself is a mountpoint or we didn't yield any grandchildren,
                    # also consider child as a candidate (covers /media/<LABEL>).
                    try:
                        if os.path.ismount(child) or not yielded:
                            yield child
                    except Exception:
                        pass
                else:
                    # Straight one-level mounts (e.g., /Volumes/*, /mnt/*)
                    yield child
        except Exception:
            continue


def find_dcim_mounts(source_roots: Iterable[str]) -> list[Path]:
    matches: list[Path] = []
    for m in iter_mounts(source_roots):
        for dn in DCIM_NAMES:
            dcim = m / dn
            if dcim.exists() and dcim.is_dir():
                matches.append(m)
                break
    return matches

def find_first_dcim(source_roots: Iterable[str]) -> Optional[Path]:
    matches = find_dcim_mounts(source_roots)
    return matches[0] if matches else None


def _has_media_quick(root: Path, max_files: int = 20000) -> bool:
    """Return True if any file under root looks like a photo/video.

    Limits work by stopping after max_files entries.
    """
    seen = 0
    for dirpath, _, files in os.walk(root):
        for fn in files:
            seen += 1
            if seen > max_files:
                return False
            if Path(fn).suffix.lower() in MEDIA_EXTS:
                return True
    return False


def find_source_mounts(source_roots: Iterable[str]) -> list[Path]:
    """Find candidate source mounts.

    Priority:
    1) Mounts with a DCIM folder
    2) If none, and exactly one mount exists, use it
    3) Else, mounts that contain media files (quick heuristic)
    """
    mounts = list(iter_mounts(source_roots))
    def _has_dcim(path: Path) -> bool:
        for dn in DCIM_NAMES:
            try:
                if (path / dn).is_dir():
                    return True
            except PermissionError:
                continue
            except OSError:
                continue
        return False

    dcims = [m for m in mounts if _has_dcim(m)]
    if dcims:
        return dcims
    if len(mounts) == 1:
        return mounts
    matches: list[Path] = []
    for m in mounts:
        try:
            if _has_media_quick(m):
                matches.append(m)
        except Exception:
            continue
    if matches:
        return matches

    # Fallback: query lsblk for mounted partitions belonging to USB disks.
    # This helps when automounts live outside of the typical roots we scan.
    try:
        out = subprocess.check_output(['lsblk', '-J', '-o', 'NAME,TYPE,TRAN,MOUNTPOINT'], text=True)
        data = json.loads(out)
    except Exception:
        data = {}

    usb_mounts: list[Path] = []

    def _collect_mounts(dev: dict, is_usb: bool = False):
        cur_is_usb = is_usb or (dev.get('tran') or '').lower() == 'usb'
        mp = dev.get('mountpoint')
        if mp and cur_is_usb:
            try:
                usb_mounts.append(Path(mp))
            except Exception:
                pass
        for ch in (dev.get('children') or []):
            _collect_mounts(ch, cur_is_usb)

    for d in (data.get('blockdevices') or []):
        _collect_mounts(d, False)

    # De-duplicate while preserving order
    seen = set()
    usb_mounts = [m for m in usb_mounts if not (str(m) in seen or seen.add(str(m)))]

    # Apply the same DCIM/media priority on these mountpoints
    dcims = [m for m in usb_mounts if any((m / dn).is_dir() for dn in DCIM_NAMES)]
    if dcims:
        return dcims
    medias = [m for m in usb_mounts if _has_media_quick(m)]
    return medias


def _get_video_metadata(video_path: Path) -> tuple[Optional[str], Optional[str]]:
    """Extract camera make and model from video metadata using ffprobe.
    
    Returns:
        tuple: (camera_make, camera_model) or (None, None) if unavailable
    """
    try:
        import subprocess
        
        cmd = [
            'ffprobe',
            '-v', 'quiet',
            '-print_format', 'json',
            '-show_entries', 'format_tags:stream_tags',
            str(video_path),
        ]
        
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=5)
        if proc.returncode != 0:
            return None, None
            
        data = json.loads(proc.stdout or '{}')
        
        # Collect all tags from format and streams
        tags = {}
        fmt = data.get('format') or {}
        for key, value in (fmt.get('tags') or {}).items():
            tags[key.lower()] = str(value)
        
        for stream in data.get('streams') or []:
            for key, value in (stream.get('tags') or {}).items():
                key_lower = key.lower()
                if key_lower not in tags:
                    tags[key_lower] = str(value)
        
        # Extract make
        camera_make = None
        for key in ['com.apple.quicktime.make', 'make', 'camera_make', 
                    'com.apple.quicktime.camera.make', 'com.apple.quicktime.manufacturer',
                    'com.android.manufacturer', 'manufacturer']:
            if key in tags and tags[key]:
                camera_make = tags[key].strip().strip('\0')
                if camera_make:
                    break
        
        # Extract model
        camera_model = None
        for key in ['com.apple.quicktime.model', 'model', 'camera_model',
                    'com.apple.quicktime.camera.model', 'com.apple.quicktime.device.model',
                    'device_model', 'com.android.model', 'android_model']:
            if key in tags and tags[key]:
                camera_model = tags[key].strip().strip('\0')
                if camera_model:
                    break
        
        return camera_make, camera_model
        
    except Exception as e:
        logger.debug(f"Failed to extract metadata from {video_path}: {e}")
        return None, None


def classify_device_code(root: Path, device_label: str | None = None) -> str:
    """Return a device code: gopro|drone|360|lumix_g7|iphone|sony|insta360|mobile|camera
    
    Classification is based on (in priority order):
    1. Device label (for uploads via web)
    2. Video metadata (camera make/model from ffprobe) - MOST RELIABLE
    3. File naming patterns (GOPRxxxx, DJI_xxxx, IMG_xxxx, etc.)
    4. File extensions (.360, .insv, .insp)
    5. Mount point name patterns
    """
    # Check if uploaded via web (mobile)
    if device_label and device_label.lower() in ('uploads', 'upload'):
        logger.info("Detected 'mobile' via device label")
        return 'mobile'
    
    # Check file patterns in the source
    # Prefer DCIM folder if it exists for faster scanning
    scan_root = root
    for dn in DCIM_NAMES:
        dcim = root / dn
        if dcim.exists() and dcim.is_dir():
            scan_root = dcim
            break
    
    # Step 1: Try metadata-first approach (sample a few video files)
    try:
        video_samples = []
        for dirpath, _, files in os.walk(scan_root):
            for filename in files:
                if Path(filename).suffix.lower() in VIDEO_EXTS:
                    video_samples.append(Path(dirpath) / filename)
                    if len(video_samples) >= 3:  # Sample 3 videos for metadata
                        break
            if len(video_samples) >= 3:
                break
        
        # Check metadata from sampled videos
        for video_file in video_samples:
            camera_make, camera_model = _get_video_metadata(video_file)
            
            if camera_make:
                make_lower = camera_make.lower()
                model_lower = (camera_model or '').lower()
                
                # GoPro detection
                if 'gopro' in make_lower or 'hero' in model_lower or 'max' in model_lower:
                    logger.info(f"Detected 'gopro' via metadata: {camera_make} {camera_model}")
                    return 'gopro'
                
                # DJI Drone detection
                if 'dji' in make_lower or any(x in model_lower for x in ['mavic', 'phantom', 'mini', 'air']):
                    logger.info(f"Detected 'drone' via metadata: {camera_make} {camera_model}")
                    return 'drone'
                
                # Apple/iPhone detection
                if 'apple' in make_lower or 'iphone' in model_lower:
                    logger.info(f"Detected 'iphone' via metadata: {camera_make} {camera_model}")
                    return 'iphone'
                
                # Sony detection
                if 'sony' in make_lower:
                    logger.info(f"Detected 'sony' via metadata: {camera_make} {camera_model}")
                    return 'sony'
                
                # Insta360 detection
                if 'insta360' in make_lower or 'insta360' in model_lower:
                    logger.info(f"Detected 'insta360' via metadata: {camera_make} {camera_model}")
                    return 'insta360'
                
                # Panasonic Lumix detection
                if 'panasonic' in make_lower and 'lumix' in model_lower:
                    logger.info(f"Detected 'lumix_g7' via metadata: {camera_make} {camera_model}")
                    return 'lumix_g7'
                
    except Exception as e:
        logger.debug(f"Metadata detection failed: {e}")
    
    # Step 2: Filename pattern detection
    try:
        checked = 0
        max_check = 100
        pattern_scores = {}  # Track pattern matches for confidence
        
        for dirpath, _, files in os.walk(scan_root):
            for filename in files:
                if checked >= max_check:
                    break
                checked += 1
                
                filename_upper = filename.upper()
                filename_lower = filename.lower()
                
                # GoPro patterns: GOPR, GH01, GP (for Hero sessions)
                if any(filename_upper.startswith(prefix) for prefix in ['GOPR', 'GH01', 'GP']):
                    pattern_scores['gopro'] = pattern_scores.get('gopro', 0) + 1
                
                # GoPro MAX: GS01xxxx.360
                if filename_upper.startswith('GS') and filename_lower.endswith('.360'):
                    pattern_scores['gopro'] = pattern_scores.get('gopro', 0) + 2  # Higher confidence
                
                # DJI Drone: DJI_, PANO_ (for panoramas)
                if any(filename_upper.startswith(prefix) for prefix in ['DJI_', 'PANO_']):
                    pattern_scores['drone'] = pattern_scores.get('drone', 0) + 1
                
                # 360 Camera: *.360 extension
                if filename_lower.endswith('.360'):
                    pattern_scores['360'] = pattern_scores.get('360', 0) + 1
                
                # Insta360: .insv, .insp, VID_ prefix
                if filename_lower.endswith(('.insv', '.insp')) or filename_upper.startswith('VID_'):
                    pattern_scores['insta360'] = pattern_scores.get('insta360', 0) + 1
                
                # iPhone: IMG_ prefix (common for iOS media)
                if filename_upper.startswith('IMG_') and Path(filename).suffix.lower() in MEDIA_EXTS:
                    pattern_scores['iphone'] = pattern_scores.get('iphone', 0) + 1
                
                # Sony: DSC_ or C00 prefix
                if filename_upper.startswith(('DSC_', 'C00')):
                    pattern_scores['sony'] = pattern_scores.get('sony', 0) + 1
                
                # Panasonic Lumix G7: Pxxxxxxx.mp4 (starts with capital P)
                if len(filename) > 0 and filename[0] == 'P' and filename[0].isupper():
                    if Path(filename).suffix.lower() in MEDIA_EXTS:
                        pattern_scores['lumix_g7'] = pattern_scores.get('lumix_g7', 0) + 1
                
            if checked >= max_check:
                break
        
        # Return the device with highest pattern score
        if pattern_scores:
            best_match = max(pattern_scores.items(), key=lambda x: x[1])
            device, score = best_match
            logger.info(f"Detected '{device}' via filename patterns (score: {score}/{checked} files)")
            return device
            
    except Exception as e:
        logger.warning(f"Filename pattern detection failed: {e}")
    
    # Step 3: Fallback to mount name patterns
    name = root.name.lower()
    if 'gopro' in name:
        logger.info(f"Detected 'gopro' via mount name: {root.name}")
        return 'gopro'
    
    # DJI
    if (root / 'DCIM' / '100MEDIA').exists() or 'dji' in name:
        logger.info(f"Detected 'drone' via mount structure/name: {root.name}")
        return 'drone'
    
    # 360
    if any(s in name for s in ('360', 'max', 'fusion')):
        logger.info(f"Detected '360' via mount name: {root.name}")
        return '360'
    
    # Insta360
    if 'insta360' in name:
        logger.info(f"Detected 'insta360' via mount name: {root.name}")
        return 'insta360'
    
    # Lumix G7 hints
    if any(s in name for s in ('lumix', 'panasonic', 'g7')):
        logger.info(f"Detected 'lumix_g7' via mount name: {root.name}")
        return 'lumix_g7'
    
    # iPhone hints
    if 'iphone' in name or 'apple' in name:
        logger.info(f"Detected 'iphone' via mount name: {root.name}")
        return 'iphone'
    
    logger.info(f"No specific device detected, defaulting to 'camera' for mount: {root.name}")
    return 'camera'
