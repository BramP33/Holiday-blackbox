from __future__ import annotations
import os
from pathlib import Path
from .config import load_config


class Paths:
    def __init__(self, cfg: dict | None = None):
        self.cfg = cfg or load_config()
        self.nvme_mount = Path(self.cfg['paths']['nvme_mount'])
        self.root = self.nvme_mount / 'Blackbox'
        self.trips = self.root / 'trips'
        self.proxies = self.root / self.cfg['paths'].get('proxies_subdir', 'proxies')
        self.logs = self.root / 'logs'

    def ensure(self):
        for p in [self.root, self.trips, self.proxies, self.logs]:
            p.mkdir(parents=True, exist_ok=True)
        return self

    def trip_root(self) -> Path:
        t = self.cfg['trip']['name']
        path = self.trips / t
        path.mkdir(parents=True, exist_ok=True)
        return path

    def photos_dir(self) -> Path:
        p = self.trip_root() / 'photos'
        p.mkdir(parents=True, exist_ok=True)
        return p

    def videos_dir(self, date_str: str, device_label: str) -> Path:
        p = self.trip_root() / date_str / device_label
        p.mkdir(parents=True, exist_ok=True)
        return p

    def proxies_dir(self) -> Path:
        self.proxies.mkdir(parents=True, exist_ok=True)
        return self.proxies
