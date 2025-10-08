#!/usr/bin/env bash
set -euo pipefail

# Resolve repo dir (Software/)
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Friendly re-exec if run with sudo (avoid root-owned venv)
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    echo "Detected sudo. Re-running as ${SUDO_USER} to avoid root-owned venv..."
    exec sudo -u "${SUDO_USER}" -H bash "$0" "$@"
  else
    echo "Please run this script as a normal user (not root)." >&2
    exit 1
  fi
fi

echo "Creating Python virtual environment (to avoid 'externally-managed-environment')..."
# If a leftover root-owned venv exists from earlier sudo runs, fix ownership
if [ -d "$DIR/.venv" ] && [ ! -w "$DIR/.venv" ]; then
  echo "Fixing ownership of existing .venv (needs sudo)..."
  sudo chown -R "$(id -un)":"$(id -gn)" "$DIR/.venv" || true
fi

if [ ! -d "$DIR/.venv" ]; then
  if ! python3 -m venv --system-site-packages "$DIR/.venv" 2>/dev/null; then
    echo "python3-venv not available — attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y python3-venv
    else
      echo "Cannot auto-install python3-venv (apt-get not found). Install it and re-run." >&2
      exit 1
    fi
    # Try again
    python3 -m venv --system-site-packages "$DIR/.venv"
  fi
fi

PY="$DIR/.venv/bin/python"
PIP="$DIR/.venv/bin/pip"

# If venv looks broken (python missing), rebuild it
if [ ! -x "$PY" ]; then
  echo "Venv seems incomplete; recreating..."
  rm -rf "$DIR/.venv"
  if ! python3 -m venv --system-site-packages "$DIR/.venv" 2>/dev/null; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y python3-venv
    fi
    python3 -m venv --system-site-packages "$DIR/.venv"
  fi
  PY="$DIR/.venv/bin/python"
  PIP="$DIR/.venv/bin/pip"
fi

# Ensure pip exists in the venv (some distros omit it initially)
if [ ! -x "$PIP" ]; then
  echo "Bootstrapping pip in venv..."
  "$PY" -m ensurepip --upgrade || true
fi

# Ensure venv exposes system site-packages (for apt Python modules like spidev/RPi.GPIO)
if [ -f "$DIR/.venv/pyvenv.cfg" ]; then
  if ! grep -q "^include-system-site-packages *= *true" "$DIR/.venv/pyvenv.cfg"; then
    echo "Recreating venv with --system-site-packages so apt modules are visible..."
    rm -rf "$DIR/.venv"
    python3 -m venv --system-site-packages "$DIR/.venv"
    PY="$DIR/.venv/bin/python"
    PIP="$DIR/.venv/bin/pip"
    "$PY" -m ensurepip --upgrade || true
  fi
fi

echo "Upgrading pip/setuptools in venv..."
"$PY" -m pip install --upgrade pip setuptools wheel

echo "Installing Python deps into venv (forcing PyPI for fresh certs)..."
"$PY" -m pip install --index-url https://pypi.org/simple -r "$DIR/requirements.txt"

# Make sure OS-level dependencies for hardware are present
if command -v apt-get >/dev/null 2>&1; then
  echo "Ensuring OS packages (GPIO/SPI/fonts/ffmpeg/mDNS/GUI) are installed..."
  sudo apt-get update -y
  sudo apt-get install -y \
    python3-rpi-lgpio \
    python3-lgpio \
    python3-spidev \
    python3-pil \
    ffmpeg \
    fonts-dejavu \
    avahi-daemon \
    onboard \
    git \
    device-tree-compiler \
    xserver-xorg \
    xinit \
    openbox \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-libav \
    libgstreamer1.0-dev \
    libgtk-3-0 \
    libgtk-3-dev \
    libstdc++6 \
    liblzma5 \
    liblzma-dev \
    libglu1-mesa \
    libmpv1 \
    libmpv-dev \
    weston \
    xwayland \
    cmake \
    ninja-build \
    pkg-config \
    clang \
    bluez \
    bluez-tools || true
  # NetworkManager for AP-mode (optional)
  sudo apt-get install -y network-manager || true
