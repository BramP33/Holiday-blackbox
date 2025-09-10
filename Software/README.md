Holiday Blackbox — Raspberry Pi 5 backup device

This folder contains the software for the e‑paper UI, backup/verify pipeline, proxy generator, AP mode helpers, and a lightweight web UI. It targets a Raspberry Pi 5 with a Waveshare 2.7" mono e‑paper, internal NVMe SSD, and a micro‑SD card reader.

Key modules:
- blackbox/main.py — entrypoint running the UI state machine.
- blackbox/config.py — load/save YAML config.
- blackbox/paths.py — resolves storage and cache directories.
- blackbox/hardware/display.py — e‑paper wrapper (and a PNG mock output for dev).
- blackbox/hardware/buttons.py — button abstraction (GPIO stubs + keyboard dev mode).
- blackbox/ui/screens.py — screen rendering according to the mockups.
- blackbox/backup/backup.py — copy + verify + dedup.
- blackbox/backup/scanner.py — locate source media with DCIM.
- blackbox/proxies/generate.py — create 480p H.264 proxies and photo thumbnails.
- blackbox/web/app.py — Flask web UI to browse and download.
- ap_mode.py & scripts/start_ap.sh — enable/disable AP using NetworkManager.

Defaults and paths live in `config.default.yml`; user‑specific config is `config.yml` (copied on first run).

Nothing here performs destructive operations by default. Replace logic is restricted to duplicate file handling when the SHA256 differs (as configured).

Storage layout (per requirements):
- trips/<TripName>/photos — all photos (any camera) in one folder.
- trips/<TripName>/<YYYY-MM-DD>/<device>/ — videos grouped by date and detected device name (`gopro`, `drone`, `360`, `camera`).
- proxies/ — generated 480p H.264 video proxies and photo thumbnails (max total size capped by config).

Deduplication:
- If a destination filename exists: compute SHA256 on both source and destination. If equal → skip; if different → replace destination with source copy. After each copy, verify using `verify.default_mode` (`fast`=size match, or `sha256`).

AP mode:
- Not auto‑enabled. Users start it from the UI. Scripts rely on NetworkManager (`nmcli`) and broadcast SSID/password from config.

Multiple sources:
- If more than one mounted source with a `DCIM` folder is detected, the UI shows an error: "2 cards detected! Remove one to continue." (manual backup only).

Device labels:
- Device classification uses simple heuristics (gopro/drone/360/lumix_g7/camera). Folder labels are configurable via `device_labels` in `config.yml` (defaults: Gopro, Drone, 360, Lumix G7, Camera).

Web API pagination:
- `/photos` and `/videos` return JSON with `page`, `page_size`, `total`, and `items`. Page size is configurable (`web.page_size`, default 50).

Hardware
- E‑paper: Waveshare 2.7" v2 (`epd2in7_V2`). If the Waveshare Python libs are installed (`waveshare_epd`), the app will use the real display; otherwise it renders frames to `run_output/` as PNG for development.
- Buttons: 4 side buttons with internal pull‑ups, active‑low (BCM): top→bottom `[5, 6, 13, 19]`. You can change in `hardware.buttons`.
- Power: undervoltage detection via `vcgencmd get_throttled`; backup pauses and the UI shows an error until power is stable.

Web UI
- `/photos` and `/videos` also serve simple paginated HTML galleries (50 per page by default) that display photo thumbnails and play 480p H.264 video proxies with a download link for the original.

**NVMe Boot (Recommended for Performance)**
- Goal: Boot Raspberry Pi OS Lite directly from the NVMe SSD so the system is fast and reliable. You can still use the same NVMe for storing backups.
- What you need: a USB–NVMe adapter or enclosure to connect the SSD to your computer while flashing.
- Steps:
  1) On your computer install Raspberry Pi Imager. Insert the NVMe via USB adapter.
  2) In Imager: choose OS → Raspberry Pi OS Lite (64‑bit). Choose Storage → your NVMe drive.
  3) Click the gear icon (Advanced): set hostname (e.g., `blackbox`), enable SSH, set username/password, configure Wi‑Fi (if needed), set locale/timezone. Save and Write.
  4) Move the NVMe into the Pi 5’s M.2 adapter. Remove any microSD card. Power on the Pi.
  5) If it doesn’t boot: update the bootloader and set boot order to NVMe/USB first:
     - `sudo apt update && sudo apt full-upgrade -y`
     - `sudo rpi-eeprom-update -a` then `sudo reboot`
     - `sudo raspi-config` → Advanced Options → Boot Order → NVMe/USB first.
  6) Confirm you’re booted from NVMe: `lsblk` should show `/` on `nvme0n1p2` (or similar).
- Data folder for backups: create a writable folder on the NVMe and point the app to it.
  - `sudo mkdir -p /mnt/nvme && sudo chown -R $USER:$USER /mnt/nvme`
  - Edit `Software/config.yml` → `paths.nvme_mount: /mnt/nvme` (the app stores everything in `/mnt/nvme/Blackbox`).
  - Alternatively, create a dedicated data partition and mount it at `/mnt/nvme` (advanced; optional).
