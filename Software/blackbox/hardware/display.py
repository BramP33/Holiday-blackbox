from __future__ import annotations
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import datetime as _dt


class DisplayBase:
    width: int = 264
    height: int = 176

    def clear(self):
        raise NotImplementedError

    def render(self, img: Image.Image):
        raise NotImplementedError


class MockDisplay(DisplayBase):
    """Developer display that writes frames to PNG files.

    This keeps dimensions close to Waveshare 2.7" v2 (264x176) landscape.
    """

    def __init__(self, out_dir: Path | None = None):
        self.out = Path(out_dir or 'run_output')
        self.out.mkdir(parents=True, exist_ok=True)
        self.counter = 0

    def clear(self):
        img = Image.new('1', (self.width, self.height), 1)
        self.render(img)

    def render(self, img: Image.Image):
        self.counter += 1
        ts = _dt.datetime.now().strftime('%Y%m%d-%H%M%S')
        path = self.out / f'frame-{ts}-{self.counter:04d}.png'
        img.save(path)
        return path


class WaveshareDisplay(DisplayBase):
    def __init__(self):
        from waveshare_epd import epd2in7_V2  # type: ignore
        self.epd = epd2in7_V2.EPD()
        self.epd.init()
        # 2.7" v2 is 264x176 — ensure landscape orientation
        self.width = 264
        self.height = 176

    def clear(self):
        self.epd.Clear(0xFF)

    def render(self, img: Image.Image):
        from waveshare_epd import epd2in7_V2  # type: ignore
        # Convert to buffer and display
        self.epd.display(self.epd.getbuffer(img))


def get_waveshare_display():
    try:
        return WaveshareDisplay()
    except Exception:
        return MockDisplay()


def load_font(size: int = 18):
    # Use a default PIL bitmap font when truetype not present
    try:
        return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)
    except Exception:
        return ImageFont.load_default()
