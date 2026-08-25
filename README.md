# Collimation Camera

macOS app for collimating a telescope against an artificial star with a Player One camera (Poseidon-M and other SDK cameras). It shows a GPU-stretched live view, keeps a star-centered ROI, and measures coma from a defocused donut.

## Features

- Live view with Metal stretch (16-bit texture, black/white/gamma on the GPU)
- ROI sizes 128 / 256 / 512 / 1024 / full, plus display zoom (25%–800%, pinch/scroll)
- Auto-center the ROI on the star; full-frame binned search if it leaves the ROI
- Manual and auto stretch (histogram percentiles)
- Numeric coma: concentricity of the outer ring vs. the secondary shadow, plus sector asymmetry
- Simulator camera so you can develop and test without hardware

## Requirements

- macOS 13 or later (universal: Apple Silicon and Intel)
- Swift 6 toolchain (`xcode-select` command line tools or Xcode)
- Optional: [Player One Camera SDK](https://www.player-one-astronomy.com/service/software/) for a real camera

## Build and run

```bash
# Simulator live view
swift run CollimationApp

# Unit tests (synthetic donuts with known coma)
swift run core-tests

# Grab one frame
swift run capture-cli --list
swift run capture-cli --simulator --output frame.png
```

Package a `.app` bundle (ad-hoc signed):

```bash
scripts/package-app.sh
open "dist/Collimation Camera.app"
```

## Player One SDK

The C library is loaded at runtime from, in order:

1. `Collimation Camera.app/Contents/Frameworks/libPlayerOneCamera.dylib`
2. `Vendor/PlayerOne/libPlayerOneCamera.dylib` (from the repo working directory)
3. `/usr/local/lib/libPlayerOneCamera.dylib`

```bash
scripts/fetch-sdk.sh
```

Without the dylib, only the simulator appears in the device list. Plug in a Poseidon-M, click Refresh, then Connect. macOS may prompt for USB/camera access on first use.

## Using it at the telescope

1. Point at the artificial star and defocus until the secondary shadow is a clear hole.
2. Connect the camera (or simulator), set exposure/gain so the donut is not clipped.
3. Click **Auto stretch**, then enable **Auto-center star**.
4. Read **Coma** (normalized fraction of the annulus width) and **Direction** (0° = right, 90° = down on the image).
5. Adjust the collimation screws to drive the normalized coma toward zero. The overlay arrow and the dial match that direction.

If the star leaves the ROI, the app switches to a binned full-frame search and recenters automatically.

## Layout

```
Sources/CollimationCore   capture, stretch, tracking, coma analysis (no UI)
Sources/CollimationApp    SwiftUI window + Metal live view
Sources/CaptureCLI        one-shot frame grab
Sources/POACameraC        Player One C types (functions via dlopen)
Tests/CollimationCoreTests
```

See `PLAN.md` for the original design.
