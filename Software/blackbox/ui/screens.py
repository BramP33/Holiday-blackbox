from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from PIL import Image, ImageDraw

from ..hardware.display import load_font


@dataclass
class ScreenContext:
    language: str = 'en'
    trip_name: str = 'Trip'


class ScreenBase:
    def __init__(self, width: int, height: int):
        self.width = width
        self.height = height
        # Tuned for 264x176 display
        self.font_h1 = load_font(24)
        self.font_big = load_font(18)
        self.font_mid = load_font(13)
        self.font_small = load_font(11)

    def draw(self) -> Image.Image:
        raise NotImplementedError


class HomeScreen(ScreenBase):
    def __init__(self, width: int, height: int, selected: int = 0):
        super().__init__(width, height)
        self.selected = selected

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        y = 10
        items = ['Start back-up', 'AP-mode', 'Info', 'Settings']
        for idx, text in enumerate(items):
            prefix = '>' if idx == self.selected else ' '
            # Keep a small right margin to avoid clipping at 264px
            line = f"{prefix} {text}"
            d.text((8, y), line, font=self.font_big, fill=0)
            y += 26
        return img


class InfoScreen(ScreenBase):
    def __init__(self, width: int, height: int, stats: dict):
        super().__init__(width, height)
        self.stats = stats

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 4), 'Info', font=self.font_h1, fill=0)
        y = 40
        lines = [
            f"Video: {self.stats.get('video_hours','0h')}",
            f"Photo: {self.stats.get('photo_count','0')}",
            f"Free: {self.stats.get('free_gb','0gb')}",
            f"Cards backed up: {self.stats.get('cards',0)}",
        ]
        for line in lines:
            d.text((8, y), line, font=self.font_mid, fill=0)
            y += 20
        d.text((8, self.height-18), 'home', font=self.font_mid, fill=0)
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
    def __init__(self, width: int, height: int, device_label: str, copying_from: str, copying_to: str, eta_min: Optional[int], remaining_str: str, progress: float):
        super().__init__(width, height)
        self.device_label = device_label
        self.copying_from = copying_from
        self.copying_to = copying_to
        self.eta_min = eta_min
        self.remaining_str = remaining_str
        self.progress = progress

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 6), 'Backing up', font=self.font_h1, fill=0)
        d.text((8, 36), f"From: {self.copying_from}", font=self.font_small, fill=0)
        d.text((8, 50), f"To:   {self.copying_to}", font=self.font_small, fill=0)
        if self.eta_min is not None:
            d.text((8, 64), f"~{self.eta_min} min remaining", font=self.font_small, fill=0)
        bar = ProgressBar(self.width-16, 14, 8, 88)
        bar.draw(d, self.progress)
        d.text((8, 110), self.remaining_str, font=self.font_mid, fill=0)
        return img


class VerifyScreen(ScreenBase):
    def __init__(self, width: int, height: int, method: str, progress: float):
        super().__init__(width, height)
        self.method = method
        self.progress = progress

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 6), 'Verifying...', font=self.font_h1, fill=0)
        d.text((8, 34), f"Method: {self.method}", font=self.font_mid, fill=0)
        bar = ProgressBar(self.width-16, 14, 8, 70)
        bar.draw(d, self.progress)
        return img


class DoneScreen(ScreenBase):
    def __init__(self, width: int, height: int, files_count: int):
        super().__init__(width, height)
        self.files_count = files_count

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 10), 'Done!', font=self.font_h1, fill=0)
        d.text((8, 48), f"Backed up {self.files_count} files", font=self.font_mid, fill=0)
        d.text((8, self.height-18), 'home', font=self.font_mid, fill=0)
        return img


class APConfirmScreen(ScreenBase):
    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), 'Start AP?', font=self.font_h1, fill=0)
        d.text((8, 46), 'yes', font=self.font_big, fill=0)
        d.text((8, 74), 'No, go back home', font=self.font_big, fill=0)
        return img


class APEnabledScreen(ScreenBase):
    def __init__(self, width: int, height: int, url: str):
        super().__init__(width, height)
        self.url = url

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), 'AP enabled', font=self.font_h1, fill=0)
        d.text((8, 42), 'Web at:', font=self.font_mid, fill=0)
        d.text((8, 58), self.url, font=self.font_mid, fill=0)
        d.text((8, self.height-18), 'home', font=self.font_mid, fill=0)
        return img


class SettingsScreen(ScreenBase):
    def __init__(self, width: int, height: int, verify: str, power_off: str, tone: bool, selected: int = 0):
        super().__init__(width, height)
        self.verify = verify
        self.power_off = power_off
        self.tone = tone
        self.selected = selected

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 6), 'Settings', font=self.font_h1, fill=0)
        y = 38
        items = [
            ("Verification:", 'Fast' if self.verify=='fast' else 'SHA256'),
            ("Power-off:", self.power_off),
            ("Tone:", 'On' if self.tone else 'Off'),
        ]
        for idx, (k, v) in enumerate(items):
            prefix = '>' if idx == self.selected else ' '
            d.text((8, y), f"{prefix} {k}  {v}", font=self.font_mid, fill=0)
            y += 18
        d.text((8, self.height-18), 'home', font=self.font_mid, fill=0)
        return img


class SettingsConfirmScreen(ScreenBase):
    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), 'Settings', font=self.font_h1, fill=0)
        d.text((8, 34), 'Save settings?', font=self.font_mid, fill=0)
        d.text((8, 60), 'no', font=self.font_mid, fill=0)
        d.text((8, 80), 'yes', font=self.font_mid, fill=0)
        return img


class ErrorScreen(ScreenBase):
    def __init__(self, width: int, height: int, message: str):
        super().__init__(width, height)
        self.message = message

    def draw(self) -> Image.Image:
        img = Image.new('1', (self.width, self.height), 1)
        d = ImageDraw.Draw(img)
        d.text((8, 8), 'Error', font=self.font_h1, fill=0)
        d.text((8, 34), self.message[:40], font=self.font_mid, fill=0)
        return img
