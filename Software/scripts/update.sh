#!/usr/bin/env bash
set -euo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

echo "Updating Holiday Blackbox in $DIR"
if [ -d "$DIR/.git" ]; then
  echo "Pulling latest changes..."
  git -C "$DIR" fetch --all --prune
  git -C "$DIR" pull --ff-only || true
else
  echo "No git repo detected; skipping git pull."
fi

PY="$DIR/.venv/bin/python"
if [ -x "$PY" ]; then
  echo "Updating Python dependencies in venv..."
  "$PY" -m pip install -r "$DIR/requirements.txt"
else
  echo "No venv detected; installing with system python (may require --break-system-packages)"
  python3 -m pip install -r "$DIR/requirements.txt" || true
fi

echo "Restarting services..."
sudo systemctl restart blackbox-web || true
sudo systemctl restart blackbox || true

echo "Update complete."
