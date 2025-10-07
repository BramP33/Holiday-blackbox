#!/usr/bin/env python3
"""Run hardware and storage self-tests for Holiday Blackbox."""

from __future__ import annotations

import argparse
import json
from typing import Any

from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from Software.blackbox.config import load_config
from Software.blackbox.health import collect_health
from Software.blackbox.paths import Paths


def _print_human(summary: dict[str, Any]) -> None:
    nvme = summary.get('nvme', {})
    display = summary.get('display', {})
    buttons = summary.get('buttons', {})
    transcription = summary.get('transcription', {})

    def status_line(title: str, status: str, detail: str | None = None) -> None:
        if detail:
            print(f"{title:<18} {status:<10} {detail}")
        else:
            print(f"{title:<18} {status}")

    nvme_detail = None
    if nvme.get('status') != 'missing' and nvme.get('total_gb'):
        nvme_detail = (
            f"{nvme.get('free_gb')} GB free / {nvme.get('total_gb')} GB total"
        )
    status_line('NVMe storage', nvme.get('status', 'unknown'), nvme_detail)

    display_detail = []
    if display.get('driver_present'):
        display_detail.append('driver')
    if display.get('spidev0') or display.get('spidev1'):
        display_detail.append('spidev')
    if display.get('mock_requested'):
        display_detail.append('mock-mode')
    status_line('Display', display.get('status', 'unknown'), ', '.join(display_detail) or None)

    buttons_detail = None
    if isinstance(buttons.get('pressed'), list):
        buttons_detail = f"pressed={buttons['pressed']}"
    status_line('Buttons', buttons.get('status', 'unknown'), buttons_detail)

    counts = transcription.get('counts', {})
    tran_detail = ', '.join(f"{k}={v}" for k, v in sorted(counts.items())) or None
    status_line('Transcription', 'ok', tran_detail)

    recent = transcription.get('recent_errors') or []
    if recent:
        print('\nRecent transcription errors:')
        for item in recent:
            stamp = item.get('updated_at') or 'n/a'
            msg = item.get('last_error') or ''
            path = item.get('path') or ''
            print(f" - [{stamp}] {path}: {msg}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true', help='Emit JSON instead of text')
    parser.add_argument(
        '--skip-buttons',
        action='store_true',
        help='Skip probing GPIO button states (safe if UI service already running)',
    )
    args = parser.parse_args()

    cfg = load_config()
    paths = Paths(cfg).ensure()
    summary = collect_health(paths, cfg, probe_buttons=not args.skip_buttons)

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(f"Generated at: {summary.get('generated_at')}")
        _print_human(summary)


if __name__ == '__main__':
    main()
