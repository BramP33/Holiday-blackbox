from __future__ import annotations
import os
from typing import List


class Buttons:
    """Abstracts the 4 physical buttons on the left side.

    Index top->bottom: 0..3, active-low.
    """

    def __init__(self, pins: List[int] | None = None, dev_mode: bool = False):
        self.dev_mode = dev_mode
        self.pins = pins or [5, 6, 13, 19]
        self._gpio = None
        if not self.dev_mode:
            try:
                import RPi.GPIO as GPIO  # type: ignore
                self._gpio = GPIO
                GPIO.setmode(GPIO.BCM)
                for p in self.pins:
                    GPIO.setup(p, GPIO.IN, pull_up_down=GPIO.PUD_UP)
            except Exception:
                # Fallback to dev_mode if GPIO unavailable
                self.dev_mode = True
                self._gpio = None

    def read(self):
        """Return list[bool] pressed states (top->bottom) or None in dev_mode."""
        if self.dev_mode or not self._gpio:
            return None
        GPIO = self._gpio
        return [GPIO.input(p) == GPIO.LOW for p in self.pins]
