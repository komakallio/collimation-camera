#!/usr/bin/env bash
set -euo pipefail

# Rebuilds every derived icon from the 1024 master PNG:
#
#   Resources/AppIcon.icns      macOS bundle icon
#   Resources/AppIcon-256.png   portable app window icon (SDL_SetWindowIcon)
#   Resources/AppIcon.ico       Windows PE resource icon
#
# Needs sips and iconutil, so it runs on macOS.

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
echo "Wrote $DEST"

# The window icon SDL loads at run time.
cp "$SET/icon_256x256.png" "$ROOT/Resources/AppIcon-256.png"
echo "Wrote $ROOT/Resources/AppIcon-256.png"

# The .ico, assembled by hand: an ICONDIR, one 16-byte ICONDIRENTRY per size,
# then the PNG blobs. PNG-compressed entries are the Vista-and-later form and
# every size is loaded by LoadImage (checked on Windows 11). A 256-pixel entry
# records its size as 0, which is what the format uses for 256.
ICO="$ROOT/Resources/AppIcon.ico"
SIZES=(16 32 48 64 128 256)
FILES=()
for size in "${SIZES[@]}"; do
  file="$SET/ico_$size.png"
  sips -z "$size" "$size" "$SRC" --out "$file" >/dev/null
  FILES+=("$file")
done

# printf a little-endian integer of a given width, in bytes.
le() {
  local value=$1 bytes=$2 i
  for ((i = 0; i < bytes; i++)); do
    printf "\x$(printf %02x $(( (value >> (8 * i)) & 0xFF )) )"
  done
}

{
  le 0 2                       # reserved
  le 1 2                       # type: icon
  le "${#SIZES[@]}" 2          # entry count
  offset=$((6 + 16 * ${#SIZES[@]}))
  for i in "${!SIZES[@]}"; do
    size=${SIZES[$i]}
    length=$(wc -c < "${FILES[$i]}")
    le $(( size >= 256 ? 0 : size )) 1
    le $(( size >= 256 ? 0 : size )) 1
    le 0 1                     # palette size: none
    le 0 1                     # reserved
    le 1 2                     # colour planes
    le 32 2                    # bits per pixel
    le "$length" 4
    le "$offset" 4
    offset=$((offset + length))
  done
  for file in "${FILES[@]}"; do
    cat "$file"
  done
} > "$ICO"
echo "Wrote $ICO"

rm -rf "$SET"
