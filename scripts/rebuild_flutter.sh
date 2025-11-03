#!/bin/bash

# Rebuild the Flutter desktop bundle used by Holiday Blackbox.
# Run this from anywhere; it resolves paths relative to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLUTTER_DIR="${PROJECT_ROOT}/Software/flutter_frontend"
BUILD_DIR="${FLUTTER_DIR}/build/linux/arm64/release/bundle"

echo "[Rebuild] Project root: ${PROJECT_ROOT}"
echo "[Rebuild] Flutter app dir: ${FLUTTER_DIR}"

if ! command -v flutter >/dev/null 2>&1; then
  echo "[Rebuild] ERROR: 'flutter' command not found. Install Flutter or add it to PATH." >&2
  exit 1
fi

pushd "${FLUTTER_DIR}" >/dev/null
echo "[Rebuild] Cleaning previous build artifacts..."
flutter clean

echo "[Rebuild] Running 'flutter pub get'..."
flutter pub get

echo "[Rebuild] Building release bundle for Linux (arm64)..."
flutter build linux --release

popd >/dev/null

if [ ! -d "${BUILD_DIR}" ]; then
  echo "[Rebuild] ERROR: build output not found at ${BUILD_DIR}" >&2
  exit 1
fi

echo "[Rebuild] Build completed. Bundle available at:"
echo "          ${BUILD_DIR}"
echo "[Rebuild] Done."
