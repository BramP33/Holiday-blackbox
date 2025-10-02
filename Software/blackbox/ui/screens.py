from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, List
from PIL import Image, ImageDraw

from ..hardware.display import load_font
from ..i18n import t as tr


@dataclass
class ScreenContext:
    language: str = 'en'
    trip_name: str = 'Trip'


class ScreenBase:
    def __init__(self, width: int, height: int, language: str = 'en'):
        self.width = width
        self.height = height
        self.language = (language or 'en').lower()
        # Tuned for 264x176 display
        self.font_h1 = load_font(24)
        self.font_big = load_font(18)
        self.font_mid = load_font(13)
        self.font_small = load_font(11)

    def draw(self) -> Image.Image:
        raise NotImplementedError


class HomeScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str = 'en', selected: int = 0):
        super().__init__(width, height, language)
        self.selected = selected

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        y = 10
        items = [
            tr(self.language, 'home.menu.start_backup'),
            tr(self.language, 'home.menu.webserver'),
            tr(self.language, 'home.menu.info'),
            tr(self.language, 'home.menu.settings'),
        ]
        for idx, text in enumerate(items):
            line = f" {text}"
            d.text((8, y), line, font=self.font_big, fill=0)
            if idx == self.selected:
                arrow_x = self.width - 20
                d.text((arrow_x, y), '<', font=self.font_big, fill=0)
            y += 26
        return img


class InfoScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, stats: dict, *, status: Optional[str] = None, show_index_action: bool = False):
        super().__init__(width, height, language)
        self.stats = stats
        self.status = status
        self.show_index_action = show_index_action

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 4), tr(self.language, 'info.title'), font=self.font_h1, fill=0)
        y = 32
        stats = self.stats or {}
        trip_name = str(stats.get('trip_name') or '').strip()
        if trip_name:
            trip_line = tr(self.language, 'info.trip', name=trip_name)
        else:
            trip_line = tr(self.language, 'info.trip_unknown')
        video_text = stats.get('video_duration') or '0m'
        photo_count = stats.get('photo_count') or 0
        free_text = stats.get('free_gb') or '0gb'

        data_lines = [
            trip_line,
            tr(self.language, 'info.video', duration=video_text),
            tr(self.language, 'info.photo', count=photo_count),
            tr(self.language, 'info.free', gb=free_text),
        ]
        line_gap = 16
        for line in data_lines:
            d.text((8, y), line, font=self.font_mid, fill=0)
            y += line_gap

        devices = [str(v).strip() for v in (stats.get('devices') or []) if str(v).strip()]
        d.text((8, y), tr(self.language, 'info.devices_title'), font=self.font_mid, fill=0)
        y += line_gap
        max_device_lines = 3
        if not devices:
            d.text((12, y), tr(self.language, 'info.devices_none'), font=self.font_small, fill=0)
            y += line_gap
        else:
            visible = devices[:max_device_lines]
            remaining = len(devices) - len(visible)
            if remaining > 0 and len(visible) == max_device_lines:
                visible = devices[:max_device_lines - 1]
                remaining = len(devices) - len(visible)
            for name in visible:
                label = name if len(name) <= 24 else name[:23] + '…'
                d.text((12, y), label, font=self.font_small, fill=0)
                y += line_gap
            if remaining > 0:
                more_line = tr(self.language, 'info.devices_more', count=remaining)
                d.text((12, y), more_line, font=self.font_small, fill=0)
                y += line_gap

        footer_items: List[tuple] = []
        footer_items.append((self.font_mid, tr(self.language, 'common.home')))
        if self.show_index_action:
            footer_items.insert(0, (self.font_small, tr(self.language, 'info.index_hint')))
        if self.status:
            footer_items.insert(0, (self.font_small, self.status))

        line_gap_small = 14
        y_footer = self.height - 18
        for font, text in reversed(footer_items):
            d.text((8, y_footer), text, font=font, fill=0)
            y_footer -= line_gap_small
        return img


class ProgressBar:
    def __init__(self, width: int, height: int, x: int, y: int):
        self.width = width
        self.height = height
        self.x = x
        self.y = y

    def draw(self, d: ImageDraw.ImageDraw, fraction: float):
        fraction = max(0.0, min(1.0, fraction))
        d.rectangle([self.x, self.y, self.x+self.width, self.y+self.height], outline=0, width=1, fill=1)
        fill_w = int(self.width * fraction)
        if fill_w > 0:
            d.rectangle([self.x, self.y, self.x+fill_w, self.y+self.height], outline=0, width=0, fill=0)


class BackupScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, device_label: str, copying_from: str, copying_to: str, eta_min: Optional[int], remaining_gb: str, progress: float):
        super().__init__(width, height, language)
        self.device_label = device_label
        self.copying_from = copying_from
        self.copying_to = copying_to
        self.eta_min = eta_min
        self.remaining_gb = remaining_gb
        self.progress = progress

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 6), tr(self.language, 'backup.title'), font=self.font_h1, fill=0)
        d.text((8, 36), tr(self.language, 'backup.from', path=self.copying_from), font=self.font_small, fill=0)
        d.text((8, 50), tr(self.language, 'backup.to', path=self.copying_to), font=self.font_small, fill=0)
        if self.eta_min is not None:
            d.text((8, 64), tr(self.language, 'backup.eta', minutes=self.eta_min), font=self.font_small, fill=0)
        bar = ProgressBar(self.width-16, 14, 8, 88)
        bar.draw(d, self.progress)
        d.text((8, 110), tr(self.language, 'backup.free_space', gb=self.remaining_gb), font=self.font_mid, fill=0)
        d.text((8, self.height-18), tr(self.language, 'common.home'), font=self.font_mid, fill=0)
        return img


class VerifyScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, method: str, progress: float):
        super().__init__(width, height, language)
        self.method = method
        self.progress = progress

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 6), tr(self.language, 'verify.title'), font=self.font_h1, fill=0)
        d.text((8, 34), tr(self.language, 'verify.method', method=self.method), font=self.font_mid, fill=0)
        bar = ProgressBar(self.width-16, 14, 8, 70)
        bar.draw(d, self.progress)
        d.text((8, self.height-18), tr(self.language, 'common.home'), font=self.font_mid, fill=0)
        return img


class ProxiesScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, done: int, total: int, current_name: str | None = None):
        super().__init__(width, height, language)
        self.done = done
        self.total = total
        self.current_name = current_name or ''

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 6), tr(self.language, 'proxies.title'), font=self.font_h1, fill=0)
        # Progress text
        d.text((8, 36), tr(self.language, 'proxies.items_done', done=self.done, total=self.total), font=self.font_mid, fill=0)
        if self.current_name:
            # Truncate current filename to fit
            shown = (self.current_name[:34] + '…') if len(self.current_name) > 35 else self.current_name
            d.text((8, 52), tr(self.language, 'proxies.building', name=shown), font=self.font_small, fill=0)
        # Progress bar
        frac = 0.0 if self.total <= 0 else float(self.done) / float(max(1, self.total))
        bar = ProgressBar(self.width-16, 14, 8, 88)
        bar.draw(d, frac)
        d.text((8, self.height-18), tr(self.language, 'common.home'), font=self.font_mid, fill=0)
        return img


class DoneScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, files_count: int):
        super().__init__(width, height, language)
        self.files_count = files_count

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 10), tr(self.language, 'done.title'), font=self.font_h1, fill=0)
        d.text((8, 48), tr(self.language, 'done.summary_files', n=self.files_count), font=self.font_mid, fill=0)
        d.text((8, self.height-18), tr(self.language, 'common.home'), font=self.font_mid, fill=0)
        return img


class WebserverConfirmScreen(ScreenBase):
    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), tr(self.language, 'web.confirm_start_title'), font=self.font_h1, fill=0)
        # Show literal 'yes' as requested
        d.text((8, 46), 'yes', font=self.font_big, fill=0)
        d.text((8, 74), tr(self.language, 'web.no_go_home'), font=self.font_big, fill=0)
        return img


class WebserverEnabledScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, url: str):
        super().__init__(width, height, language)
        self.url = url

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), tr(self.language, 'web.enabled_title'), font=self.font_h1, fill=0)
        d.text((8, 42), tr(self.language, 'web.url_label'), font=self.font_mid, fill=0)
        d.text((8, 58), self.url, font=self.font_mid, fill=0)
        d.text((8, self.height-18), tr(self.language, 'web.hint_stop'), font=self.font_mid, fill=0)
        return img


class SettingsScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, verify: str, power_off: str, proxies_enabled: bool, tone: bool, network_mode: str = 'ap', ui_language: str = 'en', selected: int = 0):
        super().__init__(width, height, language)
        self.verify = verify
        self.power_off = power_off
        self.proxies_enabled = proxies_enabled
        self.tone = tone
        self.network_mode = network_mode
        self.ui_language = (ui_language or 'en').lower()
        self.selected = selected

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 6), tr(self.language, 'settings.title'), font=self.font_h1, fill=0)
        y = 38
        items = [
            (tr(self.language, 'settings.items.verification'), tr(self.language, 'settings.values.fast' if self.verify=='fast' else 'settings.values.sha256')),
            (tr(self.language, 'settings.items.power_off'), tr(self.language, f"settings.power_values.{self.power_off}")),
            # Show literal 'on'/'off' for these toggles
            (tr(self.language, 'settings.items.proxies'), 'on' if self.proxies_enabled else 'off'),
            (tr(self.language, 'settings.items.tone'), 'on' if self.tone else 'off'),
            (tr(self.language, 'settings.items.network'), tr(self.language, 'settings.values.ap' if (self.network_mode or 'ap').lower()=='ap' else 'settings.values.wifi')),
            (tr(self.language, 'settings.items.language'), tr(self.language, 'settings.values.lang_nl' if self.ui_language=='nl' else 'settings.values.lang_en')),
        ]
        for idx, (k, v) in enumerate(items):
            prefix = '>' if idx == self.selected else ' '
            d.text((8, y), f"{prefix} {k}  {v}", font=self.font_mid, fill=0)
            y += 18
        d.text((8, self.height-18), tr(self.language, 'common.home'), font=self.font_mid, fill=0)
        return img


