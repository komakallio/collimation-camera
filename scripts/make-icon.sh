#!/usr/bin/env bash
set -euo pipefail

# Rebuild Resources/AppIcon.icns from the 1024 master PNG.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon-1024.png"
SET="$ROOT/Resources/AppIcon.iconset"
DEST="$ROOT/Resources/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
  echo "Missing $SRC" >&2
  exit 1
fi

rm -rf "$SET"
mkdir -p "$SET"

sips -z 16 16 "$SRC" --out "$SET/icon_16x16.png" >/dev/null
sips -z 32 32 "$SRC" --out "$SET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SRC" --out "$SET/icon_32x32.png" >/dev/null
sips -z 64 64 "$SRC" --out "$SET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SRC" --out "$SET/icon_128x128.png" >/dev/null
sips -z 256 256 "$SRC" --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC" --out "$SET/icon_256x256.png" >/dev/null
sips -z 512 512 "$SRC" --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC" --out "$SET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC" --out "$SET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$SET" -o "$DEST"
rm -rf "$SET"
echo "Wrote $DEST"
