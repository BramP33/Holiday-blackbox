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

# Try to find flutter if not in PATH
if ! command -v flutter >/dev/null 2>&1; then
  echo "[Rebuild] Flutter not found in PATH, searching common locations..."
  
  # Common Flutter installation locations
  FLUTTER_LOCATIONS=(
    "$HOME/flutter/bin/flutter"
    "$HOME/snap/flutter/common/flutter/bin/flutter"
    "/opt/flutter/bin/flutter"
    "$HOME/development/flutter/bin/flutter"
    "$HOME/.flutter/bin/flutter"
  )
  
  FLUTTER_CMD=""
  for location in "${FLUTTER_LOCATIONS[@]}"; do
    if [ -f "$location" ]; then
      FLUTTER_CMD="$location"
      echo "[Rebuild] Found Flutter at: $FLUTTER_CMD"
      break
    fi
  done
  
  if [ -z "$FLUTTER_CMD" ]; then
    echo "[Rebuild] ERROR: 'flutter' command not found." >&2
    echo "[Rebuild] Please run: ${SCRIPT_DIR}/setup_flutter_path.sh" >&2
    exit 1
  fi
else
  FLUTTER_CMD="flutter"
fi

pushd "${FLUTTER_DIR}" >/dev/null
echo "[Rebuild] Cleaning previous build artifacts..."
"$FLUTTER_CMD" clean

echo "[Rebuild] Running 'flutter pub get'..."
"$FLUTTER_CMD" pub get

echo "[Rebuild] Building release bundle for Linux..."
"$FLUTTER_CMD" build linux --release

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
