#!/usr/bin/env bash
set -euo pipefail

# Simple deploy script to sync this repo to the Pi and restart services.
# Usage: ./deploy.sh [user@host] [remote_dir]
# Defaults: user@host=blackbox@blackbox.local, remote_dir=~/Holiday-blackbox

DEST_HOST="${1:-blackbox@blackbox.local}"
DEST_DIR="${2:-~/Holiday-blackbox}"

echo "[deploy] Syncing to ${DEST_HOST}:${DEST_DIR}"
rsync -azvh --delete \
  --exclude='.git/' \
  --exclude='Software/.venv/' \
  --exclude='**/__pycache__/' \
  --exclude='*.pyc' \
  --exclude='**/run_output*/' \
  ./ "${DEST_HOST}:${DEST_DIR}/"

echo "[deploy] Ensuring scripts are executable and restarting services..."
ssh "${DEST_HOST}" "bash -lc 'chmod +x ${DEST_DIR}/Software/scripts/*.sh || true; cd ${DEST_DIR}/Software && bash ./scripts/update.sh'"

echo "[deploy] Done."

