#!/usr/bin/env bash
set -e
SSID=${1:-Blackbox}
PASS=${2:-pi}
if command -v nmcli >/dev/null 2>&1; then
  nmcli dev wifi hotspot ifname wlan0 ssid "$SSID" password "$PASS"
else
  echo "nmcli not found; please install NetworkManager or provide alternative."
  exit 1
fi

