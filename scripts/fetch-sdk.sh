#!/usr/bin/env bash
set -euo pipefail

# Fetch a macOS Player One Camera SDK dylib for local development.
# Official packages: https://www.player-one-astronomy.com/service/software/
# This script uses the copy redistributed with INDI as a convenience fallback.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/PlayerOne/libPlayerOneCamera.dylib"
mkdir -p "$ROOT/Vendor/PlayerOne"

if [[ -f "$DEST" ]]; then
  echo "Already present: $DEST"
  file "$DEST"
  exit 0
fi

URL="${PLAYERONE_SDK_URL:-https://raw.githubusercontent.com/indilib/indi-3rdparty/master/libplayerone/mac/libPlayerOneCamera.bin}"
echo "Downloading $URL"
curl -fL "$URL" -o "$DEST"
file "$DEST"
echo "Installed $DEST"