class SettingsConfirmScreen(ScreenBase):
    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), tr(self.language, 'settings.save_confirm_title'), font=self.font_h1, fill=0)
        d.text((8, 34), tr(self.language, 'settings.save_confirm_question'), font=self.font_mid, fill=0)
        # Order to match buttons: 1=Yes (top), 2=No (below)
        # Show literal 'yes'/'no' as requested
        d.text((8, 60), 'yes', font=self.font_mid, fill=0)
        d.text((8, 80), 'no', font=self.font_mid, fill=0)
        d.text((8, self.height-18), tr(self.language, 'settings.back_to_settings'), font=self.font_mid, fill=0)
        return img


class ErrorScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, message: str):
        super().__init__(width, height, language)
        self.message = message

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), tr(self.language, 'common.error'), font=self.font_h1, fill=0)
        d.text((8, 34), self.message[:40], font=self.font_mid, fill=0)
        d.text((8, self.height-18), tr(self.language, 'common.home'), font=self.font_mid, fill=0)
        return img


class DeviceDetectedScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, title_key: str | None = None, start_key: str | None = None):
        super().__init__(width, height, language)
        self.title_key = title_key or 'device.detected_title'
        self.start_key = start_key or 'device.start_backup_button'

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), tr(self.language, self.title_key), font=self.font_h1, fill=0)
        d.text((8, 46), tr(self.language, self.start_key), font=self.font_big, fill=0)
        d.text((8, 74), tr(self.language, 'device.dismiss_button'), font=self.font_big, fill=0)
        return img


class DeviceRemovedScreen(ScreenBase):
    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), tr(self.language, 'device.removed_title'), font=self.font_h1, fill=0)
        d.text((8, self.height-18), tr(self.language, 'common.home'), font=self.font_mid, fill=0)
        return img


class TripPowerOffScreen(ScreenBase):
    def __init__(self, width: int, height: int, language: str, trip_name: str, begin_date: str, end_date: str, places: List[str]):
        super().__init__(width, height, language)
        self.trip_name = trip_name or ''
        self.begin_date = begin_date or ''
        self.end_date = end_date or ''
        self.places = places or []

    def _text_center(self, d: ImageDraw.ImageDraw, y: int, text: str, font) -> None:
        try:
            bbox = d.textbbox((0, 0), text, font=font)
            w = (bbox[2] - bbox[0]) if bbox else 0
        except Exception:
            try:
                w = d.textlength(text, font=font)
            except Exception:
                w = 0
        x = max(0, int((self.width - w) / 2))
        d.text((x, y), text, font=font, fill=1)

    def draw(self) -> Image.Image:
        # Black background, white text
        img = Image.new('1', (self.width, self.height), 0)
        d = ImageDraw.Draw(img)
        # Title: --Tripname--
        title = f"--{self.trip_name.strip()}--" if self.trip_name.strip() else "--"
        y = 10
        self._text_center(d, y, title, self.font_big)
        # Date range
        y += 26
        rng = tr(self.language, 'power.date_range', begin=self.begin_date, end=self.end_date)
        self._text_center(d, y, rng, self.font_mid)
        # Places: joined by comma or dot separator
        y += 22
        places_line = ' · '.join([str(p).strip() for p in (self.places or []) if str(p).strip()])
        if places_line:
            self._text_center(d, y, places_line, self.font_mid)
        # Footer: Power-Off label at bottom
        footer = tr(self.language, 'power.power_off_label')
        fw = d.textlength(footer, font=self.font_mid)
        fx = max(0, int((self.width - fw) / 2))
        d.text((fx, self.height-18), footer, font=self.font_mid, fill=1)
        return img


class BootScreen(ScreenBase):
    def draw(self) -> Image.Image:
        # Black background, white text centered
        img = Image.new('1', (self.width, self.height), 0)
        d = ImageDraw.Draw(img)
        text = tr(self.language, 'boot.booting')
        try:
            bbox = d.textbbox((0, 0), text, font=self.font_big)
            tw = (bbox[2] - bbox[0]) if bbox else 0
            th = (bbox[3] - bbox[1]) if bbox else self.font_big.size
        except Exception:
            try:
                tw = d.textlength(text, font=self.font_big)
            except Exception:
                tw = 0
            th = self.font_big.size
        x = max(0, int((self.width - tw) / 2))
        y = max(0, int((self.height - th) / 2))
        d.text((x, y), text, font=self.font_big, fill=1)
        return img 
