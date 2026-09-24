#!/usr/bin/env bash
set -euo pipefail

# Bundles the portable app for macOS as "Collimation Camera (portable).app".
#
# This is a development and parity build, not the macOS release — that is
# package-app.sh, which bundles the SwiftUI app. Two things make the bundle
# worth building anyway: an unbundled `swift run` gets no Retina backing store
# and no Dock icon, and the bundle is what a side-by-side HUD comparison
# against the SwiftUI app needs (§9.8).
#
# The bundle carries its own SDL3, so it runs on a Mac without Homebrew.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Collimation Camera (portable)"
DIST="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"
swift build -c release --product CollimationCamera

BIN="$(swift build -c release --show-bin-path)/CollimationCamera"
if [[ ! -f "$BIN" ]]; then
  echo "No such executable: $BIN" >&2
  exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Frameworks" "$DIST/Contents/Resources"

# CFBundleIdentifier differs from the SwiftUI app's on purpose: the two keep
# separate UserDefaults domains, which PARITY.md records as deliberate.
cat > "$DIST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Collimation Camera (portable)</string>
  <key>CFBundleIdentifier</key><string>local.collimation-camera.portable</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>CollimationCamera</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "$BIN" "$DIST/Contents/MacOS/CollimationCamera"
chmod +x "$DIST/Contents/MacOS/CollimationCamera"

# AppPaths looks beside the executable first, then one directory up, which is
# Contents/ in a bundle — hence Contents/Resources.
cp -R "$ROOT/Resources/Fonts" "$DIST/Contents/Resources/"
cp "$ROOT/Resources/AppIcon-256.png" "$DIST/Contents/Resources/"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$DIST/Contents/Resources/AppIcon.icns"
fi
cp -R "$ROOT/LICENSES" "$DIST/Contents/Resources/LICENSES"

install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$DIST/Contents/MacOS/CollimationCamera" 2>/dev/null || true

# --- SDL3 -------------------------------------------------------------------
# The executable links Homebrew's dylib by absolute path. Copy it in, give it
# an @rpath install name, and repoint the executable at that.
SDL_PATH="$(otool -L "$DIST/Contents/MacOS/CollimationCamera" | awk '/libSDL3/ {print $1; exit}')"
if [[ -n "${SDL_PATH:-}" ]]; then
  SDL_NAME="$(basename "$SDL_PATH")"
  if [[ -f "$SDL_PATH" ]]; then
    cp "$SDL_PATH" "$DIST/Contents/Frameworks/$SDL_NAME"
    chmod u+w "$DIST/Contents/Frameworks/$SDL_NAME"
    install_name_tool -id "@rpath/$SDL_NAME" "$DIST/Contents/Frameworks/$SDL_NAME"
    install_name_tool -change "$SDL_PATH" "@rpath/$SDL_NAME" \
      "$DIST/Contents/MacOS/CollimationCamera"
    echo "Bundled $SDL_NAME"
  else
    echo "warning: $SDL_PATH is not on this machine; the bundle needs Homebrew's sdl3" >&2
  fi
else
  echo "warning: the executable does not reference libSDL3; check the link" >&2
fi

# --- Vendor libraries -------------------------------------------------------
# Loaded by name at run time from Contents/Frameworks. One copy of libusb
# serves both vendors; its license applies to the macOS packages only.
for lib in \
  "$ROOT/Vendor/PlayerOne/libPlayerOneCamera.dylib" \
  "$ROOT/Vendor/PlayerOne/libPlayerOnePW.dylib" \
  "$ROOT/Vendor/ZWO/libASICamera2.dylib" \
  "$ROOT/Vendor/ZWO/libusb-1.0.0.dylib"
do
  if [[ -f "$lib" ]]; then
    cp "$lib" "$DIST/Contents/Frameworks/"
  else
    echo "not bundled: $(basename "$lib") (run scripts/fetch-sdk.sh)" >&2
  fi
done

# Ad-hoc signature, so Gatekeeper reports an unsigned app rather than a broken
# one. The README explains "Open Anyway" and the quarantine attribute.
codesign --force --deep --sign - "$DIST" 2>/dev/null || true

echo "Built $DIST"
