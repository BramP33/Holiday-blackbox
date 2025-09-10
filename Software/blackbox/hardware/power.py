from __future__ import annotations
import subprocess


def is_undervoltage() -> bool:
    """Return True if Pi reports undervoltage via vcgencmd.

    When vcgencmd is unavailable (dev), return False.
    """
    try:
        out = subprocess.check_output(['vcgencmd', 'get_throttled'], text=True)
        # output like: throttled=0x0 or 0x50000 etc.
        if '0x0' in out:
            return False
        # Bit 0 (undervoltage now) or 16 (has happened) -> warn, treat as low power if bit0 set
        val = int(out.strip().split('=')[1], 16)
        return bool(val & 0x1)
    except Exception:
        return False

