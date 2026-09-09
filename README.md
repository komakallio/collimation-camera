# Collimation Camera

Collimate a telescope against an artificial star with a Player One or ZWO camera. The app shows a GPU-stretched live view, keeps a star-centered ROI, and measures coma from a defocused donut.

Two apps ship from this repository, on one shared core:

| | macOS | Windows |
|---|---|---|
| **CollimationApp** | SwiftUI and Metal. The macOS release. | — |
| **CollimationCamera** | SDL3 and Dear ImGui. A development and parity build. | SDL3 and Dear ImGui. The Windows release. |

They drive the same engine and take every label, shortcut, and HUD from the same modules, so they behave the same. `PARITY.md` has the feature table and the deliberate differences; `PLAN-MULTIPLATFORM.md` has the milestones.

## Features

- Live view with a GPU stretch (16-bit texture, black/white/midtones MTF on the GPU; Metal on macOS, SDL3 GPU on Windows)
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
- A GPU with Direct3D 12 feature level 11_0 (Intel Iris Xe and newer integrated graphics are enough)
- **To run a release build**: nothing else. The zip carries the Swift runtime, the Microsoft C++ runtime, SDL3, and the vendor SDKs.
- **To build**: Swift 6.3.3 (`winget install --id Swift.Toolchain -e --source winget`) and Visual Studio 2022 Build Tools with the MSVC v143 workload and a Windows 11 SDK, then `scripts\fetch-sdk.ps1` for SDL3 and the vendor SDKs
- The Player One and ZWO camera **drivers** are separate downloads from each vendor's software page. Install the driver first, then plug the camera in. The SDK DLLs this repository fetches are not drivers.

`scripts\build-win.ps1 <swift arguments>` runs a build with both MSVC and the Swift toolchain on `PATH`; `scripts\run-win.ps1 CollimationCamera` starts a development build with the Swift runtime staged beside it. Running `swift build` from an ordinary shell reports `could not find CLI tool 'link'` because SwiftPM cannot find MSVC's `link.exe`.

## Build and run

### macOS

```bash
swift run CollimationApp          # the SwiftUI app
brew install sdl3
swift run CollimationCamera       # the portable app, for parity checks
```

`swift run` starts an unbundled binary. The app still takes over the menu bar and Dock as **Collimation Camera**. For a normal Dock icon and Info.plist, package it:

```bash
scripts/package-app.sh
open "dist/Collimation Camera.app"
```

```bash
scripts/package-portable-mac.sh
open "dist/Collimation Camera (portable).app"
```

### Windows

```powershell
scripts\fetch-sdk.ps1
scripts\build-win.ps1 build --product CollimationCamera
scripts\run-win.ps1 CollimationCamera
```

A debug build keeps a console; a release build does not, and writes everything to its log file instead.

### Both

```bash
# Unit tests (synthetic donuts with known coma)
swift run core-tests

# Grab one frame as a 16-bit mono TIFF
swift run capture-cli --list
swift run capture-cli --simulator --output frame.tif
swift run capture-cli --device asi-0 --output zwo.tif
```

`make lint` checks that no shared module imports a UI or platform framework. CI runs the same check, the tests, and both apps' builds on both platforms.

## Packaging

```bash
scripts/package-app.sh              # dist/Collimation Camera.app
scripts/package-portable-mac.sh     # dist/Collimation Camera (portable).app
```

```powershell
scripts\package-win.ps1             # dist\CollimationCamera-win-x64\ and .zip
```

The Windows zip runs on a machine with no Swift toolchain: unzip it anywhere and start `CollimationCamera.exe`. The only prerequisite is the camera driver. Neither package is code-signed; see Troubleshooting.

## Where files go

| | macOS | Windows |
|---|---|---|
| Settings | `~/Library/Preferences/<bundle id>.plist` | `%LOCALAPPDATA%\<executable name>.plist` |
| Guide calibration | `~/Library/Application Support/Collimation Camera/guide-calibration.json` | `%LOCALAPPDATA%\Collimation Camera\guide-calibration.json` |
| Log file | standard output (SwiftUI app); `~/Library/Logs/Collimation Camera/collimation.log` (portable app) | `%LOCALAPPDATA%\Collimation Camera\collimation.log` |

The portable app keeps one generation of history beside the log, as `collimation.log.1`. The two macOS apps have separate settings domains on purpose, so a remembered port or folder is per app.

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

## Troubleshooting

**macOS refuses to open the app.** The bundles are ad-hoc signed, not notarized. Open **System Settings → Privacy & Security** and choose **Open Anyway**, or clear the quarantine attribute:

```bash
xattr -d com.apple.quarantine "dist/Collimation Camera.app"
```

**Windows SmartScreen blocks the download.** The zip is unsigned. Choose **More info**, then **Run anyway**.

**A camera is not in the list.** In order:

1. The vendor driver is installed, and the camera was plugged in after the driver.
2. No other application is holding the camera.
3. The SDK library is where the app looks (see Camera SDKs above). On Windows the release zip already contains it.
4. The log file names every path it tried and why each load failed. On Windows that is `%LOCALAPPDATA%\Collimation Camera\collimation.log`.

**The portable app closes immediately, or reports a failed step.** Every startup failure — SDL, the GPU device, the shader pipeline — shows a message box naming the step and the log path. Windows error 126 next to a DLL means the file is there but a dependency is not; installing the vendor driver usually supplies it.

## Third-party licenses

`LICENSES/README.md` lists every component that ships inside a package — SDL3, Dear ImGui, cimgui, the DejaVu fonts, the Player One and ZWO SDKs, libusb on macOS, and the Swift and Microsoft C++ runtimes on Windows — with the license text or a link to it. The packaging scripts copy the directory into each package.

## Layout

```
Sources/CollimationCore   capture, stretch, tracking, coma analysis (no UI)
Sources/CollimationCore/Platform   the only #if os() code in the core
Sources/CollimationUI     commands, formatters, HUD scenes; no UI framework
Sources/CollimationApp    SwiftUI window + Metal live view (macOS)
Sources/CollimationPortableApp   SDL3 + Dear ImGui window, live view, and HUD
Sources/CSDL3             SDL3 module map and the flag shim
Sources/CImGui            cimgui, the imgui subset, and the SDLGPU3 bridge
Sources/CaptureCLI        one-shot frame grab
Sources/POACameraC        Player One C types (functions resolved at run time)
Sources/ASICameraC        ZWO C types (functions resolved at run time)
Sources/CoreTests         test runner
```

See `PLAN.md` for the original design and `PLAN-MULTIPLATFORM.md` for the multiplatform work.
