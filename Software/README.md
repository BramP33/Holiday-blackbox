# Holiday Blackbox

Holiday Blackbox is a Raspberry Pi 5 field backup appliance for offloading camera media while travelling. It supports both a Waveshare 2.7" monochrome e-paper display and a HyperPixel 4.0 touchscreen (via Flutter), verifies every copy, generates lightweight proxies, and exposes an offline-friendly web gallery and JSON API.

## Who is this for?
The project is made with creators in mind. Outside people who don't mind sleeping in a tent to get the perfect shot.

## Highlights
- Verified ingest from SD cards, USB readers, GoPro Link, and (optionally) iPhone via ifuse.
- Deduplication with SHA-256 comparison and configurable verification modes (`fast` size check or full hash).
- Automatic 480p H.264 proxy generation plus photo thumbnails for quick review.
- Button-driven e-paper UI with a PNG mock display for desktop development.
- Flutter touchscreen UI for HyperPixel 4.0 displays (see `Software/flutter_frontend`).
- Lightweight Flask web UI (`/photos`, `/videos`, `/`) with pagination and downloads.
- Optional access-point mode powered by NetworkManager helpers.
- On-device transcription and keyword indexing (scheduled overnight, with a manual "Index now" trigger on the info screen).

## Hardware Targets
- Raspberry Pi 5 (Raspberry Pi OS Lite, 64-bit recommended).
- Waveshare 2.7" V2 e-paper (epd2in7) connected over SPI.
- Pimoroni HyperPixel 4.0 rectangular touchscreen running the Flutter UI.
- Four active-low buttons on GPIO5, GPIO6, GPIO13, GPIO19 (internal pull-ups).
- NVMe SSD mounted at `/mnt/nvme` (or another path configured in `paths.nvme_mount`).
- Stable 5V/3A power. Undervoltage triggers a pause screen until power recovers.

## Repository Layout (Software/)
- `blackbox/main.py` — entry point running the UI state machine and backup flow.
- `blackbox/config.py` — load/merge default config and persist `config.yml` on first run.
- `blackbox/paths.py` — resolves storage directories (trips, proxies, photos, videos).
- `blackbox/backup/backup.py` — copy, dedupe, verify, metadata indexing.
- `blackbox/backup/scanner.py` — detect mounted sources and infer device labels.
- `blackbox/proxies/generate.py` — ffmpeg-based proxy builder with cache limits.
- `blackbox/ui/screens.py` — renders e-paper frames according to mockups.
- `blackbox/hardware/` — display abstraction, button handling, undervoltage checks, USB monitor.
- `blackbox/web/app.py` — Flask app serving HTML galleries and JSON endpoints.
- `blackbox/iphone/importer.py` — ifuse-based importer for iPhone DCIM/videos.
- `scripts/` — install/update helpers, AP toggles, maintenance utilities.
- `systemd/` — unit templates for the UI, web app, and shutdown screen.

- `flutter_frontend/` — Flutter touchscreen app that talks to the Flask API.

## Getting Started on Raspberry Pi
For the full walkthrough (booting from NVMe, wiring, OS packages), follow [`INSTALL.md`](INSTALL.md).

Quick recap once Raspberry Pi OS Lite is running and the repo is in `~/Holiday-blackbox`:

```bash
cd ~/Holiday-blackbox/Software
chmod +x scripts/*.sh
./scripts/install.sh
# The installer creates .venv, installs Python deps from PyPI, copies systemd units,
# and prints the `sudo systemctl enable --now ...` command to run next.
```

On first launch the app writes `config.yml` beside `config.default.yml`. Edit it to set trip dates, AP credentials, preferred language, proxy limits, and mount paths. Restart with `sudo systemctl restart blackbox blackbox-web` after changes.
## Flutter Frontend Installation
cd ~/Holiday-blackbox/Software/flutter_frontend

# Install dependencies
flutter pub get

# Build for Linux (flutter-pi)
flutter build linux --release

# Copy the bundle to the runtime path
sudo mkdir -p /opt/blackbox_flutter
sudo chown -R blackbox:blackbox /opt/blackbox_flutter
rsync -a build/linux/arm64/release/bundle/ /opt/blackbox_flutter/

# The Flutter app is launched automatically via systemd service
# blackbox-flutter.service starts X11 and runs the Flutter UI on HyperPixel 4.0
# Ensure both backend services are running:
# sudo systemctl start blackbox-web.service blackbox-flutter.service
## Development on a Laptop/Desktop
The display layer automatically falls back to the PNG mock display, so you can run the UI without hardware:

```bash
cd /path/to/Holiday-blackbox/Software
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m blackbox.main          # renders frames into Software/run_output/
python -m blackbox.web.app       # serves the Flask app on http://127.0.0.1:8080
```

Set `BLACKBOX_PARTIAL=1` if you want to exercise partial refresh support with real hardware. Use `scripts/update.sh` to pull new code, update dependencies, and restart systemd units on the Pi.

