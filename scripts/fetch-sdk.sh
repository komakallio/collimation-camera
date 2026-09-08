#!/usr/bin/env bash
set -euo pipefail

# Fetch the macOS camera and filter-wheel SDK libraries the app loads at run
# time. Official packages:
#   Player One  https://www.player-one-astronomy.com/service/software/
#   ZWO ASI     https://www.zwoastro.com/software/product-sdk/
# This script uses the copies redistributed with INDI as a convenience.
#
# The ZWO arm64 slice is built with a macOS 15 minimum and links libusb, which
# the vendor does not bundle, so libusb is fetched and the install names are
# rewritten to load it from next to the dylib.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/Vendor/PlayerOne" "$ROOT/Vendor/ZWO"

fetch_binary() {
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
ASI_X86_URL="${ZWO_SDK_X86_URL:-https://raw.githubusercontent.com/indilib/indi-3rdparty/master/libasi/mac/libASICamera2.bin}"
ASI_ARM64_URL="${ZWO_SDK_ARM64_URL:-https://raw.githubusercontent.com/indilib/indi-3rdparty/master/libasi/mac_arm64/libASICamera2.bin}"

fetch_binary "$ROOT/Vendor/PlayerOne/libPlayerOneCamera.dylib" "$CAMERA_URL"
fetch_binary "$ROOT/Vendor/PlayerOne/libPlayerOnePW.dylib" "$PW_URL"

ASI="$ROOT/Vendor/ZWO/libASICamera2.dylib"
if [[ ! -f "$ASI" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  fetch_binary "$TMP/libASICamera2-x86_64.dylib" "$ASI_X86_URL"
  fetch_binary "$TMP/libASICamera2-arm64.dylib" "$ASI_ARM64_URL"
  lipo -create "$TMP/libASICamera2-x86_64.dylib" "$TMP/libASICamera2-arm64.dylib" -output "$ASI"
  file "$ASI"
fi

# Both vendors link libusb. Put one copy next to the dylibs and point every
# reference at it, then re-sign: Apple silicon rejects a modified dylib whose
# signature no longer matches.
LIBUSB="$ROOT/Vendor/ZWO/libusb-1.0.0.dylib"
if [[ ! -f "$LIBUSB" ]]; then
  for candidate in \
    /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib \
    /usr/local/opt/libusb/lib/libusb-1.0.0.dylib
  do
    if [[ -f "$candidate" ]]; then
      cp "$candidate" "$LIBUSB"
      break
    fi
  done
fi
if [[ ! -f "$LIBUSB" ]]; then
  echo "libusb not found. Install it with: brew install libusb"
  echo "Then re-run this script."
  exit 1
fi

install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$LIBUSB" 2>/dev/null || true
for dylib in "$ASI" "$ROOT/Vendor/PlayerOne/libPlayerOneCamera.dylib"; do
  [[ -f "$dylib" ]] || continue
  install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib" 2>/dev/null || true
  while read -r reference; do
    case "$reference" in
      *libusb-1.0.0.dylib)
        install_name_tool -change "$reference" "@loader_path/libusb-1.0.0.dylib" "$dylib" 2>/dev/null || true
        ;;
    esac
  done < <(otool -L "$dylib" | awk 'NR > 1 { print $1 }')
  codesign --force --sign - "$dylib" 2>/dev/null || true
done
codesign --force --sign - "$LIBUSB" 2>/dev/null || true

cp "$LIBUSB" "$ROOT/Vendor/PlayerOne/libusb-1.0.0.dylib"
echo "Vendor libraries are in $ROOT/Vendor."
