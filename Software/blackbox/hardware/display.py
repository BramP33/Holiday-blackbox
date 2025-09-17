from __future__ import annotations
import os
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

    def supports_partial(self) -> bool:
        return False

    def render_partial(self, img: Image.Image, bbox: tuple[int, int, int, int]):
        # Default implementation falls back to a full refresh.
        self.render(img)


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
        self._partial_enabled = os.environ.get('BLACKBOX_PARTIAL', '0') == '1'
        self._partial_initted = False
        self._partial_since_full = 0
        self._partial_limit = 6

    def clear(self):
        self.epd.Clear(0xFF)

    def supports_partial(self) -> bool:
        return self._partial_enabled and hasattr(self.epd, 'display_Partial') and hasattr(self.epd, 'Init_Partial')

    def render(self, img: Image.Image):
        from waveshare_epd import epd2in7_V2  # type: ignore
        # Convert to buffer and display
        self.epd.display(self.epd.getbuffer(img))
        self._partial_initted = False
        self._partial_since_full = 0

    def _ensure_partial_init(self):
        if not self._partial_initted:
            init_partial = getattr(self.epd, 'Init_Partial', None)
            if callable(init_partial):
                init_partial()
            self._partial_initted = True

    def render_partial(self, img: Image.Image, bbox: tuple[int, int, int, int]):
        if not self.supports_partial() or not bbox:
            self.render(img)
            return

        x0, y0, x1, y1 = bbox
        if x1 <= x0 or y1 <= y0:
            return

        if self._partial_since_full >= self._partial_limit:
            self.render(img)
            return

        self._ensure_partial_init()

        buf = self.epd.getbuffer(img)

        # Convert landscape coordinates to the panel's native orientation.
        # Panel width/height match the driver's portrait layout (176x264).
        panel_height = getattr(self.epd, 'height', 264)
        panel_width = getattr(self.epd, 'width', 176)

        disp_x0 = int(max(0, min(panel_width, y0)))
        disp_x1 = int(max(0, min(panel_width, y1)))
        disp_y0 = int(max(0, min(panel_height, panel_height - x1)))
        disp_y1 = int(max(0, min(panel_height, panel_height - x0)))

        # Align X bounds to full bytes to keep the driver happy.
        disp_x0 = max(0, (disp_x0 // 8) * 8)
        disp_x1 = min(panel_width, ((disp_x1 + 7) // 8) * 8)

        if disp_x1 <= disp_x0 or disp_y1 <= disp_y0:
            self.render(img)
            return

        # The driver expects end coordinates to be exclusive; it will adjust internally.
        self.epd.display_Partial(buf, disp_x0, disp_y0, disp_x1, disp_y1)
        self._partial_since_full += 1


def get_waveshare_display():
    try:
        disp = WaveshareDisplay()
        print("[Display] Using Waveshare 2.7\" V2 EPD")
        return disp
    except Exception as e:
        print("[Display] Waveshare init failed:", e)
        print("[Display] Falling back to MockDisplay (writing PNG frames)")
        return MockDisplay()


def load_font(size: int = 18):
    # Use a default PIL bitmap font when truetype not present
    try:
        return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)
    except Exception:
        return ImageFont.load_default()
