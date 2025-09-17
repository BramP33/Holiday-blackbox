from __future__ import annotations

import logging
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import requests

DEFAULT_HOST = '172.23.0.51'
DEFAULT_PORT = 8080

logger = logging.getLogger(__name__)


class GoProHttp:
    def __init__(self, host: str = DEFAULT_HOST, timeout: float = 5.0):
        self.base = f'http://{self._normalise_host(host)}'
        self.session = requests.Session()
        self.timeout = timeout

    @staticmethod
    def _normalise_host(host: str) -> str:
        if '://' in host:
            return host.split('://', 1)[1]
        if ':' in host.rsplit(']', 1)[-1]:  # rudimentary IPv6/IPv4 port check
            return host
        return f'{host}:{DEFAULT_PORT}'

    def _get_json(self, path: str) -> Dict:
        url = f'{self.base}{path}'
        resp = self.session.get(url, timeout=self.timeout)
        resp.raise_for_status()
        return resp.json()

    def enable_wired_usb(self) -> None:
        try:
            self.session.get(
                f'{self.base}/gopro/camera/control/wired_usb',
                params={'p': 1},
                timeout=self.timeout,
            ).raise_for_status()
        except requests.RequestException as exc:
            logger.debug("wired_usb enable failed: %s", exc)

    def keep_alive(self) -> None:
        try:
            self.session.get(
                f'{self.base}/gopro/camera/keep_alive',
                timeout=self.timeout,
            ).raise_for_status()
        except requests.RequestException as exc:
            logger.debug("keep_alive failed: %s", exc)

    def claim_control(self) -> None:
        try:
            self.session.get(
                f'{self.base}/gopro/camera/control/set_camera_control',
                params={'p': 2},
                timeout=self.timeout,
            ).raise_for_status()
        except requests.RequestException as exc:
            logger.debug("set_camera_control failed: %s", exc)

    def media_list(self) -> List[Dict]:
        self.enable_wired_usb()
        errors: List[Exception] = []
        for path in self._media_list_paths():
            try:
                data = self._get_json(path)
                logger.debug("media_list retrieved via %s", path)
                break
            except (requests.RequestException, ValueError) as exc:
                errors.append(exc)
                logger.debug("media_list failed via %s: %s", path, exc)
        else:
            raise errors[-1]
        out: List[Dict] = []
        for media in data.get('media', []) or []:
            directory = media.get('d') or ''
            for fi in media.get('fs', []) or []:
                name = fi.get('n')
                if not name:
                    continue
                out.append({
                    'directory': directory,
                    'filename': name,
                    'size': int(fi.get('s') or 0),
                    'created': fi.get('cre') or fi.get('mod'),
                    'type': fi.get('l') or '',
                })
        return out

    def download(self, remote_rel: str, dest: Path, progress=None) -> None:
        url = f"{self.base}/videos/{remote_rel.lstrip('/')}"
        with self.session.get(url, stream=True, timeout=self.timeout) as r:
            r.raise_for_status()
            total = int(r.headers.get('Content-Length', '0') or 0)
            done = 0
            dest.parent.mkdir(parents=True, exist_ok=True)
            with open(dest, 'wb') as fh:
                for chunk in r.iter_content(chunk_size=1024*1024):
                    if not chunk:
                        continue
                    fh.write(chunk)
                    done += len(chunk)
                    if progress:
                        try:
                            progress(done, total)
                        except Exception:
                            pass

    @staticmethod
    def _media_list_paths() -> Iterable[str]:
        # Primary: Open GoPro HTTP API
        # Secondary: legacy gpMediaList for older firmware
        return ('/gopro/media/list', '/gp/gpMediaList')
