#!/usr/bin/env bash
set -euo pipefail

# Fetch macOS Player One Camera and Phoenix Filter Wheel SDK dylibs.
# Official packages: https://www.player-one-astronomy.com/service/software/
# This script uses the copies redistributed with INDI as a convenience fallback.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/Vendor/PlayerOne"

fetch_dylib() {
  local dest="$1"
  local url="$2"
  if [[ -f "$dest" ]]; then
    echo "Already present: $dest"
    file "$dest"
    return
  fi
  echo "Downloading $url"
  curl -fL "$url" -o "$dest"
  file "$dest"
  echo "Installed $dest"
}

CAMERA_URL="${PLAYERONE_SDK_URL:-https://raw.githubusercontent.com/indilib/indi-3rdparty/master/libplayerone/mac/libPlayerOneCamera.bin}"
PW_URL="${PLAYERONE_PW_SDK_URL:-https://raw.githubusercontent.com/indilib/indi-3rdparty/master/libplayerone/mac/libPlayerOnePW.bin}"

fetch_dylib "$ROOT/Vendor/PlayerOne/libPlayerOneCamera.dylib" "$CAMERA_URL"
fetch_dylib "$ROOT/Vendor/PlayerOne/libPlayerOnePW.dylib" "$PW_URL"
