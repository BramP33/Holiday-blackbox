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

PY_VENV="$DIR/.venv/bin/python"
PY_CMD=""
if [ -x "$PY_VENV" ]; then
  PY_CMD="$PY_VENV"
  echo "Updating Python dependencies in venv..."
  "$PY_CMD" -m pip install -r "$DIR/requirements.txt"
else
  if command -v python3 >/dev/null 2>&1; then
    PY_CMD=$(command -v python3)
    echo "No venv detected; installing with $PY_CMD (may require --break-system-packages)"
    "$PY_CMD" -m pip install -r "$DIR/requirements.txt" || true
  else
    echo "python3 not found; skipping dependency install and transcript reindex."
  fi
fi

if [ -n "$PY_CMD" ]; then
  echo "Requeueing transcripts for current Whisper model..."
  if ! (cd "$DIR" && "$PY_CMD" -m Software.scripts.reindex_transcripts); then
    echo "Warning: transcript requeue failed; run '$PY_CMD -m Software.scripts.reindex_transcripts' manually." >&2
  fi
fi

echo "Restarting services..."
sudo systemctl restart blackbox-web || true
sudo systemctl restart blackbox || true

echo "Update complete."