## Configuration & Storage Layout
- Defaults live in `config.default.yml`; user overrides are written to `config.yml` on first run.
- Primary storage is rooted at `paths.nvme_mount` (default `/mnt/nvme`). The app creates a `Blackbox/` folder containing `trips/`, `proxies/`, and metadata caches.
- Trip media layout:
  - `trips/<TripName>/photos/` — all photos in one folder.
  - `trips/<TripName>/<YYYY-MM-DD>/<device>/` — videos grouped by capture date and detected device (gopro, drone, 360, lumix_g7, camera, etc.).
  - `proxies/` — capped by `previews.max_cache_gb`; contains 480p H.264 proxies and JPEG thumbnails.
- Proxy encoding uses FFmpeg with the software `libx264` encoder; adjust bitrate and height via the `previews` settings.
- Device labels are configurable via `device_labels` and appear in both the UI and folder names.
- Backup stops early if free space would drop below `limits.min_free_gb`.

## Backup and Verification Flow
1. Detects a single mounted source containing `DCIM` (or the raw mount if DCIM absent). Multiple sources raise an error prompt on the UI.
2. Copies media files, deduping by hash when a filename already exists on the destination.
3. Verifies each copy using the configured mode (`fast` size or `sha256`). Failures retrigger a copy once before reporting an error.
4. Video imports update the metadata index to power duration stats and the web gallery.
5. On low voltage the UI warns and pauses until power is stable.

## Transcription & Search
- New video imports are queued for on-device transcription (Whisper via `faster-whisper`) and keyword extraction. Jobs run automatically during the nightly window configured in `transcription.start_time`/`end_time` (default 22:00–07:00).
- You can press the third button on the Info screen to bypass the schedule and start indexing immediately; the screen shows live status while the worker runs in the background.
- To invoke the worker from the shell (e.g., for development), use:
  ```bash
  cd ~/Holiday-blackbox/Software
  source .venv/bin/activate
  python -m blackbox.transcription.worker --once  # process queue and exit
  ```
- Keyword extraction defaults to a lightweight frequency scorer; switch `transcription.keywords.method` to `sentence-transformer` if you also install a compact `sentence-transformers` model for richer semantics.
- Semantic search adds multilingual embeddings (English & Dutch friendly) via the `transcription.semantic` section. Install `sentence-transformers` to enable the default `paraphrase-multilingual-MiniLM-L12-v2` model, or change the model ID/device if you prefer another encoder.

## Web UI & JSON API
- Serves from `0.0.0.0:<port>` (default 8080).
- Endpoints:
  - `/` — landing page with latest photo preview and camping fact of the day.
  - `/photos` and `/videos` — HTML galleries (default 50 items per page) with download links.
  - `/api/photos` and `/api/videos` — paginated JSON (`page`, `page_size`, `total`, `items`).
  - `/api/stats` — trip summary (duration, photos, free space, devices).
  - `/api/backup/start`, `/api/backup/status`, `/api/backup/cancel` — trigger and monitor manual backups.
  - `/preview/<path>` and `/download/<path>` — serve proxies and originals.
- Language strings come from `blackbox/i18n/strings_*.yml`; set `language` in config to switch.

## iPhone Importer
`blackbox.iphone.importer` mounts an iPhone using `ifuse` (libimobiledevice) and copies only video files into the trip folder. Requirements on the Pi:
- `ifuse`, `libimobiledevice`, and FUSE (`libfuse` and `fusermount3`).
- Trusted device pairing (`idevicepair pair`). The importer retries pairing prompts when possible.
- Run the importer from custom tooling by calling `import_videos_from_iphone(Paths(cfg), verify_mode=...)`.

## GoPro MTP Importer
`blackbox.gopro.mtp_importer` prefers using `simple-mtpfs` for wired GoPro transfers. Ensure:
- `simple-mtpfs` and `fuse` packages are installed (`sudo apt-get install simple-mtpfs fuse`).
- Your user is in the `fuse` group (the installer attempts to add it).
- `simple-mtpfs -l` detects the camera before starting the UI. If not, double-check the USB cable and enable GoPro Connect mode on the camera.
When `simple-mtpfs` is unavailable the app falls back to the HTTP importer automatically.

## Access Point Helpers
- `ap_mode.py` toggles AP mode from the UI. Ensure NetworkManager is installed and Wi-Fi credentials are set in `config.yml`.
- `scripts/start_ap.sh` / `scripts/stop_ap.sh` expose manual `nmcli` helpers.

## Maintenance Scripts & Services
- `scripts/install.sh` — prepares `.venv`, installs Python deps, copies systemd unit files, and hints at enabling them.
- `scripts/update.sh` — git pull + pip install + service restart (used by `deploy.sh`).
- `scripts/list_devices.py` — prints per-trip stats for debugging.
- `systemd/blackbox.service` — runs the UI (`python -m blackbox.main`).
- `systemd/blackbox-web.service` — runs the Flask app (`python -m blackbox.web.app`).
- `systemd/blackbox-poweroff.service` — renders a power-off frame when the OS shuts down.

## Additional Documentation
- [`INSTALL.md`](INSTALL.md) — full Pi provisioning, wiring, and troubleshooting guide.
- [`LICENSE`](../LICENSE) — project licensing.
- `deploy.sh` — rsync-based helper to push updates from a development machine.

Contributions, bug reports, and hardware notes are welcome. Open an issue or submit a pull request if you discover gaps in the docs or want to share improvements.
