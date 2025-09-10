#!/usr/bin/env bash
set -euo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

echo "Installing Python deps..."
python3 -m pip install -r "$DIR/requirements.txt"

echo "Ensuring /mnt/nvme exists..."
sudo mkdir -p /mnt/nvme
if mountpoint -q /mnt/nvme; then
  echo "/mnt/nvme is a mountpoint."
else
  echo "WARNING: /mnt/nvme is not mounted. Create an fstab entry to mount your NVMe here for best performance."
fi

echo "Copying systemd units..."
# Replace WorkingDirectory placeholder with the absolute repo path
SED_PATH="$DIR"
sed "s|%h/Holiday-blackbox/Software|$SED_PATH|g" "$DIR/systemd/blackbox.service" | sudo tee /etc/systemd/system/blackbox.service >/dev/null
sed "s|%h/Holiday-blackbox/Software|$SED_PATH|g" "$DIR/systemd/blackbox-web.service" | sudo tee /etc/systemd/system/blackbox-web.service >/dev/null
sudo systemctl daemon-reload
echo "Enable with: sudo systemctl enable --now blackbox.service blackbox-web.service"