fi

# HyperPixel configuration is now done separately - not in this script

configure_x11_launcher() {
  local USERNAME
  USERNAME="$(id -un)"
  local HOME_DIR
  HOME_DIR="$(eval echo "~$USERNAME")"
  local GROUP_NAME
  GROUP_NAME="$(id -gn "$USERNAME")"
  local SERVICE_PATH="/etc/systemd/system/blackbox-flutter.service"
  local FLUTTER_BIN="/opt/blackbox_flutter/blackbox_flutter"
  local XINITRC="$HOME_DIR/.xinitrc"

  if [ ! -f "$XINITRC" ]; then
    cat <<'EOF' > "$XINITRC"
#!/bin/sh
export BLACKBOX_BASE_URL=http://127.0.0.1:5000
xset -dpms
xset s off
exec /opt/blackbox_flutter/blackbox_flutter --window-decorator=false --fullscreen
EOF
    chmod +x "$XINITRC"
    echo "Created $XINITRC"
  else
    echo "$XINITRC already exists; leaving as-is."
  fi

  if [ ! -f "$SERVICE_PATH" ]; then
    sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Blackbox Flutter UI (X11)
After=systemd-user-sessions.service
Requires=systemd-user-sessions.service

[Service]
User=$USERNAME
Group=$GROUP_NAME
PAMName=login
Environment=DISPLAY=:0
Environment=BLACKBOX_BASE_URL=http://127.0.0.1:5000
WorkingDirectory=$HOME_DIR
ExecStartPre=/usr/bin/test -x $FLUTTER_BIN
ExecStart=/usr/bin/startx $XINITRC -- -nocursor -keeptty
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
  else
    echo "blackbox-flutter.service already exists; leaving as-is."
  fi

  if [ ! -x "$FLUTTER_BIN" ]; then
    echo "NOTE: $FLUTTER_BIN not found yet; deploy the Flutter bundle there before boot." >&2
  fi

  if ! systemctl is-enabled --quiet blackbox-flutter.service 2>/dev/null; then
    sudo systemctl enable blackbox-flutter.service || true
  fi
  sudo systemctl restart blackbox-flutter.service || true
}

echo "Configuring X11 + Flutter autostart..."
configure_x11_launcher

# Try to install Waveshare e‑paper library into the venv if missing
echo "Checking Waveshare e-paper Python lib..."
if ! "$PY" - <<'PY'
try:
    from waveshare_epd import epd2in7_V2  # noqa: F401
    import sys
    sys.exit(0)
except Exception:
    import sys
    sys.exit(1)
PY
then
  echo "waveshare_epd not found in Python path; attempting to install it..."
  VENV_SITE=$("$PY" - <<'PY'
import sysconfig
print(sysconfig.get_paths()["purelib"])
PY
)
  if [ -d "$HOME/e-Paper/RaspberryPi_JetsonNano/python/lib/waveshare_epd" ]; then
    echo "Copying waveshare_epd from ~/e-Paper into venv site-packages..."
    cp -r "$HOME/e-Paper/RaspberryPi_JetsonNano/python/lib/waveshare_epd" "$VENV_SITE"/
  else
    if command -v git >/dev/null 2>&1; then
      echo "Cloning Waveshare e-Paper repo..."
      git -C "$HOME" clone https://github.com/waveshareteam/e-Paper.git || true
      if [ -d "$HOME/e-Paper/RaspberryPi_JetsonNano/python/lib/waveshare_epd" ]; then
        echo "Copying waveshare_epd into venv site-packages..."
        cp -r "$HOME/e-Paper/RaspberryPi_JetsonNano/python/lib/waveshare_epd" "$VENV_SITE"/
      fi
    fi
  fi
  # Verify again
  if ! "$PY" - <<'PY'
