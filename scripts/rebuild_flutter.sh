#!/bin/bash

# Rebuild the Flutter desktop bundle used by Holiday Blackbox.
# Run this from anywhere; it resolves paths relative to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLUTTER_DIR="${PROJECT_ROOT}/Software/flutter_frontend"

# Flutter uses different paths depending on architecture
# Try arm64 first (explicit), then fall back to generic linux path
BUILD_DIR_ARM64="${FLUTTER_DIR}/build/linux/arm64/release/bundle"
BUILD_DIR_GENERIC="${FLUTTER_DIR}/build/linux/release/bundle"

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

echo "[Rebuild] Building release bundle for Linux..."
flutter build linux --release

popd >/dev/null

# Determine which build directory was actually created
if [ -d "${BUILD_DIR_ARM64}" ]; then
  BUILD_DIR="${BUILD_DIR_ARM64}"
  echo "[Rebuild] Found ARM64-specific build at ${BUILD_DIR}"
elif [ -d "${BUILD_DIR_GENERIC}" ]; then
  BUILD_DIR="${BUILD_DIR_GENERIC}"
  echo "[Rebuild] Found generic Linux build at ${BUILD_DIR}"
else
  echo "[Rebuild] ERROR: build output not found at either:" >&2
  echo "          ${BUILD_DIR_ARM64}" >&2
  echo "          ${BUILD_DIR_GENERIC}" >&2
  exit 1
fi

echo "[Rebuild] Build completed. Bundle available at:"
echo "          ${BUILD_DIR}"
echo "[Rebuild] Done."
