#!/usr/bin/env python3
"""Add a test transcript to verify the delete button appears."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from blackbox.config import load_config
from blackbox.paths import Paths
from blackbox.transcription.queue import TranscriptionQueue

def main():
    cfg = load_config()
    paths = Paths(cfg)
    queue = TranscriptionQueue(paths)
    
    # Get first video
    root = paths.trip_root()
    videos = list(root.rglob('*.mp4')) + list(root.rglob('*.MP4'))
    
    if not videos:
        print("No videos found")
        return
    
    video_path = str(videos[0].relative_to(root))
    print(f"Adding test transcript for: {video_path}")
    
    # Add a test transcript
    queue.enqueue(video_path, force=True)
    queue.mark_done(video_path, [
        {"start": 0.0, "end": 3.0, "text": "Dit is een test transcript"},
        {"start": 3.0, "end": 6.0, "text": "Om te testen of de delete knop werkt"},
    ])
    
    print("✓ Test transcript added")
    print(f"  Video: {video_path}")

if __name__ == '__main__':
    main()
