#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Collimation Camera"
DIST="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"
swift build -c release --product CollimationApp

BIN="$(swift build -c release --show-bin-path)/CollimationApp"
rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Frameworks" "$DIST/Contents/Resources"

cat > "$DIST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Collimation Camera</string>
  <key>CFBundleIdentifier</key><string>local.collimation-camera</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>CollimationApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "$BIN" "$DIST/Contents/MacOS/CollimationApp"
chmod +x "$DIST/Contents/MacOS/CollimationApp"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$DIST/Contents/Resources/AppIcon.icns"
fi

# Vendor libraries are loaded at run time from Contents/Frameworks. One copy of
# libusb serves both vendors.
copied_vendor_library=0
for lib in \
  "$ROOT/Vendor/PlayerOne/libPlayerOneCamera.dylib" \
  "$ROOT/Vendor/PlayerOne/libPlayerOnePW.dylib" \
  "$ROOT/Vendor/ZWO/libASICamera2.dylib" \
  "$ROOT/Vendor/ZWO/libusb-1.0.0.dylib"
do
  if [[ -f "$lib" ]]; then
    cp "$lib" "$DIST/Contents/Frameworks/"
    copied_vendor_library=1
  fi
done
if [[ $copied_vendor_library -eq 1 ]]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$DIST/Contents/MacOS/CollimationApp" 2>/dev/null || true
fi

codesign --force --deep --sign - "$DIST" 2>/dev/null || true
echo "Built $DIST"
