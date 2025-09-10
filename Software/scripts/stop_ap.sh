#!/usr/bin/env bash
set -e
if command -v nmcli >/dev/null 2>&1; then
  nmcli con down Hotspot || true
  nmcli con delete Hotspot || true
else
  echo "nmcli not found; nothing to stop."
fi

