# Collimation Camera

macOS app for collimating a telescope against an artificial star with a Player One or ZWO camera. It shows a GPU-stretched live view, keeps a star-centered ROI, and measures coma from a defocused donut.

The shared core, the frame grabber, and the tests also build and run on Windows. The Windows UI is not here yet; see `PLAN-MULTIPLATFORM.md` for the milestones.

## Features

- Live view with Metal stretch (16-bit texture, black/white/midtones MTF on the GPU)
- ROI sizes 256 / 512 / 1024 / 2048 / full, plus display zoom (25%–800%, pinch/scroll)
- Auto-center the ROI on the star; full-frame binned search if it leaves the ROI
- Manual and auto stretch (histogram percentiles)
- Numeric coma: concentricity of the outer ring vs. the secondary shadow, plus sector asymmetry
- Simulator camera so you can develop and test without hardware
- Player One and ZWO cameras through one device list, both loaded at run time
- Player One Phoenix filter wheel: connect, read on-wheel aliases, and move to a slot

## Requirements

### macOS

- macOS 14 or later (universal: Apple Silicon and Intel). ZWO cameras on Apple silicon need macOS 15, because the vendor's arm64 library is built with that minimum.
- Swift 6 toolchain (`xcode-select` command line tools or Xcode)
- Optional: [Player One Camera SDK](https://www.player-one-astronomy.com/service/software/) for a Player One camera
- Optional: [Player One Filter Wheel SDK](https://www.player-one-astronomy.com/service/software/) for a Phoenix filter wheel (PW5 / PW7 / PW8)
- Optional: [ZWO ASI Camera SDK](https://www.zwoastro.com/software/product-sdk/) for a ZWO camera

### Windows

- Windows 10 22H2 or Windows 11, x64, on an NTFS volume
- Swift 6.3.3 (`winget install --id Swift.Toolchain -e --source winget`) and Visual Studio 2022 Build Tools with the MSVC v143 workload and a Windows 11 SDK
- The Player One and ZWO camera drivers, which are separate downloads from each vendor's software page
- `swift build --product core-tests` and `swift build --product capture-cli` are what build today

If `swift build` reports `could not find CLI tool 'link'`, SwiftPM did not find MSVC's `link.exe`. Run from the x64 Native Tools prompt, or pass `-Xswiftc -use-ld=lld`.

Settings on Windows go to `%LOCALAPPDATA%\<executable name>.plist` and the guide calibration to `%LOCALAPPDATA%\Collimation Camera\guide-calibration.json`.

## Build and run

```bash
swift run CollimationApp
```

`swift run` starts an unbundled binary. The app still takes over the menu bar and Dock as **Collimation Camera**. For a normal Dock icon and Info.plist, package it:

```bash
scripts/package-app.sh
open "dist/Collimation Camera.app"
```

```bash
# Unit tests (synthetic donuts with known coma)
swift run core-tests

# Grab one frame as a 16-bit mono TIFF
swift run capture-cli --list
swift run capture-cli --simulator --output frame.tif
swift run capture-cli --device asi-0 --output zwo.tif
```

`make lint` checks that no shared module imports a UI or platform framework. CI runs the same check plus the tests on both platforms.

## Camera SDKs

The vendor libraries are loaded at run time, so the app links nothing and starts without them. They are looked for in this order:

1. Next to the executable, and `Collimation Camera.app/Contents/Frameworks/`
2. `Vendor/PlayerOne/` and `Vendor/ZWO/` under the working directory
3. The working directory, then the platform defaults

File names are `libPlayerOneCamera.dylib`, `libPlayerOnePW.dylib`, and `libASICamera2.dylib` on macOS; `PlayerOneCamera.dll`, `PlayerOnePW.dll`, and `ASICamera2.dll` on Windows.

```bash
scripts/fetch-sdk.sh          # macOS
```

```powershell
scripts\fetch-sdk.ps1         # Windows
```

Without a camera library, only the simulator appears in the device list. Plug in a camera, click Refresh, then Connect. macOS may prompt for USB/camera access on first use.

Without the filter-wheel library, the sidebar Filter wheel section stays disconnected. Plug in a Phoenix wheel, click Refresh, then Connect, and pick a slot. Aliases stored on the wheel (Ha, OIII, IR-cut, …) show next to the 1-based position.

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
Sources/CollimationCore/Platform   the only #if os() code in the core
Sources/CollimationApp    SwiftUI window + Metal live view (macOS)
Sources/CaptureCLI        one-shot frame grab
Sources/POACameraC        Player One C types (functions resolved at run time)
Sources/ASICameraC        ZWO C types (functions resolved at run time)
Sources/CoreTests         test runner
```

See `PLAN.md` for the original design and `PLAN-MULTIPLATFORM.md` for the multiplatform work.
