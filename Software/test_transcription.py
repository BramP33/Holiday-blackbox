#!/usr/bin/env python3
"""Quick test to transcribe a sample video with the new small model."""

import sys
from pathlib import Path

# Add Software dir to path
sys.path.insert(0, str(Path(__file__).parent))

from blackbox.config import load_config
from blackbox.paths import Paths
from blackbox.transcription.worker import TranscriptionWorker

def main():
    print("=== Whisper Small Model Transcription Test ===\n")
    
    # Load config and paths
    cfg = load_config()
    paths = Paths(cfg).ensure()
    
    # Create worker
    worker = TranscriptionWorker(paths, cfg=cfg)
    
    # Show config
    whisper_cfg = cfg.get('transcription', {}).get('whisper', {})
    print(f"Model: {whisper_cfg.get('model', 'unknown')}")
    print(f"Language: {whisper_cfg.get('language', 'auto')}")
    print(f"Beam size: {whisper_cfg.get('beam_size', 5)}")
    print(f"Device: {whisper_cfg.get('device', 'cpu')}")
    print(f"\nProcessing videos...\n")
    
    # Process all pending
    count = 0
    while worker.process_next():
        count += 1
        print(f"Processed {count} video(s)")
    
    if count == 0:
        print("No videos to transcribe (queue empty or all done)")
    else:
        print(f"\n=== Completed {count} transcription(s) ===")

if __name__ == '__main__':
    main()
