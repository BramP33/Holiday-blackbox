#!/usr/bin/env bash
set -euo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

echo "Creating Python virtual environment (to avoid 'externally-managed-environment')..."
if [ ! -d "$DIR/.venv" ]; then
  python3 -m venv --system-site-packages "$DIR/.venv"
fi

PY="$DIR/.venv/bin/python"
PIP="$DIR/.venv/bin/pip"

echo "Upgrading pip/setuptools in venv..."
"$PY" -m pip install --upgrade pip setuptools wheel

echo "Installing Python deps into venv..."
"$PY" -m pip install -r "$DIR/requirements.txt"

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
sudo systemctl daemon-reload
echo "Enable with: sudo systemctl enable --now blackbox.service blackbox-web.service"
