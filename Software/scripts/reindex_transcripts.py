#!/usr/bin/env python3
"""Requeue video transcripts when switching Whisper models."""
from __future__ import annotations

import argparse
from pathlib import Path

from Software.blackbox.config import load_config
from Software.blackbox.paths import Paths
from Software.blackbox.transcription import TranscriptionQueue

VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}


def iter_videos(root: Path):
    for path in root.rglob('*'):
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS:
            yield path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Requeue transcripts for existing videos')
    parser.add_argument(
        '--all',
        action='store_true',
        help='Requeue every video even if it already has a transcript for the current model',
    )
    args = parser.parse_args(argv)

    cfg = load_config()
    whisper_cfg = (cfg.get('transcription') or {}).get('whisper') or {}
    target_model = whisper_cfg.get('model') or 'tiny.en'

    paths = Paths(cfg).ensure()
    queue = TranscriptionQueue(paths)
    trip_root = paths.trip_root().resolve()

    jobs = {job['path']: job for job in queue.all_jobs()}

    total_files = 0
    requeued = 0
    for video in iter_videos(trip_root):
        total_files += 1
        rel = video.relative_to(trip_root).as_posix()
        job = jobs.get(rel)
        should_requeue = args.all or job is None
        if not should_requeue and job:
            state = job.get('state')
            model = job.get('transcript_model')
            if state != 'done' or model != target_model:
                should_requeue = True
        if should_requeue:
            if queue.enqueue(video, force=True):
                requeued += 1
    print(f'Requeued {requeued} of {total_files} videos (model={target_model})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
