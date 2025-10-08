# Blackbox Flutter Touch UI

A Flutter-based touchscreen interface that mirrors the key flows from the e-paper interface and Flask web server. It targets the HyperPixel 4.0 display and runs locally on the Raspberry Pi alongside the existing backend.

## Features
- Dashboard with trip stats (videos, photos, free storage, device labels)
- Photo and video browsers backed by `/api/photos` and `/api/videos`
- Inline video playback through the existing `/preview/video` endpoint
- Backup status and triggers using the new `/api/backup/*` endpoints
- Quick navigation into the Flask web interface for advanced settings

## Requirements
- Flutter 3.16 or newer (Dart 3.1+) on the Raspberry Pi or a Linux workstation
- Raspberry Pi OS Lite (Bookworm) with the Flask backend (`blackbox-web`) running
- GStreamer packages for video playback on Linux: `sudo apt install gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav`
- MPV runtime libraries for the media_kit backend: `sudo apt install libmpv1 libmpv-dev`
- Fonts: the default Roboto shipped with Flutter is used; add extra fonts if desired

## Getting Started
```bash
cd Software/flutter_frontend
flutter pub get
flutter run --release --dart-define=BLACKBOX_BASE_URL=http://127.0.0.1:5000
```

The app reads the following compile-time environment variables (override with `--dart-define` or `Platform.environment` when running in debug):
- `BLACKBOX_BASE_URL` (default `http://127.0.0.1:5000`)
- `BLACKBOX_WS_URL` (reserved for future WebSocket streaming, default `ws://127.0.0.1:5000/ws/status`)

## Building for Deployment
On the Raspberry Pi:
```bash
flutter build linux --release
```
The bundle will be written to `build/linux/arm64/release/bundle/`. Copy that directory to `/opt/blackbox_flutter` (or similar) and start the binary `blackbox_flutter`.

## Autostart on Boot
Create a systemd service at `/etc/systemd/system/blackbox-flutter.service`:
```ini
[Unit]
Description=Blackbox Flutter UI
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/opt/blackbox_flutter
Environment=BLACKBOX_BASE_URL=http://127.0.0.1:5000
ExecStart=/opt/blackbox_flutter/blackbox_flutter
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
Then enable it:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now blackbox-flutter.service
```

For kiosk-style deployment, pair this with an X11/Wayland session that auto-starts the binary (e.g. `weston --shell=fullscreen-shell.so`).

## Backend Integration
The Flutter UI consumes these endpoints provided by `Software/blackbox/web/app.py`:
- `GET /api/stats` — Trip overview from `collect_trip_media_stats`
- `GET /api/photos` — Paged list of photo paths
- `GET /api/videos` — Paged video metadata + thumbnails and transcripts
- `POST /api/backup/start` / `GET /api/backup/status` / `POST /api/backup/cancel` — Manual backup control
- `GET /preview/photo`, `GET /preview/video`, `GET /preview/video_thumb`, `GET /download`

Ensure the Flask app is running (via `blackbox-web.service`) before launching the Flutter UI.

## Notes
- Cancellation is not yet implemented server-side; the UI hides the button until that lands.
- Video playback relies on the system GStreamer + MPV stack. If playback is blank, confirm both the GStreamer plugins and `libmpv` packages above are installed.
- The UI defaults to landscape orientation; remove or adjust the orientation pin in `lib/main.dart` if you mount the display differently.
