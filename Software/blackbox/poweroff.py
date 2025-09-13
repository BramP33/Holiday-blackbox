from __future__ import annotations
import psutil
from .config import load_config
from .paths import Paths
from .hardware.display import get_waveshare_display
from .ui.screens import InfoScreen
from PIL import Image, ImageDraw


def bytes_to_gb(n: int) -> str:
    return f"{n/1_000_000_000:.0f}gb"


def main():
    cfg = load_config()
    paths = Paths(cfg).ensure()
    disp = get_waveshare_display()
    mode = cfg.get('power_off_screen', 'info').lower()

    try:
        if mode == 'clear':
            disp.clear()
            return
        if mode == 'weather':
            img = Image.new('1', (disp.width, disp.height), 1)
            d = ImageDraw.Draw(img)
            d.text((8, 8), 'Weather', fill=0)
            d.text((8, 32), 'No network widget', fill=0)
            d.text((8, 50), 'Configure later', fill=0)
            disp.render(img)
            return
        # Default: info
        free = psutil.disk_usage(str(paths.nvme_mount)).free
        stats = {
            'video_hours': '?',
            'photo_count': '?',
            'free_gb': bytes_to_gb(free),
            'cards': 0,
        }
        screen = InfoScreen(disp.width, disp.height, stats)
        disp.render(screen.draw())
    except Exception:
        try:
            disp.clear()
        except Exception:
            pass


if __name__ == '__main__':
    main()