try:
    from waveshare_epd import epd2in7_V2  # noqa: F401
    import spidev  # noqa: F401
    import RPi.GPIO as GPIO  # noqa: F401
    import sys
    sys.exit(0)
except Exception:
    import sys
    sys.exit(1)
PY
  then
    echo "WARNING: waveshare_epd and/or spidev/RPi.GPIO still not importable in venv."
    echo " - Ensure SPI is enabled (raspi-config) and /dev/spidev0.* exists."
    echo " - Ensure 'python3-spidev' and 'python3-rpi-lgpio' are installed."
    echo " - Venv must include system site-packages (we attempted to recreate it)."
  else
    echo "waveshare_epd detected."
  fi
fi

# Group membership for SPI/GPIO access
ME="$(id -un)"
if id -nG "$ME" | grep -vqE '\bspi\b'; then
  echo "Adding $ME to 'spi' group (needs sudo)..."
  sudo usermod -aG spi "$ME" || true
fi
if id -nG "$ME" | grep -vqE '\bgpio\b'; then
  echo "Adding $ME to 'gpio' group (needs sudo)..."
  sudo usermod -aG gpio "$ME" || true
fi
if id -nG "$ME" | grep -vqE '\bfuse\b'; then
  echo "Adding $ME to 'fuse' group (needs sudo)..."
  sudo usermod -aG fuse "$ME" || true
fi
if id -nG "$ME" | grep -vqE '\bvideo\b'; then
  echo "Adding $ME to 'video' group (needs sudo)..."
  sudo usermod -aG video "$ME" || true
fi
if id -nG "$ME" | grep -vqE '\binput\b'; then
  echo "Adding $ME to 'input' group (needs sudo)..."
  sudo usermod -aG input "$ME" || true
fi
if [ ! -e /dev/spidev0.0 ] && [ ! -e /dev/spidev0.1 ]; then
  echo "WARNING: /dev/spidev0.* not found. Enable SPI via 'sudo raspi-config' (Interface Options → SPI)."
fi

echo "Ensuring /mnt/nvme exists..."
sudo mkdir -p /mnt/nvme
if mountpoint -q /mnt/nvme; then
  echo "/mnt/nvme is a mountpoint."
else
  echo "WARNING: /mnt/nvme is not mounted. Create an fstab entry to mount your NVMe here for best performance."
fi

echo "Copying systemd units..."
# Replace WorkingDirectory and ExecStart with the absolute repo path and venv python
SED_PATH="$DIR"
VENVPY="$DIR/.venv/bin/python"
sed -e "s|%h/Holiday-blackbox/Software|$SED_PATH|g" \
    -e "s|^ExecStart=.*blackbox.main|ExecStart=$VENVPY -m blackbox.main|" \
    "$DIR/systemd/blackbox.service" | sudo tee /etc/systemd/system/blackbox.service >/dev/null
sed -e "s|%h/Holiday-blackbox/Software|$SED_PATH|g" \
    -e "s|^ExecStart=.*blackbox.web.app|ExecStart=$VENVPY -m blackbox.web.app|" \
    "$DIR/systemd/blackbox-web.service" | sudo tee /etc/systemd/system/blackbox-web.service >/dev/null
sed -e "s|%h/Holiday-blackbox/Software|$SED_PATH|g" \
    -e "s|^ExecStart=.*blackbox.poweroff|ExecStart=$VENVPY -m blackbox.poweroff|" \
    "$DIR/systemd/blackbox-poweroff.service" | sudo tee /etc/systemd/system/blackbox-poweroff.service >/dev/null
sudo systemctl daemon-reload
echo "Enable with: sudo systemctl enable --now blackbox.service blackbox-web.service"
echo "Also enable the shutdown screen: sudo systemctl enable blackbox-poweroff.service"
