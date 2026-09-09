# Collimation Camera — multiplatform plan

Status: approved direction, detailed plan, 2026-09-08, reviewed. Written so
that an engineer or agent with no prior context can execute it. The original
macOS design is in `PLAN.md`; this document adds the multiplatform work on top.

## Progress

| Milestone | State |
|---|---|
| 0 — spike | **Windows half done and the gate passed** (§14a): SDL3 + cimgui + SDLGPU3 build and run from Swift, R16_UINT storage-read works on Intel Iris Xe, 2048² uploads hold 60 fps, and the timer numbers confirm §7.3. The macOS half (Metal, MSL, Retina, trackpad pinch) and the camera frame rates are not run. |
| 1 — core portability, Observation, ZWO, CI | Code complete on branch `multiplatform-m1`, **CI green on macOS and Windows**. `core-tests` builds and all 71 tests pass on Windows (Swift 6.3.3) and macOS (Swift 6.1.2); `capture-cli` builds on both; `CollimationApp` builds on macOS. The rest of §7.8 needs hardware and is untouched: no camera, mount, or filter wheel has been plugged in, so device removal, ZWO MSB alignment, ROI-move-without-restart, and the resize and stabilize checks are all unverified. |
| 2 — `CollimationUI` | Code complete on branch `multiplatform-m2`. `CommandCatalog`, `MetricText`, `HelpText`, `StatusChip`, `LogSlider`, and the six HUD scenes exist with 14 tests; `ImageLayout.ndcRect` replaces `MetalRenderer.toNDC`; the macOS app is rebuilt on top of all of it, and its menus now use the engine's `can*` predicates. §8.7's visual acceptance is **not** done: nobody has compared the app before and after, and the HUD colours moved from named SwiftUI system colours to resolved sRGB constants, so that needs eyes on a screenshot. |
| 3 — portable app | **Code complete on branch `spike/sdl3-gpu` and running on Windows** against the simulator: menu bar, sidebar, live view with the HLSL stretch shader, the six HUD scenes on an ImGui draw list, the save dialog, the error modal, the window icon, and the log file. `stretch shader math` pins the three copies of the stretch maths to each other. CI builds `CollimationCamera` on both runners. Not done: the app has never run on macOS, no camera has been plugged in, and §9.8's screenshot comparison against the SwiftUI app is untouched. |
| 4 — mount and wheel on Windows | §10.1 pulled forward into milestone 1: the serial port is already split into `SerialPortDriver`, `SerialPortPOSIX`, and `SerialPortWindows`. §10.2 needs no work — `PhoenixWheel` loads `PlayerOnePW.dll` through `DynamicLibrary`. §10.3's unit half is done: a `ScriptedSerialPortDriver` covers the probe order, the unrecognized and open-failure paths, and the pulse sequences of all three protocols, and `windows com scanner parsing` covers the registry decode and the COM10-after-COM9 ordering. The manual and hardware halves need a cable and a mount. |
| 5 — packaging and documentation | **Windows done and verified**: the release links as a GUI subsystem image carrying its own icon, and `package-win.ps1` produces a zip that runs from a fresh directory on a machine with no Swift toolchain. `package-portable-mac.sh` bundles the portable app on macOS with its own SDL3 — written but never run, since there is no Mac here. `LICENSES/` indexes every shipped component, and both fetch scripts keep the vendors' own terms. README and `PARITY.md` rewritten for two apps. |

## 1. Decisions on record

| Decision | Choice | Why |
|---|---|---|
| Core language | Keep Swift; make `CollimationCore` build on Windows | 12k lines and 62 tests carry over. The Apple-only surface is small (§3.4). Swift 6.3.3 ships official Windows toolchains. |
| Engine observation | Move from Combine `@Published` to the Observation framework (`@Observable`) | Combine has no maintained Windows port. Observation ships in the Windows toolchain. Raises the macOS minimum from 13 to 14. |
| Second UI | A portable Swift app: SDL3 for windowing and input, SDL3 GPU for rendering, Dear ImGui (through cimgui) for widgets | Runs on Windows and macOS from one codebase, so it is developed on the Mac and tested on Windows. Immediate-mode UI reads the engine each frame; no binding layer. |
| Fallback for the second UI | Win32 + Direct3D 11 + ImGui, Windows only | Used only if the milestone 0 spike shows SDL3 GPU cannot do the upload rate or the render loop. |
| Cameras | Player One and ZWO on both platforms, through one `CameraDevice` protocol, both loaded at runtime like today | No link-time dependency on vendor binaries. |
| Mount and filter wheel | In scope on Windows: Win32 serial port for the EQ6, `PlayerOnePW.dll` for the Phoenix wheel | Feature parity. |
| Sync between UIs | The engine stays the only view model; a new platform-free module `CollimationUI` holds commands, formatters, and HUD scenes; CI builds both apps from milestone 1 | Structure enforces parity instead of discipline. |
| Release deliverables | macOS: the SwiftUI app (`CollimationApp`). Windows: the portable app (`CollimationCamera`). The portable app on macOS is a development and parity build, not a release. | One release per platform. The two macOS apps keep separate `UserDefaults` domains; remembered ports, wheels, and folders are per app (recorded in `PARITY.md`). |
| Stabilization centroid in the portable app | CPU path first, GPU compute later | The CPU reduction already exists and costs under a millisecond; the GPU version is an optimization. |
| Native Windows UI | Not in this plan | Can be added later as a third front end on top of `CollimationUI`. |

### 1.1 Non-goals for this release

Linux as a release target (it builds, shaders need an offline SPIR-V step);
Windows on ARM64 and 32-bit Windows; Intel Macs for the portable app
(Homebrew has no Intel bottle for `sdl3`, source build only); macOS 13; color
cameras and debayering (RAW16 mono only); cameras other than Player One and
ZWO; ASCOM, INDI, or ASIAIR drivers for mount or wheel (direct serial EQ6,
SynScan, LX200 and `PlayerOnePW` only); more than one camera at a time; GPU
centroid in the portable app; code signing, notarization, installers, and
auto-update; localization; touch input; multi-window or docking UI; shared
settings between the two macOS apps; the Win32 + D3D11 fallback unless the
milestone 0 gate fails.

## 2. How to use this document

- Work milestone by milestone (§6 to §11). Each milestone lists tasks, files,
  acceptance criteria, and the commands that prove them.
- Read §3 first. It maps the current code with file and line references, so
  you do not have to rediscover the architecture. Line numbers refer to the
  `main` branch at commit `3afe7a3`; they drift as edits land.
- The `Package.swift` in §4 is the end state. Each milestone names the
  targets it adds; do not declare a target before its directory exists,
  because SwiftPM refuses a manifest whose target path is missing.
- Rules that apply to every change are in §12 (working agreements). Follow
  them from the first merged commit. Milestone 0 spike branches never merge
  and are exempt.
- Facts marked "verified" in §14 were checked against primary sources on
  2026-09-08 (toolchain sources, SDK headers, SDL3 and ImGui sources). Facts
  marked "spike" must be confirmed in milestone 0 before code depends on
  them.
- Style: Google developer documentation style for docs, comments, and commit
  messages. Commit messages have no trailers or footers.

## 3. The code as it is today

Swift Package Manager project, Swift 6 language mode, `Package.swift`
tools-version 6.0, platform macOS 13. Build with `swift run CollimationApp`,
test with `swift run core-tests` (custom runner, 62 tests, exits 1 on failure).

### 3.1 Targets

| Target | Kind | Purpose | Platform dependencies |
|---|---|---|---|
| `POACameraC` | C, types only | Player One camera and filter-wheel enums and structs; functions are resolved at runtime | none |
| `CollimationKernels` | C | Stacking accumulate and moment-centroid kernels (`StackKernels.c`) | none |
| `CollimationCore` | Swift | Capture, pipeline, tracking, analysis, mount, filter wheel, and the `CollimationEngine` view model | `Darwin`, `Combine`, POSIX serial, `dlopen`; links Accelerate (unused) and `dl` |
| `CollimationApp` | Swift executable | macOS SwiftUI window, Metal live view, sidebar, HUD | AppKit, SwiftUI, Metal, MetalKit |
| `CaptureCLI` | Swift executable | One-shot frame grab to PNG | AppKit, ImageIO |
| `CoreTests` | Swift executable | Test runner; a single `main.swift` that also carries `@main` | none |

### 3.2 Data flow

1. `CaptureSession` (`Sources/CollimationCore/Pipeline/CaptureSession.swift`)
   runs a grab loop on a serial `DispatchQueue`. It applies pending exposure,
   gain, ROI, and frame-limit requests, then calls
   `CameraDevice.grabFrame(timeoutMs:)`. For hardware cameras it paces the
   loop to `capFPS` (30 by default, 0 = unlimited while stacking) with
   `Thread.sleep` (line 153). Frames go to `onFrame`.
2. `CollimationEngine.ingest(_:)` (`CollimationEngine.swift:760`) runs on the
   capture thread: applies the 512-pixel software crop
   (`SoftwareCropController`), stores the frame in `FrameSlot` for the
   renderer, feeds `StackCaptureBuffer` while stacking, and submits the frame
   to `FrameCoalescer` (latest-frame-wins analysis queue).
3. `CollimationEngine.analyze(_:)` (`CollimationEngine.swift:772`) runs on the
   analysis queue: `FramePipeline.process` does detection, tracking, coma,
   FWHM, and the star profile, may request a tracker ROI move, stores the
   display frame, then hops to the main actor with `Task { @MainActor in
   self.publish(processed) }`.
4. `publish` updates the published properties the UI reads.
5. The Metal renderer (`Sources/CollimationApp/MetalRenderer.swift`) polls
   `FrameSlot` at 30 fps, uploads new frames to an `r16Uint` texture,
   optionally measures the stabilization centroid on the GPU
   (`GPUCentroid.swift`), and draws a stretched quad. `RenderStateSlot`
   carries stretch, zoom, and stabilization pose from the engine to the
   renderer. The quad's NDC rect comes from `ImageLayout.imageRect` and the
   private `MetalRenderer.toNDC` (`MetalRenderer.swift:210`).

### 3.3 Threading and isolation

- `CollimationEngine` is `@MainActor` and `ObservableObject`. Its
  `nonisolated let` members (`frameSlot`, `renderStateSlot`, `stabilization`,
  `session`, `pipeline`, `coalescer`, `mount`, `filterWheel`, and so on) are
  lock-protected classes shared with background threads.
- Long operations (auto exposure, stacking, constellation, mount calibration
  and centering, filter wheel moves) are `Task`s on the main actor that await
  `Task.sleep` and poll `frameSequence`. Mount and filter wheel SDK calls run
  inside `Task.detached`. Camera SDK calls do not: `connect()` calls `open()`
  and `applyExposure()`, and `disconnect()` calls `CaptureSession.stop()`,
  synchronously on the main actor.
- `CaptureSession.stop()` cancels the grab, waits up to 3 s for the capture
  thread to leave SDK calls, then calls `stopVideo()` and `close()`. It runs
  on the caller's thread, which is the main actor both for user-initiated
  disconnect and for the grab-error path (`session.onError` → `handleError`
  → `disconnect`). On a grab error the capture thread calls `stopVideo()`
  itself before leaving the group, so the main actor waits for that call,
  then repeats `stopVideo()` and calls `close()`. If the 3 s wait expires,
  the main thread's calls overlap the capture thread's, which is the
  concurrent-SDK case §13 warns about. Keep this order on every platform;
  neither SDK documents thread safety. In the portable app the wait freezes
  the render loop for its duration (§9.5); §7.5 measures it.
- `LiveView.updateNSView` (`LiveView.swift:37-45`) is the only place that
  feeds the live-view size into `engine.viewWidth`/`viewHeight`. It runs
  today only because `@ObservedObject` re-invokes it on every published
  change. §7.4 replaces it with an explicit resize hook.

### 3.4 Apple-only code in the core

This is the complete list. Everything else in `CollimationCore` uses
Foundation, Dispatch, Swift concurrency, or the C kernels, all of which have
Windows implementations (verified).

| File | What | Replacement |
|---|---|---|
| `Camera/POALoader.swift` | `dlopen`/`dlsym`, `usleep(200)` at line 221, Bundle paths | `DynamicLibrary` helper (§7.2); `preciseSleep` (§7.3) |
| `Camera/POACameraDevice.swift` | `import Darwin` for `memcpy` at line 164 | `UnsafeMutableRawBufferPointer.copyMemory` |
| `FilterWheel/POAPWLoader.swift` | `dlopen`/`dlsym` | `DynamicLibrary` |
| `FilterWheel/PhoenixWheel.swift` | `usleep` | `preciseSleep` |
| `Mount/SerialPort.swift` | POSIX termios, `poll`, `ioctl`, `/dev/cu.*` scan | Protocol plus POSIX and Win32 implementations (§10.1) |
| `Mount/EQ6Mount.swift` | `speed_t`, `B9600`, `usleep` | Integer baud, `preciseSleep` |
| `Analysis/AiryRenderer.swift` | `j1` from Darwin | Pure Swift Bessel `j1` (§7.3) |
| `Pipeline/Stretch.swift` | `Darwin.asinh` | `Foundation.asinh` |
| `Pipeline/RenderState.swift` | `import Combine` (unused; the file uses only `NSLock` and `SIMD2`) | Delete the import |
| `CollimationEngine.swift` | `Combine` (`@Published`, `sink`) | Observation (§7.4) |
| `Pipeline/CaptureSession.swift:115,169` | `DispatchQueue.main.async` | Call `onError` directly; the engine hops to the main actor |
| `Package.swift` | links `Accelerate`, `dl` | Remove both |

`CaptureCLI` uses AppKit and ImageIO to write PNG; it moves to the existing
`MonoTIFF` writer so it runs on Windows. Diagnostic output today is `print`
plus `fflush(stdout)` in `Mount/SerialPort.swift:158-164`,
`Mount/EQ6Mount.swift:315`, and `FilterWheel/PhoenixWheel.swift:32,59,70,134,139`;
§7.3 routes it through a log sink.

### 3.5 Key constants and rules the ports must preserve

- Live view readout cap 30 fps (`CaptureLayout.maxReadoutFPS`); stacking
  requests unlimited (`unlimitedReadoutFPS = 0`).
- Hardware ROI while tracking 2048×2048 (`trackingHardwareSize`); display and
  analysis crop 512 (`displayCropSize`); stacking crop 256.
- Clip threshold `StarQuality.clipADU = 0xFFF0`. 12-bit and 14-bit cameras
  put data in the high bits, so this works for Player One and ZWO.
- Exposure UI range 100 µs to 100 ms (`ExposureControl.range`).
- Zoom 0.25 to 8 (`CollimationEngine.minZoom`, `maxZoom`), 0.05 floor while a
  full-frame preview is shown. Zoom 1.0 means one image pixel per view point.
  Nearest-neighbor sampling at zoom ≥ 1, manual bilinear below. Scroll zoom
  multiplies by 1.08 or 0.92 once per scroll event by the sign of the delta
  (`LiveView.swift:23-28`), not per accumulated tick.
- ROI alignment today: width and x multiples of 4, height and y multiples of
  2 (`Alignment.centeredROI`). ZWO needs width multiples of 8 (§7.5).
- Keyboard shortcuts (macOS `CollimationApp.swift:20-97`): connect ⌘K, auto
  stretch ⌘A, auto exposure ⌘E, save TIFF ⌘S, save stacked ⇧⌘S, search full
  frame ⌘F, stabilize ⌘L, calibrate mount ⇧⌘G, center star ⌘G, overlay ⌘O,
  filters ⌥1 to ⌥9 (positions 0 to 8, `CollimationApp.swift:88-92`). Return
  in the sidebar connects (`SidebarView.swift:103`).
- Menu and sidebar enablement differ today for four items; §7.4 resolves
  it in favor of the sidebar predicates.
- Overlay colors and HUD geometry: `LiveView.swift` (`OverlayChrome`,
  `OverlayView`, `ROIMapView` 140×94 max, `StarProfileView` 148×102,
  `OverlayLegendView`), `SidebarView.swift` (`HistogramView`, `CompassDial`
  88×88), `ContentView.stateChip` labels and colors. HUD labels are 8 pt
  monospaced (`LiveView.swift:474`, weight medium; `SidebarView.swift:48`,
  weight semibold); metric rows use `.caption.monospacedDigit()`; captions
  are 10 pt; body 13 pt.
- Stretch shader math: `MetalRenderer.swift:234-317`. The CPU reference is
  `StretchParams.apply` in `Pipeline/Stretch.swift`.

## 4. Target architecture

```
Sources/
  POACameraC/            types-only Player One headers (unchanged)
  ASICameraC/            NEW (M1) types-only ZWO header excerpt
  CollimationKernels/    C kernels (unchanged)
  CollimationCore/       shared core; Platform/ holds the only #if os() code
  CollimationUI/         NEW (M2) platform-free UI model: commands, formatters, HUD scenes
  CollimationApp/        macOS SwiftUI app (refactored onto CollimationUI)
  CollimationPortableApp/ NEW (M3) SDL3 + ImGui app (Windows, macOS)
  CImGui/                NEW (M3) C++ target
    include/CImGui.h     umbrella header Swift imports (defines the cimgui C macros)
    vendor/              pinned cimgui + imgui subset + SDL3/SDLGPU3 backends (committed copies, never edited)
    vendor/UPSTREAM.md   cimgui SHA, imgui version, copy command, bump procedure
    backends_shim.cpp    C-linkage wrappers for the SDLGPU3 renderer backend
  CSDL3/                 NEW (M3) system-library target: module map + shim header for SDL3
  CaptureCLI/            cross-platform now (TIFF output, --device)
  CoreTests/             runs on both platforms; gains UI-model tests; main.swift renamed (§8.6)
Vendor/                  gitignored binaries only
  PlayerOne/             dylibs (macOS) and DLLs (Windows)
  ZWO/                   libASICamera2 + libusb (macOS), ASICamera2.dll (Windows)
  SDL3/                  SDL3-devel VC zip contents (Windows); macOS uses Homebrew
Resources/
  AppIcon-1024.png       master (committed); AppIcon.icns (committed)
  AppIcon-256.png        NEW window icon (committed); AppIcon.ico NEW PE icon (committed)
  CollimationCamera.rc   NEW `1 ICON "AppIcon.ico"` (committed); CollimationCamera.res generated on Windows (gitignored)
  Fonts/                 NEW DejaVu Sans, DejaVu Sans Mono, DejaVu Sans Mono Bold + LICENSE (committed)
LICENSES/                NEW third-party license texts shipped with every package (§5.3)
scripts/
  fetch-sdk.sh           extended: ZWO, libusb
  fetch-sdk.ps1          NEW Windows: Player One, ZWO, SDL3, rc.exe step
  vendor-cimgui.sh       NEW copies the pinned cimgui/imgui subset into Sources/CImGui/vendor/
  make-icon.sh           extended: also writes AppIcon-256.png and AppIcon.ico
  package-app.sh         macOS SwiftUI app bundle (extended: ZWO + libusb + LICENSES, macOS 14)
  package-portable-mac.sh NEW macOS bundle for the portable app
  package-win.ps1        NEW Windows zip
.github/workflows/ci.yml NEW (M1) macOS + Windows matrix, extended in M3
PARITY.md                NEW feature parity checklist
```

Dependency direction: `CollimationUI` depends on `CollimationCore`; both apps
depend on both. Neither `CollimationCore` nor `CollimationUI` imports AppKit,
SwiftUI, Metal, WinSDK, SDL3, or ImGui outside `CollimationCore/Platform/`.

`Package.swift` end state (tools-version 6.0, platforms `[.macOS(.v14)]`).
Host-evaluated `#if os()` omits macOS-only targets on Windows and switches
how SDL3 is located (verified: SwiftPM has no per-platform target exclusion;
`#if` in the manifest is evaluated on the build host, which equals the target
for native builds). Milestone 1 adds `ASICameraC`, raises `platforms`,
removes Accelerate and `dl`, and wraps `CollimationApp`; milestone 2 adds
`CollimationUI`; milestone 3 adds `CSDL3`, `CImGui`, `CollimationPortableApp`,
and the SDL settings variables.

```swift
// swift-tools-version: 6.0
import PackageDescription

let sdlInclude = "\(Context.packageDirectory)/Vendor/SDL3/include"   // Windows only
let sdlLib = "\(Context.packageDirectory)/Vendor/SDL3/lib/x64"        // Windows only
let iconRes = "\(Context.packageDirectory)/Resources/CollimationCamera.res"

#if os(Windows)
let csdl3: Target = .systemLibrary(name: "CSDL3", path: "Sources/CSDL3")
let sdlCSettings: [CSetting] = [.unsafeFlags(["-I", sdlInclude])]
let sdlCxxSettings: [CXXSetting] = [.unsafeFlags(["-I", sdlInclude])]
let sdlSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I", "-Xcc", sdlInclude])]
let sdlLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-L", sdlLib])]
let guiLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup",
                  "-Xlinker", iconRes], .when(configuration: .release)),
]
#else
let csdl3: Target = .systemLibrary(name: "CSDL3", path: "Sources/CSDL3",
                                   pkgConfig: "sdl3", providers: [.brew(["sdl3"])])
let sdlCSettings: [CSetting] = []
let sdlCxxSettings: [CXXSetting] = []
let sdlSwiftSettings: [SwiftSetting] = []
let sdlLinkerSettings: [LinkerSetting] = []
let guiLinkerSettings: [LinkerSetting] = []
#endif

var targets: [Target] = [
    .target(name: "POACameraC", publicHeadersPath: "include"),
    .target(name: "ASICameraC", publicHeadersPath: "include"),
    .target(name: "CollimationKernels", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-O3"], .when(configuration: .debug))]),
    .target(name: "CollimationCore", dependencies: ["POACameraC", "ASICameraC", "CollimationKernels"]),
    .target(name: "CollimationUI", dependencies: ["CollimationCore"]),
    .executableTarget(name: "CaptureCLI", dependencies: ["CollimationCore"]),
    .executableTarget(name: "CoreTests", dependencies: ["CollimationCore", "CollimationUI"]),
    csdl3,
    .target(name: "CImGui", dependencies: ["CSDL3"], path: "Sources/CImGui",
            publicHeadersPath: "include",
            cSettings: sdlCSettings,
            cxxSettings: sdlCxxSettings + [
                .headerSearchPath("vendor"),
                .headerSearchPath("vendor/imgui"),
                .headerSearchPath("vendor/imgui/backends"),
                .define("IMGUI_DISABLE_OBSOLETE_FUNCTIONS"),
                .define("IMGUI_IMPL_API", to: "extern \"C\""),
                .define("CIMGUI_NO_EXPORT"),
            ]),
    .executableTarget(name: "CollimationPortableApp",
                      dependencies: ["CollimationCore", "CollimationUI", "CImGui", "CSDL3"],
                      swiftSettings: sdlSwiftSettings,
                      linkerSettings: sdlLinkerSettings + guiLinkerSettings + [.linkedLibrary("SDL3")]),
]
var products: [Product] = [
    .library(name: "CollimationCore", targets: ["CollimationCore"]),
    .executable(name: "CollimationCamera", targets: ["CollimationPortableApp"]),
    .executable(name: "capture-cli", targets: ["CaptureCLI"]),
    .executable(name: "core-tests", targets: ["CoreTests"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "CollimationApp",
    dependencies: ["CollimationCore", "CollimationUI"],
    linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"),
                     .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("QuartzCore")]))
products.append(.executable(name: "CollimationApp", targets: ["CollimationApp"]))
#endif

let package = Package(name: "collimation-camera", platforms: [.macOS(.v14)],
                      products: products, targets: targets, cxxLanguageStandard: .cxx17)
```

Notes on this manifest (all verified unless marked spike):
- `unsafeFlags` are allowed because this is the root package; they make the
  package ineligible as a dependency of other packages, which is fine.
- Linker-only arguments must each be preceded by `-Xlinker` in
  `LinkerSetting.unsafeFlags`; `-L` is understood by the swift driver itself.
- The CImGui `cxxSettings` must not define `CIMGUI_DEFINE_ENUMS_AND_STRUCTS`
  or `CIMGUI_USE_SDL3`: `cimgui.cpp` includes `imgui.h` before `cimgui.h`,
  and with that macro set `cimgui.h` redeclares `ImVec2`, `ImGuiIO`, and the
  flag enums as C types in the same C++ translation unit. Those macros live
  in `include/CImGui.h`, the header Swift imports (§9.3). SwiftPM does not
  pass a target's `.define` settings to dependents; a Swift target that
  depends on a C target receives only `-fmodule-map-file` and `-I include`.
- The `.res` icon resource is linked unconditionally in release builds;
  `fetch-sdk.ps1` generates it (§5.2). Do not guard it with a file-existence
  check in the manifest: SwiftPM caches manifest evaluation keyed on the
  manifest text, tools version, and environment, so the check's result goes
  stale. `link.exe` and `lld-link` both accept a `.res` as an input file.
- On Windows, `swift build` puts products under
  `.build\x86_64-unknown-windows-msvc\{debug,release}\`. `SDL3.dll` must sit
  next to the executable or on `PATH` (§9.2).
- Spike: confirm that the `-Xcc -I` swift setting on the app target is
  enough for `import CSDL3` and `import CImGui`, and that the C++ target sees
  the SDL include path. Reference manifests that work on Windows:
  JackPilley/SwiftWindowsSDLTemplate, Painst2005/SwiftSurvivor (same
  subsystem flags), navjack/Codexitma (Windows CI that downloads the SDL3
  devel zip).

## 5. Environment setup

### 5.1 macOS

- Xcode 16 or later with the Swift 6.x toolchain. macOS 14 or later for the
  apps; macOS 15 or later for ZWO cameras on Apple silicon (the vendor's
  arm64 dylib is built with a 15.0 minimum, verified from its load commands).
- `brew install sdl3` (3.4.16 or newer) for the portable app during
  development. Homebrew's `sdl3.pc` is found by SwiftPM's `pkgConfig`.
- `brew install imagemagick` for `scripts/make-icon.sh` (`sips` cannot write
  ICO files).
- SDKs: `scripts/fetch-sdk.sh` downloads Player One camera and filter-wheel
  dylibs, ZWO `libASICamera2` (x86_64 and arm64 slices, combined with `lipo`),
  and `libusb-1.0.0.dylib` into `Vendor/`.

### 5.2 Windows

- Windows 10 22H2 or Windows 11, x64. Build on an NTFS volume, not a Dev
  Drive (ReFS); `lld-link` fails there with Swift 6.3.x (verified, open bug).
- Visual Studio 2022 Build Tools or Community with components
  `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` and a Windows 11 SDK
  (`Windows11SDK.22621` or newer). Enable Developer Mode in Windows settings.
- Swift 6.3.3: `winget install --id Swift.Toolchain -e --source winget`.
  Verify with `swift --version` in a plain PowerShell. If `swift build`
  reports `could not find CLI tool 'link'`, SwiftPM's eager lookup of a
  static-library librarian did not find MSVC's `link.exe` on `PATH`
  (verified): run from the x64 Native Tools prompt, or pass
  `-Xswiftc -use-ld=lld`, which makes the toolchain's `lld-link` the
  librarian.
- GPU: Direct3D 12 feature level 11_0, Shader Model 6, and resource binding
  tier 2 (any discrete GPU from the last decade; Intel Haswell and Broadwell
  iGPUs are tier 1 and are accepted through the fewer-resource-slots property
  in §9.4). SDL 3.4.x's own D3D12 blit shaders are DXIL, so SM6 is required
  even though the app ships DXBC (verified; fixed in SDL 3.6).
- Drivers: Player One camera driver (`Player_One_Camera_Driver_V1.6.x`) and
  ZWO ASI camera driver (V3.28 or newer). Both are separate downloads from the
  vendor software pages and are required on Windows only. Install drivers
  before the first launch.
- SDKs, SDL3, and the icon resource: `scripts/fetch-sdk.ps1` downloads and
  unpacks, with SHA-256 checks and an env-var override per file:
  - `SDL3-devel-3.4.16-VC.zip` from
    `https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/`
    → `Vendor/SDL3/include`, `Vendor/SDL3/lib/x64/{SDL3.lib, SDL3.dll}`; it
    also copies `SDL3.dll` into both SwiftPM output directories so
    `swift run` works;
  - `PlayerOne_Camera_SDK_Windows_V3.10.1.zip` and
    `PlayerOne_FilterWheel_SDK_Windows_V1.2.3.zip` from
    `https://player-one-astronomy.com/download/softwares/` (direct URLs,
    verified) → `Vendor/PlayerOne/{PlayerOneCamera.dll, PlayerOnePW.dll}`
    from each zip's `lib/x64/`;
  - the ZWO bundle from
    `https://dl.zwoastro.com/software?app=DeveloperCameraSdk&platform=windows86&region=Overseas`
    (redirects to a short-lived signed URL; follow redirects, do not
    hard-code the target) → `ASI_Windows_SDK_V1.41/ASI SDK/lib/x64/ASICamera2.dll`
    into `Vendor/ZWO/`; if the download fails, the script prints the manual
    steps;
  - compiles `Resources\CollimationCamera.rc` to `CollimationCamera.res` with
    `rc.exe /nologo /fo` from the newest
    `${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\rc.exe`.
  `-SDL3Only` limits the script to SDL3 and the `.res` (used by CI).
- Optional: Visual Studio Code with the Swift extension for debugging (LLDB).
  For D3D12 validation, install the "Graphics Tools" optional Windows
  feature and create the GPU device with `debug_mode = true` in debug builds.

### 5.3 Repository conventions for binaries and third-party code

- `Vendor/` holds gitignored binaries only (the existing `.gitignore`
  already covers `Vendor/PlayerOne/*.dylib|*.so|*.dll`; add the same patterns
  for `Vendor/ZWO/` and all of `Vendor/SDL3/`, plus
  `Resources/CollimationCamera.res` and `frame.tif`).
- The only committed third-party source is `Sources/CImGui/vendor/` (§9.3);
  mark it `linguist-vendored` in `.gitattributes`. The repository contains no
  git symlinks: Git for Windows defaults to `core.symlinks=false` and checks
  them out as text stubs.
- License texts are committed, not fetched. `LICENSES/` holds
  `SDL3-LICENSE.txt` (zlib), `imgui-LICENSE.txt` and `cimgui-LICENSE.txt`
  (MIT), `PlayerOne-license.txt` and `ZWO-license.txt` (the `license.txt`
  from each SDK package; MIT-style, the notice must accompany copies),
  `libusb-COPYING` (LGPL-2.1, with the libusb version and source URL used),
  `DejaVu-LICENSE.txt` (Bitstream Vera license), and `Swift-LICENSE.txt`
  (Apache-2.0 with Runtime Library Exception, shipped with the runtime DLLs
  to be safe). `fetch-sdk.sh` pulls macOS binaries from INDI, not the SDK
  packages, so add the SDK `license.txt` files by hand when bumping a vendor
  SDK. Every package copies `LICENSES/` (§11).

## 6. Milestone 0: spike (about one week)

Goal: prove the toolchain and the rendering stack before any production code.
Nothing from this milestone ships; keep it in `spike/` branches.

### 6.1 Tasks

1. **Core builds on Windows.** Apply the minimal edits from §3.4 as
   temporary `#if os(Windows)` stubs (serial port stubbed, `j1` stubbed) so
   that `swift build --product core-tests` and `swift run core-tests` pass on
   Windows. Record the runtime DLL list the executable needs (§11.2).
2. **Observation smoke test.** A 20-line Windows program with an
   `@Observable @MainActor` class and a `Task { @MainActor in }` hop, driven by
   a loop that calls `RunLoop.main.limitDate(forMode: .default)`. Confirms the
   main-actor draining model of §9.5.
3. **SDL3 + ImGui hello world** in Swift on both platforms, with the manifest
   in §4 and the CImGui layout of §9.3:
   - window with `SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY`, GPU
     device, swapchain with vsync;
   - `import CImGui` from Swift resolves `igBegin`, `ImVec2`,
     `ImGui_ImplSDL3_InitForSDLGPU`, and `cimgui_sdlgpu3_init`, and
     `SDL_GPUDevice` is the same type Swift sees through `CSDL3`; the ImGui
     demo window renders with the fonts from §9.6 (no `?` glyphs);
   - `SDL_GPUTextureSupportsFormat(device, R16_UINT, 2D, GRAPHICS_STORAGE_READ)`
     returns true on the test machines (record the GPU names);
   - a 2048×2048 `R16_UINT` storage-read texture updated every frame from a
     CPU buffer, drawn through the stretch fragment shader (§9.4), MSL source
     on macOS and HLSL compiled at runtime with `D3DCompile` on Windows,
     including the arcsinh branch;
   - a compute pass that reduces a 513×513 window of the texture to a peak
     value in a storage buffer, downloaded through a transfer buffer and a
     fence (keeps the GPU-centroid option proven);
   - `SDL_ShowSimpleMessageBox` works before `SDL_Init` and with a `nil`
     window; `SDL_SetLogOutputFunction` replaces SDL's default output;
   - measure: steady 60 fps with the upload, CPU time per frame.
4. **Native pieces from SDL3:** save-file dialog, mouse wheel deltas, pinch
   on the Mac trackpad, Ctrl + wheel from a Windows precision touchpad pinch
   (expected but not verified from a primary source), display scale on a
   HiDPI Windows monitor, window resize, and a Retina check on an unbundled
   macOS executable.
5. **Player One and ZWO on Windows through `capture-cli`** once milestone 1
   task 7.5 exists; otherwise a throwaway loader that calls
   `POAGetCameraCount` and `ASIGetNumOfConnectedCameras`. Log the achieved
   frame rate at the 2048 ROI and note it next to the macOS figure for the
   same camera in §14.
6. **Timer resolution on Windows.** In the task 3 program, measure the actual
   duration of `Thread.sleep(forTimeInterval:)` for 0.0002 and 0.0333 (a)
   before `SDL_Init`, (b) after `SDL_Init`, (c) with a
   `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` waitable timer. Expected: about
   15.6 ms, about 1 ms, under 0.1 ms. Record the numbers in §14.

### 6.2 Gate

- If task 1 fails on the current toolchain, pin the last known-good Swift
  release (§13) and file the regression before continuing.
- If task 2 shows that `RunLoop.main.limitDate` does not drain main-actor
  jobs, install a custom main executor through the Swift 6.2 `ExecutorFactory`
  and `MainExecutor` SPI (the shape used by swift-platform-executors) that
  appends jobs to a lock-protected queue drained by `MainLoop` each frame.
- Proceed with SDL3 GPU if tasks 3 and 4 pass on both platforms. If the
  `R16_UINT` storage read is unsupported on a target GPU, fall back in order:
  `R16_UNORM` with `SAMPLER` usage and a nearest sampler, recovering the ADU
  with `round(v * 65535)` (also queried, it is not on SDL's universal list);
  then `R32_FLOAT` with `GRAPHICS_STORAGE_READ`, which SDL guarantees
  everywhere, with a `UInt16` to `Float` conversion during the transfer-buffer
  copy. Only if uploads or the render loop are unusable switch milestone 8
  to Win32 + Direct3D 11: the same ImGui UI code, ImGui's Win32 and DX11
  backends, a `R16_UINT` texture read with `Load`, `Map(WRITE_DISCARD)`
  uploads, a flip-model swapchain, and `timeBeginPeriod(1)` at startup (SDL
  does this on the main path, §9.5). UI and HUD code stay identical; only
  `GPULiveRenderer` and the window plumbing differ.

Write the spike findings into §14 and commit.

## 7. Milestone 1: core portability, Observation, ZWO, CI

### 7.1 Package changes

- Raise `platforms` to `.macOS(.v14)`; update `LSMinimumSystemVersion` in
  `scripts/package-app.sh:27` to `14.0` and the README requirements.
- Remove `linkedFramework("Accelerate")` and `linkedLibrary("dl")` from
  `CollimationCore`.
- Add target `ASICameraC` with `include/ASICamera2.h` (types only, §7.5)
  and `include/module.modulemap`, plus a `dummy.c` like `POACameraC`.
- Wrap `CollimationApp` in `#if os(macOS)` as shown in §4.

### 7.2 `Platform/DynamicLibrary.swift`

```swift
struct DynamicLibrary {
    private let handle: UnsafeMutableRawPointer   // dlopen handle or HMODULE

    /// Tries each candidate path in order, then the bare name. On failure
    /// logs each attempt with dlerror() / GetLastError() through Log (§7.3).
    init?(candidates: [String], bareName: String)
    func symbol<T>(_ name: String) -> T?          // dlsym / GetProcAddress + unsafeBitCast

    /// Directories searched for vendor libraries, in order:
    /// executable directory, <exe>/../Frameworks (macOS bundle),
    /// <cwd>/Vendor/<vendor>, cwd, then platform defaults
    /// (/usr/local/lib and ~/Library/PlayerOne on macOS).
    static func candidatePaths(fileName: String, vendorFolder: String) -> [String]
}
```

- macOS: `dlopen(path, RTLD_NOW | RTLD_LOCAL)`, `dlsym`.
- Windows: `LoadLibraryExW(path, nil, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
  LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)` so a vendor DLL finds its own
  dependencies next to it; `GetProcAddress`. `import WinSDK`.
- Replace the `openLibrary`/`candidatePaths` code in `POALoader.swift:262-291`
  and `POAPWLoader.swift:155-184` with this helper. File names: macOS
  `libPlayerOneCamera.dylib`, `libPlayerOnePW.dylib`, `libASICamera2.dylib`;
  Windows `PlayerOneCamera.dll`, `PlayerOnePW.dll`, `ASICamera2.dll`.
- `CameraError.sdkNotFound` becomes `sdkNotFound(vendor: CameraVendor)`
  (`enum CameraVendor { case playerOne, zwo }`) and
  `FilterWheelError.sdkNotFound` keeps one case; both messages name the
  platform's file and folder. Update `testFilterWheelErrorText`
  (`CoreTests/main.swift:1641-1645`), which today asserts on
  `libPlayerOnePW.dylib`, to expect `PlayerOnePW.dll` under `#if os(Windows)`.

### 7.3 Small portability edits

- `Analysis/Bessel.swift`: pure Swift `j1(_ x: Double) -> Double` using the
  standard rational approximations (Numerical Recipes `bessj1`: polynomial
  for |x| < 8, asymptotic form above). Test: `j1(0.1) ≈ 0.049937526036242`,
  `j1(1.0) ≈ 0.440050585744934`, `j1(3.8317059702) ≈ 0` within 1e-7. Use it
  in `AiryRenderer.swift` and drop `import Darwin`.
- `Stretch.swift`: `Darwin.asinh` → `asinh` from Foundation.
- `Pipeline/RenderState.swift`: delete the unused `import Combine`. After
  this and §7.4, no file in `CollimationCore` imports Combine.
- `Platform/PreciseSleep.swift` with `func preciseSleep(microseconds: Int)`.
  macOS: `usleep`. Windows: `CreateWaitableTimerExW(nil, nil,
  CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS)`, `SetWaitableTimer`
  with a negative 100 ns due time, `WaitForSingleObject`; if creation fails
  (Windows before 1803), fall back to `Thread.sleep`. Reason: Foundation's
  Windows `Thread.sleep(forTimeInterval:)` is a plain `CreateWaitableTimerW`
  wait (verified in swift-corelibs-foundation `Thread.swift`), quantized to
  the process timer resolution, 15.625 ms unless `timeBeginPeriod` was
  called; a 33 ms pacing sleep then phase-locks to about 47 ms and the
  200 µs frame-ready poll becomes a 15.6 ms poll. Use `preciseSleep` for
  every `usleep` call (`POALoader.swift:221`, `EQ6Mount.swift`,
  `PhoenixWheel.swift`) and for the pacing sleep in `CaptureSession.swift:153`.
  Optional, and only after checking the SDK's own wait behavior because it
  also changes macOS: for Player One, call `POAGetImageData` with a 200 ms
  timeout in slices instead of polling `POAImageReady` every 200 µs.
- `POACameraDevice.swift:164`: replace `memcpy` with
  `dest.copyMemory(from: UnsafeRawBufferPointer(start: s, count: n))`.
- `CaptureSession.swift`: call `onError` directly from the capture thread;
  the engine already hops to the main actor in its handler. Document that
  `onError` may be called on any thread.
- `CollimationCore/Log.swift`: `public enum Log { nonisolated(unsafe) public
  static var sink: @Sendable (String) -> Void = { print($0); fflush(stdout) };
  public static func info(_ message: String) }`. Set `sink` once at startup
  before any thread starts; the sink must be safe to call from the capture,
  mount, and wheel threads. Replace the `print` calls listed in §3.4 with
  `Log.info`, and call `Log.info` where the engine sets `errorMessage`
  (`CollimationEngine.swift:1315,1319`). The default sink keeps stdout, so
  `capture-cli`, `core-tests`, and the SwiftUI app behave as today.
- `CaptureCLI/main.swift`: replace `writePNG` with `MonoTIFF.write(frame:to:)`;
  default output `frame.tif`; remove AppKit and ImageIO; add `--device <id>`
  (falls back to the first hardware device) so both vendors can be tested.
  Update the `Makefile` target `cli`, `.gitignore`, and the README.
- `GuideCalibrationStore.defaultURL()` works unchanged; on Windows it
  resolves to `%LOCALAPPDATA%\Collimation Camera\guide-calibration.json`.
- `UserDefaults.standard` works on Windows; it persists to
  `%LOCALAPPDATA%\<executable name>.plist`. Acceptable; note it in the README.
- Type widths: C `long` is 32-bit on Windows and 64-bit on macOS; C enums
  import as `Int32` on Windows and `UInt32` elsewhere. Use `CLong` and the
  imported enum types, never hard-coded Swift integer types, at SDK
  boundaries.

### 7.4 Observation refactor of `CollimationEngine`

Edit `CollimationEngine.swift`:

1. Replace `import Combine` with `import Observation`. Change the class to
   `@Observable @MainActor public final class CollimationEngine`. Remove
   `ObservableObject`.
2. Delete every `@Published`. Properties keep their access levels
   (`public private(set)` stays).
3. Mark non-UI state `@ObservationIgnored`: `viewWidth`, `viewHeight`,
   `applyingControls`, `lastSentExposure`, `lastSentGain`, `sensorWidth`,
   `sensorHeight`, `optics`, `mountTask`, `stackTask`, `autoExposeTask`,
   `filterWheelTask`, `mountHoldsROI`, `zoomBeforeFullFrame`,
   `axisDirections`, `hardwareFilterPosition`. The `nonisolated let`
   members are untouched.
4. Replace the five Combine subscriptions (`CollimationEngine.swift:196-230`)
   with property observers:
   - `stretch`, `zoom`, `stabilize`: `didSet { updateStabilization() }`
   - `autoCenter`: `didSet { applyPipelineConfig() }`
   - `autoSearch`: `didSet { applyPipelineConfig(); handleAutoSearchChange(autoSearch) }`
   - `selectedSerialPort`: `didSet { defaults.set(selectedSerialPort, forKey: Self.serialPortDefaultsKey) }`
   - `selectedFilterWheelID`: `didSet { if !selectedFilterWheelID.isEmpty { defaults.set(...) } }`
   Remove `cancellables`. Three behavior notes:
   - Observers run for every assignment made in a method called from
     `init()`; only assignments written directly in `init` skip them. The
     sinks today are attached after `init` restores the saved serial port,
     but `refreshSerialPorts()` (`CollimationEngine.swift:818`) assigns
     `ports.first` when the selection is empty, so with an observer in place
     the saved `mount.serialPort` would be overwritten before line 175 reads
     it. Reorder `init()`: read the saved port and assign
     `selectedSerialPort` first, then call `refreshSerialPorts()`; delete the
     now-redundant `serialPorts.insert(saved, at: 0)` in `init()`. Also
     change line 818 to `selectedSerialPort = saved.isEmpty ? (ports.first ??
     "") : saved` so `refreshSerialPorts()` prefers the remembered port
     whenever the selection is empty.
   - `@Published` publishes in `willSet`, so today `updateStabilization()`
     and `applyPipelineConfig()` read the previous values; `didSet` reads the
     new values. This fixes a latent one-event lag (toggling Auto-center now
     reaches `pipeline.configure` on the same event). Record it in §7.8.
   - The sinks also fired once at subscription. Call `updateStabilization()`
     and `applyPipelineConfig()` explicitly at the end of `init()` so the
     render state slot and the pipeline are configured before the first
     frame; the `UserDefaults` writes at init are intentionally dropped.
   Add a test seam: `public init(defaults: UserDefaults = .standard,
   serialPortPaths: @escaping () -> [String] = SerialPortScanner.availablePaths)`;
   store both as `@ObservationIgnored` and use them in `init()`,
   `refreshSerialPorts()`, and the observers instead of `UserDefaults.standard`
   and `SerialPortScanner.availablePaths()`.
5. Move UI-side state into the engine so both apps share it:
   - `public var snapshotDirectory: URL?` backed by the existing
     `snapshot.directory` defaults key (moved from `SnapshotExport`).
   - Enablement predicates, each a computed `public var`:
     - `canRefreshDevices = !isConnected`; `canSelectDevice = !isConnected`
     - `canAutoExpose = isConnected && !isAutoExposing && !isStacking && !isMountBusy`
     - `canSaveSnapshot = isConnected && !isStacking`
     - `canSaveStacked = isConnected && !isStacking && !isMountBusy && tracking.state == .tracking`
     - `canSelectStackCount = !isStacking`
     - `canCalibrateMount = isMountConnected && isConnected && !isMountBusy && !isStacking && tracking.state == .tracking`
     - `canCenterStar = canCalibrateMount && isMountCalibrated`
     - `canSaveConstellation = canCenterStar`
     - `canToggleAutoCenter = !isMountBusy && !isStacking`
     - `canSearchFullFrame = isConnected && !isMountBusy && !isStacking`
     - `canConnectMount = (isMountConnected || !serialPorts.isEmpty) && !isMountBusy`
     - `canSelectSerialPort = !isMountConnected && !isMountBusy`; `canRefreshSerialPorts` the same
     - `canConnectFilterWheel = (isFilterWheelConnected || !filterWheels.isEmpty) && !isFilterWheelMoving`
     - `canSelectFilterWheel = !isFilterWheelConnected && !isFilterWheelMoving`; `canRefreshFilterWheels` the same
     - `canSelectFilter = isFilterWheelConnected && !isFilterWheelMoving`

     Controls with no `.disabled` on either surface stay ungated and get no
     predicate: camera Connect/Disconnect, Auto Stretch, Stabilize View,
     Collimation Overlay, Fit to window. Where the macOS menu and sidebar
     disagree today, the sidebar predicate wins because it matches the
     engine's own guards (`calibrateMount()` and `centerStar()` return early
     on `isMountBusy || isStacking`, `CollimationEngine.swift:1005-1014`;
     `handleAutoSearchChange` returns early unless `isConnected &&
     !isMountBusy && !isStacking`, line 689). Four menu items therefore
     tighten when milestone 2 switches the menus to `CommandCatalog`:
     Calibrate Mount (`CollimationApp.swift:58`) and Center Star (line 61)
     also require `isConnected && !isStacking`; Search Full Frame (line 47,
     ungated today) requires `canSearchFullFrame`; Connect Mount (line 50,
     ungated today) requires `canConnectMount`. Name them in the milestone 2
     commit message and in the `PARITY.md` notes column.
   - `disconnect()` also cancels `mountTask`, as it already cancels
     `stackTask` and `autoExposeTask` (§7.5, device removal).
6. `TelescopeOptics`: derive pixel size from `CameraDescriptor.pixelSizeMicrons`
   and keep only the Barlow rule by name (`xena` → 4×, else 1×). Update
   `forCameraName` callers and `testTelescopeOpticsFromCameraName`.

macOS app changes that follow (do them in this milestone so the app keeps
building): `@StateObject` → `@State private var engine = CollimationEngine()`;
`.environmentObject(engine)` → `.environment(engine)`; `@EnvironmentObject`
→ `@Environment(CollimationEngine.self)`; `@ObservedObject var engine` →
`let engine`, plus `@Bindable var engine = engine` inside `body` where `$`
bindings are used. `SidebarView` needs nothing more because its body reads
tracked properties. `LiveView` is the exception: it reads no tracked
property, so SwiftUI stops calling `updateNSView` after the first call, and
that call is today the only feed of `engine.viewWidth`/`viewHeight`. Move the
size feed to an explicit hook: add `var onResize: ((CGSize) -> Void)?` to
`LiveMTKView`, override `setFrameSize(_:)` (call `super`, then
`onResize?(bounds.size)`), and in `makeNSView` set `view.onResize = { size in
Task { @MainActor in engine.viewWidth = size.width; engine.viewHeight =
size.height; engine.updateStabilization() } }`, matching the existing
`onScroll` pattern. Use points from `bounds`, not `drawableSize` pixels, so
the value matches what `MetalRenderer.draw` uses. Leave `updateNSView` empty
of engine state.

### 7.5 ZWO support (both platforms)

**Header excerpt** `Sources/ASICameraC/include/ASICamera2.h`: copy only the
enums and structs from ZWO SDK 1.41, written as real C enums (the vendor
header defines them as `int` macros in C mode): `ASI_BOOL`,
`ASI_BAYER_PATTERN`, `ASI_IMG_TYPE` (RAW8 = 0, RGB24 = 1, RAW16 = 2, Y8 = 3),
`ASI_ERROR_CODE` (0 to 23 as listed in §14), `ASI_CONTROL_TYPE` (GAIN = 0,
EXPOSURE = 1, OFFSET = 5, BANDWIDTHOVERLOAD = 6, TEMPERATURE = 8, FLIP = 9,
HARDWARE_BIN = 13, HIGH_SPEED_MODE = 14, ...), `ASI_FLIP_STATUS`,
`ASI_CAMERA_INFO`, `ASI_CONTROL_CAPS`. Field order and types must match the
vendor header exactly. Keep `long` fields (`MaxHeight`, `MaxWidth`,
`MinValue`, `MaxValue`, `DefaultValue`) as `long` and use `CLong` in Swift.
Do not define `_WINDOWS`; the vendor's `__declspec(dllexport)` on
declarations is harmless but unnecessary since functions are resolved at
runtime.

**`Camera/ASILoader.swift`**, class `ASINative` mirroring `POANative`,
resolving with `@convention(c)`:

```
ASIGetNumOfConnectedCameras() -> Int32
ASIGetCameraProperty(UnsafeMutablePointer<ASI_CAMERA_INFO>, Int32) -> ASI_ERROR_CODE
ASIOpenCamera(Int32), ASIInitCamera(Int32), ASICloseCamera(Int32)
ASIGetNumOfControls(Int32, UnsafeMutablePointer<Int32>)
ASIGetControlCaps(Int32, Int32 index, UnsafeMutablePointer<ASI_CONTROL_CAPS>)
ASIGetControlValue(Int32, ASI_CONTROL_TYPE, UnsafeMutablePointer<CLong>, UnsafeMutablePointer<ASI_BOOL>)
ASISetControlValue(Int32, ASI_CONTROL_TYPE, CLong, ASI_BOOL)
ASISetROIFormat(Int32, Int32 w, Int32 h, Int32 bin, ASI_IMG_TYPE), ASIGetROIFormat(...)
ASISetStartPos(Int32, Int32 x, Int32 y), ASIGetStartPos(...)
ASIStartVideoCapture(Int32), ASIStopVideoCapture(Int32)
ASIGetVideoData(Int32, UnsafeMutablePointer<UInt8>, CLong size, Int32 waitMs) -> ASI_ERROR_CODE
ASIGetDroppedFrames(Int32, UnsafeMutablePointer<Int32>)
ASIGetSDKVersion() -> UnsafePointer<CChar>?
```

All are cdecl (verified: no `__stdcall` in the header). Error mapping:
`ASI_ERROR_TIMEOUT` → `CameraError.timeout`; `CAMERA_REMOVED`,
`CAMERA_CLOSED` → `.disconnected`; `INVALID_SIZE`, `OUTOF_BOUNDARY` →
`.invalidROI`; others → `.poa(code:message:)` renamed to a vendor-neutral
`.sdk(vendor:code:message:)`.

**Device removal.** Both SDKs return a removal error from the grab
(`POA_ERROR_DEVICE_NOT_FOUND`, `ASI_ERROR_CAMERA_REMOVED`), which reaches
`handleError` and runs the sequence in §3.3 on the main actor. Today
`disconnect()` does not cancel `mountTask`, so an unplug during Center ends
4 s later with `MountError.noStar` from `waitForCentroid`, replacing the
disconnect message; §7.4 item 5 fixes that. Measure `stopVideo` + `close`
after an unplug for each SDK on each platform and record the numbers in §14.
If either exceeds 500 ms, run the post-error `session.stop()` in
`Task.detached`, set an `isClosing` flag that keeps `connect()` refused until
it returns, and keep the synchronous order for user-initiated disconnect.

**`Camera/ASICameraDevice.swift`** conforming to `CameraDevice`:

- `open()`: `ASIOpenCamera`, `ASIInitCamera`; read `ASI_CAMERA_INFO` by
  index (only `ASIGetCameraProperty` takes an index; everything else takes
  the camera ID); descriptor `id: "asi-<CameraID>"`, name, `MaxWidth`,
  `MaxHeight`, `PixelSize`; `supportedBins` from `SupportedBins` until the
  first 0. Enumerate control caps to fill `exposureRange` and `gainRange`.
  Set `ASI_BANDWIDTHOVERLOAD` to the cap's `MaxValue` (fast readout),
  `ASI_HIGH_SPEED_MODE` 0 (keeps 12-bit and 14-bit ADC), `ASI_FLIP` 0.
  `ASISetROIFormat(w, h, 1, ASI_IMG_RAW16)` then `ASISetStartPos` for the
  centered 512 ROI; then exposure and gain.
- `applyExposure`: `ASISetControlValue(id, ASI_EXPOSURE, µs, ASI_FALSE)`.
- `applyROI`: if only `x` and `y` changed and width, height, and binning are
  unchanged, call `ASISetStartPos` without stopping capture (verified: the
  SDK allows moving the ROI while streaming). Otherwise stop video, set
  format, set start position, restart. Read back with `ASIGetROIFormat` and
  `ASIGetStartPos` into `currentROI`. The first frame after a move may still
  come from the old position; the pipeline tolerates that.
- `grabFrame(timeoutMs:)`: loop calling `ASIGetVideoData` with `waitMs = 200`
  until a frame arrives, the deadline passes, or `cancelGrab` was called;
  buffer size `w * h * 2`. Copy into `[UInt16]` as the Player One device
  does. No byte swapping; data is little-endian, MSB-aligned.
- `applyFrameLimit` is a no-op; `CaptureSession` paces in software with
  `preciseSleep`.
- `close()`: `ASIStopVideoCapture` then `ASICloseCamera`.

**ROI alignment per device.** Add to `CameraDevice`:

```swift
public struct ROIAlignment: Equatable, Sendable {
    public var widthMultiple: Int      // POA 4, ASI 8
    public var heightMultiple: Int     // POA 2, ASI 2
    public var originXMultiple: Int    // POA 4, ASI 1
    public var originYMultiple: Int    // POA 2, ASI 1
    public static let playerOne = ROIAlignment(4, 2, 4, 2)
    public static let zwo = ROIAlignment(8, 2, 1, 1)
}
var roiAlignment: ROIAlignment { get }
```

Thread it through `Alignment.centeredROI` and `fullFrameROI` as a parameter
with default `.playerOne`, through `Tracker.process`, `FramePipeline.configure`,
and the four engine call sites (`applyROISize`, `searchNow`,
`applyTrackingWindow`, `showFullFramePreview`). For the ASI120 family also
force `height` to a multiple of 128 so `width * height % 1024 == 0`
(camera name contains "120").

**Catalog.** `DeviceCatalog.list()` appends ZWO devices after Player One;
`DeviceCatalog.vendor(forID:)` returns `.playerOne` for `poa-*`, `.zwo` for
`asi-*`, nil otherwise, and `makeDevice(id:)` dispatches on it.
`playerOneSDKVersion` gains a sibling `zwoSDKVersion`; the status line shows
both when present.

**macOS packaging of ZWO** (`scripts/fetch-sdk.sh` and `package-app.sh`):
combine `lib/mac/libASICamera2.dylib` (x86_64 slice) and
`lib/mac_arm64/libASICamera2.dylib` with `lipo -create`; copy
`libusb-1.0.0.dylib` from Homebrew or the INDI redistribution; run
`install_name_tool -change /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib
@loader_path/libusb-1.0.0.dylib` and `-id @rpath/libASICamera2.dylib`, then
`codesign -s -` (verified: the arm64 dylib hard-codes the Homebrew libusb
path; modified dylibs must be re-signed on Apple silicon). The Player One
dylib references `@rpath/libusb-1.0.0.dylib` too; put one copy of libusb
next to both. The arm64 slice needs macOS 15; document it in the README and
`Vendor/ZWO/README.md`, and let `DynamicLibrary` log the loader error so the
cause shows in the status line.

### 7.6 Tests to add (CoreTests)

- `bessel j1`: values above.
- `roi alignment zwo`: `centeredROI` with `.zwo` returns width % 8 == 0.
- `asi error mapping`.
- `device vendor from id`: `DeviceCatalog.vendor(forID:)` for `asi-0`,
  `poa-0`, `simulator`, and junk; assert `makeDevice("asi-0")` throws
  `sdkNotFound(vendor: .zwo)` only when `ASINative.shared == nil` (on the
  recommended dev setup the library is present).
- `remembered serial port`: with `serialPortPaths` returning `["/dev/cu.a",
  "/dev/cu.b"]` and a `UserDefaults(suiteName:)` instance holding
  `mount.serialPort = "/dev/cu.b"`, a fresh `CollimationEngine` has
  `selectedSerialPort == "/dev/cu.b"` and the key still reads `/dev/cu.b`;
  with the key absent the selection is `/dev/cu.a`; with the key set to a
  path not in the list the selection is that path and `serialPorts.first`
  equals it.
- `filter wheel error text` updated for the platform file name (§7.2).
- Existing tests keep passing on both platforms.

### 7.7 CI (`.github/workflows/ci.yml`)

The workflow lands in the same pull request that makes `core-tests` build on
Windows (§7.1 to §7.3). Steps: `actions/checkout@v6`; on Windows
`compnerd/gha-setup-swift@v0.4.1` with `swift-version: swift-6.3.3-release`
and `swift-build: 6.3.3-RELEASE`, plus `compnerd/gha-setup-vsdevenv` as
librarian insurance (hosted runners pass today only because Git's coreutils
`link.exe` satisfies SwiftPM's lookup); an import guard on both runners with
`shell: bash`:

```
! grep -rEn '^import (Combine|Darwin|AppKit|SwiftUI|Metal|MetalKit|ImageIO)' \
    --exclude-dir=Platform --exclude='SerialPort*.swift' Sources/CollimationCore Sources/CollimationUI
```

then `swift build --product core-tests`, `swift run core-tests`,
`swift build --product capture-cli`, and on macOS `swift build --product
CollimationApp`. No `fetch-sdk` or `brew` step yet: `core-tests` needs no
vendor binaries (loaded at runtime; the `device vendor from id` test covers
their absence) and no SDL3. Windows notes (verified): use Swift 6.1 or newer
on `windows-latest` (Windows SDK 26100); keep one `swift` command per step
because PowerShell does not propagate a failing subcommand's exit code;
cache `.build` with `--cache-path .cache` if build times matter.

### 7.8 Acceptance

- `swift run core-tests` passes on macOS and Windows; CI green on both
  runners for every milestone 1 pull request.
- `swift run capture-cli --list` on Windows lists a Player One and a ZWO
  camera when plugged in; `capture-cli --device poa-0 --output poa.tif` and
  `capture-cli --device asi-0 --output zwo.tif` write valid 16-bit TIFFs.
- macOS app behaves as before with a Player One camera and now lists ZWO
  cameras; the simulator works. Known deliberate changes: control toggles
  take effect on the same event (§7.4 item 4).
- Resize the window with the simulator running, then use Fit to window and
  start a full-frame search: the image fits the new window size both times.
  With Stabilize on, the star stays centered through the resize.
- With a ZWO camera, tracker recentering (star moved to the ROI edge) does
  not restart the stream: the live view does not black out and the fps
  counter stays at 30.
- With a 12-bit ZWO camera, a deliberately saturated exposure reads 65520 at
  the peak (confirms MSB alignment; see §13 for the fallback).
- Unplug the camera during live view: macOS app with Player One and ZWO;
  `capture-cli --hardware` on Windows with both. The error dialog appears
  within 1 s, the UI stays responsive, and Connect succeeds after replugging
  and Refresh. Record `stopVideo` + `close` time per SDK in §14.

## 8. Milestone 2: shared UI model (`CollimationUI`)

Purpose: everything that both UIs must show identically lives here, with
tests, so the two apps are layout and input only.

### 8.1 Commands

```swift
public struct Shortcut: Equatable, Sendable {
    public enum Key: Equatable, Sendable { case character(Character), `return` }
    public enum Modifier: Sendable { case primary, shift, option }
    // primary = ⌘ on macOS, Ctrl elsewhere; option = ⌥ on macOS, Alt elsewhere
    public var key: Key
    public var modifiers: Set<Modifier>
}

public enum CommandMenu: Sendable { case camera, mount, filterWheel, view }

public struct Command: Identifiable {
    public enum Kind {
        case action
        case toggle(get: @MainActor (CollimationEngine) -> Bool,
                    set: @MainActor (CollimationEngine, Bool) -> Void)
    }
    public var id: String
    public var menu: CommandMenu?                       // nil = sidebar only
    public var kind: Kind
    public var title: @MainActor (CollimationEngine) -> String
    public var shortTitle: (@MainActor (CollimationEngine) -> String)?   // sidebar label; nil = title
    public var help: String?                            // tooltip
    public var shortcuts: [Shortcut]                    // Connect has ⌘K and Return
    public var isEnabled: @MainActor (CollimationEngine) -> Bool
    public var perform: @MainActor (CollimationEngine, any UIHost) -> Void
}

/// Platform services a command may need.
@MainActor public protocol UIHost: AnyObject {
    func presentSaveDialog(title: String, message: String, suggestedName: String,
                           directory: URL?, completion: @escaping @MainActor (URL?) -> Void)
}

public enum CommandCatalog {
    @MainActor public static let all: [Command]           // fixed commands
    @MainActor public static func filterCommands(_ engine: CollimationEngine) -> [Command]  // ⌥1…⌥9 for positions < 9
    @MainActor public static func commands(in menu: CommandMenu, engine: CollimationEngine) -> [Command]
}
```

Port every menu item and shortcut from `CollimationApp.swift:20-97`, and the
sidebar buttons that duplicate them. Short titles: Auto Exposure → "Auto";
Calibrate Mount → "Calibrate"; Center Star → "Center"; Save Stacked… → "Save
Stacked"; Save Constellation… → "Save Constellation"; Connect/Disconnect
Mount and Filter Wheel → "Connect"/"Disconnect"; Collimation Overlay → "Hide
overlay" when `showOverlay` else "Show overlay" (the sidebar renders a
`.toggle` command as a button labeled `shortTitle` that flips the value, as
today). Sidebar-only commands (`menu: nil`): `camera.refreshDevices`,
`filterWheel.refresh`, `mount.refreshPorts`, `view.fitToWindow` (calls
`engine.fitZoom()`). Command-attached tooltips (`SidebarView.swift:109, 127,
139, 244, 247, 371`) go in `Command.help`. Both sidebars render every button
and toggle by looking up the command by id; a sidebar never spells a label,
shortcut, help string, or predicate. Save commands call
`host.presentSaveDialog` with the texts from `SnapshotExport`
(`CollimationApp.swift:284-337`), then `engine.saveSnapshot(to:)`,
`saveStackedSnapshot`, or `saveConstellation`, and store the folder in
`engine.snapshotDirectory`. A `UIHost` ignores `presentSaveDialog` while a
dialog is already open (a `dialogOpen` flag cleared in the completion), so a
repeated ⌘S cannot open two dialogs.

### 8.2 Formatting and help text

`MetricText` with static functions ported from `SidebarView.swift:379-491`
plus the inline formats: `coma`, `direction`, `asymmetry`, `fwhm`, `snr`,
`quality`, `exposureLabel`, `percent`, `zoomAndFPS`, `gain` (`%.0f`, line
145), `midtones` (`%.4f`, 336), `arcsinhFactor` (`%.1f`, 342), `zoomPercent`
(`%.0f%%`, 310), `stackCount(Int)` (115), `serialPortName(String)`
(`lastPathComponent` on POSIX paths, unchanged for `COMn` names, line 221;
§10.1 refers to this), `filterWheelPlaceholder(sdkPresent: Bool)` ("SDK not
found" / "No Phoenix wheel", 160), `serialPortPlaceholder` ("No serial
ports", 216), `calibrationSummary(GuideCalibration) -> [String]` (the date
line with abbreviated date and shortened time, plus the "Backlash  RA %.0f px
·  Dec %.0f px" line only when either backlash exceeds 0.5 px, lines
255-267; the test pins the backlash rule, not the locale-dependent date).
`StatusChip.model(engine) -> (label: String, color: HUDColor)` ported from
`ContentView.stateChip` (`CollimationApp.swift:240-282`). `LogSlider` helpers
for the exposure and arcsinh sliders (`SidebarView.swift:452-476`).
`HelpText` enum with the tooltips not attached to a command: `stackCount`
(122), `stackedSave` (124), `filterPicker(slotCount:)` (193), `autoCenter`
(300), `stabilize` (302), `searchFullFrame` (305), `arcsinh` (344), `fwhm`
(361), `roiSection` (293), `legend` (`LiveView.swift:119`), `roiMap` (362),
`starProfile` (440). Tooltips are shown on both platforms: `.help` on macOS,
`igSetItemTooltip` after each item in ImGui.

### 8.3 HUD scenes

```swift
public struct HUDColor: Equatable, Sendable { public var r, g, b, a: Float }
public enum HUDAnchor: Sendable { case topLeading, leading, bottomLeading, center /* … */ }
public enum HUDWeight: Sendable { case regular, medium, semibold, bold }

public enum HUDPrimitive: Equatable, Sendable {
    case line(from: SIMD2<Double>, to: SIMD2<Double>, color: HUDColor, width: Double)
    case polyline(points: [SIMD2<Double>], color: HUDColor, width: Double)
    case circle(center: SIMD2<Double>, radius: Double, color: HUDColor, width: Double)
    case disc(center: SIMD2<Double>, radius: Double, color: HUDColor)
    case rect(origin: SIMD2<Double>, size: SIMD2<Double>, color: HUDColor, width: Double, cornerRadius: Double)
    case fillRect(origin: SIMD2<Double>, size: SIMD2<Double>, color: HUDColor, cornerRadius: Double)
    case fillPolygon(points: [SIMD2<Double>], color: HUDColor)
    case text(String, at: SIMD2<Double>, anchor: HUDAnchor, color: HUDColor, size: Double, monospaced: Bool, weight: HUDWeight)
    case clipped(origin: SIMD2<Double>, size: SIMD2<Double>, primitives: [HUDPrimitive])
}

public enum OverlayScene {   // port of OverlayView.body, LiveView.swift:213-273
    public static func primitives(overlay: OverlayModel, zoom: Double,
        lockNormalized: SIMD2<Double>?, liveCentroid: SIMD2<Double>?,
        displayedWidth: Int?, displayedHeight: Int?, viewSize: SIMD2<Double>) -> [HUDPrimitive]
}
public enum ROIMapScene { public static let maxSize = SIMD2(140.0, 94.0); public static func size(sensorWidth: Int, sensorHeight: Int) -> SIMD2<Double>; public static func primitives(/* … */) -> [HUDPrimitive] }
public enum StarProfileScene { public static let size = SIMD2(148.0, 102.0); /* … */ }
public enum HistogramScene { public static func primitives(histogram: Histogram, stretch: StretchParams, size: SIMD2<Double>) -> [HUDPrimitive] }
public enum CompassDialScene { public static let size = SIMD2(88.0, 88.0); /* … */ }
public enum LegendScene { /* … */ }   // OverlayLegendView rows and marks
public enum OverlayChrome { /* every scene color as an explicit HUDColor */ }
```

Coordinates are view points with the origin at the top left of the widget
box. Each scene is a pure function; the macOS `Canvas` code is the reference
when porting, and the tests pin the geometry. `OverlayChrome` defines every
color the scenes use as explicit sRGB constants, including the SwiftUI
system colors the views use today (orange 255,149,0; red 255,59,48; blue
0,122,255; yellow 255,204,0; gray 142,142,147; white and black with the
existing opacities); `HUDCanvas` draws those constants rather than named
SwiftUI colors.

`ImageLayout` (core) gains `ndcRect(viewWidth:viewHeight:) -> (x0, y0, x1,
y1)`, the move of `MetalRenderer.toNDC` and the quad construction
(`MetalRenderer.swift:112-130, 210-221`); both renderers call it.

### 8.4 Rasterizers

- macOS: `HUDCanvas: View` that draws `[HUDPrimitive]` with `GraphicsContext`
  (about 80 lines). `OverlayView`, `ROIMapView`, `StarProfileView`,
  `HistogramView`, `CompassDial`, `OverlayLegendView` become thin wrappers
  that call the scene and `HUDCanvas`. Keep `.help` tooltips, sourced from
  `HelpText` and `Command.help`.
- Portable app: `HUDDrawList.draw(_ primitives:, on: ImDrawList*, origin:,
  pointScale:)` using the cimgui functions `ImDrawList_AddLine`,
  `ImDrawList_AddPolyline`, `ImDrawList_AddCircle`,
  `ImDrawList_AddCircleFilled`, `ImDrawList_AddRect`,
  `ImDrawList_AddRectFilled`, `ImDrawList_AddConvexPolyFilled`,
  `ImDrawList_AddText_FontPtr(list, font(monospaced, weight), Float(size *
  pointScale), pos, color, text, nil, 0, nil)` (the size argument is the
  final rendered size, so it is multiplied by `pointScale` like the
  coordinates), `ImDrawList_PushClipRect` and `ImDrawList_PopClipRect`.
  Colors through `igColorConvertFloat4ToU32`. Every coordinate is multiplied
  by `pointScale` (§9.6).

### 8.5 macOS app migration

Replace menus with a loop over `CommandCatalog.commands(in:engine:)` that
builds `Button` or `Toggle` per `Kind` and applies `KeyboardShortcut` from
each `Shortcut` (`.primary` → `.command`, `.option` → `.option`, `.return` →
`.return`). Replace the status chip, metric rows, quality text, tooltips, and
the HUD views. `SnapshotExport` becomes the macOS `UIHost` implementation
using `NSSavePanel`. The result must look the same as before, except that
Calibrate Mount, Center Star, Search Full Frame, and Connect Mount in the
menus are greyed out in the extra states listed in §7.4 item 5. Verify with
screenshots before and after on the simulator, and check those menu items
while a stack is running.

### 8.6 Tests

`CoreTests` today is a single `main.swift` that also carries `@main`; it
compiles only because SwiftPM passes `-parse-as-library` for a single-file
executable with `@main`. Before adding a second file, rename it to
`CoreTests.swift`. Mark `main()` `@MainActor` and change `run` to take
`@MainActor () throws -> Void` (Swift 6 rejects passing a `@MainActor`
function to a nonisolated closure parameter; existing nonisolated test
functions convert without changes). Tests that construct `CollimationEngine`
follow three rules:

- Set `engine.selectedDeviceID = CameraDescriptor.simulator.id` before
  `connect()`. `init()` prefers a hardware camera
  (`DeviceCatalog.preferredDeviceID`, `CameraDevice.swift:107-108`), and the
  §7.2 search order finds the vendor library from `swift run core-tests` at
  the repo root, so a bare `connect()` opens a real camera when one is
  attached.
- `defer { engine.disconnect() }`. `connect()` starts the simulator grab loop
  on the capture queue and every analyzed frame queues `Task { @MainActor in
  publish(...) }`; the runner never drains the main queue, so those tasks
  retain the engine, `deinit` never runs, and without the explicit
  `disconnect()` the capture thread is still running when `main()` calls
  `exit()`.
- Do not assert on `publish()` output (`fps`, `histogram`, `tracking`,
  `overlay`) unless the test first loops on
  `RunLoop.main.limitDate(forMode: .default)`. `isConnected`,
  `exposureMicroseconds`, and `gain` are set synchronously by `connect()`.
  `CollimationEngine.init` enumerates cameras through the vendor SDKs,
  scans serial ports, reads `UserDefaults`, and loads the guide calibration
  file if present; pass a `UserDefaults(suiteName:)` and a fixed
  `serialPortPaths` closure (§7.4) to make results deterministic.

Tests:
- `command catalog enablement`: fresh engine on the simulator with
  `serialPortPaths: { [] }`. Disconnected: `connect`, `refreshDevices`,
  `autoStretch`, `overlay`, `stabilize`, `refreshSerialPorts`,
  `refreshFilterWheels`, `fitToWindow` enabled; `autoExpose`, `saveTIFF`,
  `saveStacked`, `saveConstellation`, `calibrate`, `center`,
  `searchFullFrame`, `connectMount`, and every filter command disabled;
  `connectFilterWheel` enabled iff `!engine.filterWheels.isEmpty`. After
  `connect()`: `autoExpose`, `saveTIFF`, `searchFullFrame` enabled;
  `refreshDevices` disabled; `saveStacked` and `calibrate` still disabled
  (`tracking.state` is `.idle` until the first async `publish`). With
  `isStacking` set through a test hook, `calibrate`, `center`, and
  `searchFullFrame` are disabled (pins the sidebar-predicate choice).
  `canToggleAutoCenter` is tested directly.
- `command catalog coverage`: every `Command` has a non-nil `menu` or a
  `shortTitle`; the ids include the four sidebar-only commands.
- `shortcut uniqueness`: no two commands share a `Shortcut`.
- `overlay scene sensor center`: port `testSensorCenterOverlay` to the
  primitive list (a crosshair at the sensor-center view point).
- `overlay scene ring shift`: rings follow the live centroid (port of
  `testOverlayRingsFollowStabilizer`).
- `roi map scene`: the ROI rectangle position for a known ROI.
- `histogram scene`: 256 bars, black and white markers at the right x.
- `compass dial scene`: arrow angle for 90° points down.
- `image layout ndc rect`: a known layout maps to the expected NDC corners.
- `metric text`: coma, FWHM, exposure labels, gain, zoomPercent,
  `calibrationSummary` backlash gating, `serialPortName` for
  `/dev/cu.usbserial-1` and `COM3`, `filterWheelPlaceholder`.

### 8.7 Acceptance

macOS app unchanged in behavior except the menu enablement tightening listed
in §7.4 item 5; `core-tests` includes the UI-model tests and passes on both
platforms; `PARITY.md` created with the feature list (§12.3).

## 9. Milestone 3: portable app (SDL3 + ImGui)

### 9.1 Layout of `Sources/CollimationPortableApp/`

```
main.swift              top-level code: metadata, diagnostics, SDL init, window, GPU device, ImGui, MainLoop.run()
MainLoop.swift          per-frame sequence (§9.5)
GPULiveRenderer.swift   SDL3 GPU: texture upload, stretch pipeline, optional centroid compute
ShaderSource.swift      MSL and HLSL source strings for the stretch shaders (§9.4)
UI/MenuBar.swift        ImGui main menu bar from CommandCatalog
UI/Sidebar.swift        ImGui window: Camera, Filter wheel, Mount, ROI & zoom, Stretch, Collimation
UI/LiveChrome.swift     status chip, zoom/fps label, legend, star profile, ROI map over the live view
UI/HUDDrawList.swift    primitive rasterizer (§8.4)
UI/Dialogs.swift        SDL save dialog (UIHost), error modal
Input.swift             SDL events → engine (wheel and pinch zoom, shortcuts from CommandCatalog)
Platform/AppPaths.swift resources, icon, fonts, log file path
Platform/Diagnostics.swift file log sink, SDL log routing, startup failure box
Resources/Fonts/        DejaVu Sans, DejaVu Sans Mono, DejaVu Sans Mono Bold, LICENSE (repo Resources/Fonts)
```

Use `main.swift` with top-level code rather than `@main`: it avoids the
`@main` and `-parse-as-library` interaction on every platform, and top-level
code is main-actor isolated in Swift 6, which matches SDL's requirement that
`SDL_Init` runs on the main thread (verified).

### 9.2 SDL3 in SwiftPM (`CSDL3`)

`Sources/CSDL3/module.modulemap`:

```
module CSDL3 [system] {
    header "shim.h"
    link "SDL3"
    export *
}
```

`Sources/CSDL3/shim.h` includes `<SDL3/SDL.h>` and then redefines the window
flags as plain literals, because SDL defines them with the function-like
macro `SDL_UINT64_C(...)`, which Swift cannot import (verified; pattern from
gay-pizza/SDL3Swift):

```c
#pragma once
#include <SDL3/SDL.h>
#undef SDL_WINDOW_RESIZABLE
#define SDL_WINDOW_RESIZABLE 0x0000000000000020ull
#undef SDL_WINDOW_HIGH_PIXEL_DENSITY
#define SDL_WINDOW_HIGH_PIXEL_DENSITY 0x0000000000002000ull
/* repeat for every SDL_WINDOW_* flag the app uses; SDL_INIT_* import as-is */
```

Locating SDL3 (verified):
- The include path must be the directory that contains the `SDL3/` folder,
  because SDL's headers include each other as `<SDL3/SDL_x.h>`.
- Windows: no pkg-config. `Vendor/SDL3/include` and `Vendor/SDL3/lib/x64`
  from `SDL3-devel-3.4.16-VC.zip`, passed as absolute paths built from
  `Context.packageDirectory` (§4). `link "SDL3"` becomes
  `/DEFAULTLIB:SDL3.lib`, which the `-L` path resolves. `SDL3.dll` is found
  in the executable's directory before `PATH`; `scripts/fetch-sdk.ps1` copies
  it into `.build\x86_64-unknown-windows-msvc\debug\` and `release\`, and
  the packaging script copies it next to the shipped exe. SwiftPM has no
  post-build hook, so the copy is a script step.
- macOS: `pkgConfig: "sdl3"` with Homebrew. For shipping, copy Homebrew's
  `libSDL3.0.dylib` into the bundle, `install_name_tool -id
  @rpath/libSDL3.0.dylib`, fix the executable's reference with
  `install_name_tool -change /opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib
  @rpath/libSDL3.0.dylib`, add `-rpath @executable_path/../Frameworks`, and
  re-sign (§11.1). SwiftPM already adds `@loader_path` as an rpath, so a
  dylib next to the executable also works for unbundled runs.
- SDL headers use no `__declspec(dllimport)`; importing them from Swift is
  routine. SDL's `SDL_DECLSPEC` is empty for consumers.
- The same pull request that adds the `CollimationCamera` product extends
  `ci.yml` with `scripts/fetch-sdk.ps1 -SDL3Only` (Windows), `brew install
  sdl3` (macOS), and `swift build --product CollimationCamera` on both
  runners.

### 9.3 ImGui in SwiftPM (`CImGui`)

- `scripts/vendor-cimgui.sh <cimgui-sha>` clones cimgui `master`
  (non-docking; tags are stale, so pin by SHA) at that commit and copies only
  these files into `Sources/CImGui/vendor/`: `cimgui.cpp`, `cimgui.h`,
  `cimgui_impl.h`, `cimgui_impl.cpp`; `imgui/{imgui.cpp, imgui_draw.cpp,
  imgui_tables.cpp, imgui_widgets.cpp, imgui_demo.cpp, imgui.h,
  imgui_internal.h, imconfig.h, imstb_rectpack.h, imstb_textedit.h,
  imstb_truetype.h}`; `imgui/backends/{imgui_impl_sdl3.cpp, imgui_impl_sdl3.h,
  imgui_impl_sdlgpu3.cpp, imgui_impl_sdlgpu3.h, imgui_impl_sdlgpu3_shaders.h}`;
  both LICENSE files. It writes `vendor/UPSTREAM.md` (cimgui SHA, imgui
  version, the copy command, and the rule that vendored files are never
  edited; local patches go in `backends_shim.cpp`). Commit the copies.
  imgui 1.92.9b or newer is required (dynamic fonts; SDLGPU3 backend since
  1.91.7). `cimgui.h` expects `imgui/` as a sibling directory, so keep that
  layout.
- The files must live under `Sources/CImGui/` because SwiftPM compiles only
  what it finds by walking the target directory; a `sources:` entry is a
  filter over that walk, so a path such as `../../Vendor/cimgui/cimgui.cpp`
  passes manifest validation and is silently never compiled (link errors
  for `ig*` symbols, no warning). Do not use symlinks either: Git for
  Windows checks them out as text stubs unless `core.symlinks` is true,
  which is off by default on developer machines (this checkout: off).
  Hosted Windows CI runners enable symlinks, so CI would not catch it.
- The `CImGui` target (C++17, `path: "Sources/CImGui"`, `publicHeadersPath:
  "include"`, header search paths `vendor`, `vendor/imgui`,
  `vendor/imgui/backends`) compiles everything under it: `vendor/**/*.cpp`
  plus `backends_shim.cpp`. Compile-time defines (C++ translation units
  only): `IMGUI_DISABLE_OBSOLETE_FUNCTIONS`, `IMGUI_IMPL_API` as
  `extern "C"` so the backend symbols have C linkage, and `CIMGUI_NO_EXPORT`.
  Never define `CIMGUI_DEFINE_ENUMS_AND_STRUCTS` or `CIMGUI_USE_SDL3` while
  compiling the C++ files: those files include `imgui.h` before `cimgui.h`,
  and with the macro set `cimgui.h` redeclares `ImVec2`, `ImGuiIO`, and every
  `ImGui*Flags_` enum as C types and hides the `ImVec2_c` helpers that
  `cimgui.cpp` itself uses (verified against cimgui's own CMake, which puts
  those macros only on the C example). `CIMGUI_USE_SDL3` is unnecessary in
  C++ because `IMGUI_IMPL_API` already gives `imgui_impl_sdl3.cpp` C linkage.
- Swift-facing header. SwiftPM does not pass a target's `.define` settings
  to dependents, so the C-side macros live in the header Swift imports.
  `Sources/CImGui/include/` holds one file, `CImGui.h`; the name matches the
  target so SwiftPM emits `umbrella header` rather than an umbrella
  directory (which would parse `cimgui.h` without the macro and fail):

  ```c
  #pragma once
  #define CIMGUI_DEFINE_ENUMS_AND_STRUCTS 1
  #define CIMGUI_USE_SDL3 1
  #define CIMGUI_NO_EXPORT 1              /* keep in sync with cxxSettings */
  #include <SDL3/SDL.h>                   /* SDL_Window, SDL_Event, SDL_GPU* below */
  #include "../vendor/cimgui.h"
  #include "../vendor/cimgui_impl.h"
  /* backends_shim.cpp, extern "C" */
  bool cimgui_sdlgpu3_init(SDL_GPUDevice *device, SDL_GPUTextureFormat color_format);
  void cimgui_sdlgpu3_new_frame(void);
  void cimgui_sdlgpu3_prepare_draw_data(ImDrawData *draw_data, SDL_GPUCommandBuffer *cmd);
  void cimgui_sdlgpu3_render_draw_data(ImDrawData *draw_data, SDL_GPUCommandBuffer *cmd, SDL_GPURenderPass *pass);
  void cimgui_sdlgpu3_shutdown(void);
  ```

  Do not include `imgui_impl_sdl3.h` or `imgui_impl_sdlgpu3.h` here; they
  are C++. `backends_shim.cpp` includes `imgui.h`, `imgui_impl_sdlgpu3.h`,
  and `<SDL3/SDL.h>`, defines the five functions inside `extern "C"`, and
  `cimgui_sdlgpu3_init` fills `ImGui_ImplSDLGPU3_InitInfo` (all five fields:
  `Device`, `ColorTargetFormat`, `MSAASamples = SDL_GPU_SAMPLECOUNT_1`,
  `SwapchainComposition = SDR`, `PresentMode = VSYNC`) and calls
  `ImGui_ImplSDLGPU3_Init`. cimgui's committed `cimgui_impl.h` already wraps
  the SDL3 platform backend (`ImGui_ImplSDL3_InitForSDLGPU`,
  `ImGui_ImplSDL3_ProcessEvent`, `ImGui_ImplSDL3_NewFrame`,
  `ImGui_ImplSDL3_Shutdown`) but not the SDLGPU3 renderer backend
  (verified), hence the shim. The SDL include path the importer needs is
  already supplied: pkg-config cflags for `CSDL3` on macOS, `-Xcc -I` in
  `sdlSwiftSettings` on Windows.
- Swift calls cimgui directly. Names to expect from cimgui master (verified):
  `igBegin`, `igSliderFloat`, `igCheckbox`, `igCombo_Str_arr`,
  `igBeginMainMenuBar`, `igMenuItem_Bool`, `igSetItemTooltip`,
  `igGetBackgroundDrawList_Nil`, `igIsKeyChordPressed_Nil`, `igShortcut_Nil`,
  `igGetIO_Nil`, `igGetStyle`, `ImGuiStyle_ScaleAllSizes`, `igPushFont`,
  `ImFontAtlas_AddFontFromFileTTF`, `ImDrawList_*`. `ImVec2` is passed by
  value. When bumping, re-check the names against the vendored `cimgui.h`
  and confirm it still guards its C block with a bare `#ifdef
  CIMGUI_DEFINE_ENUMS_AND_STRUCTS`. (ctreffs/SwiftImGui defines the macro in
  `cxxSettings` and only builds because it patches `cimgui.h` to invert that
  guard; do not copy its manifest.)

### 9.4 Rendering (`GPULiveRenderer`)

Mirror `MetalRenderer` one to one on the SDL3 GPU API (all API facts
verified against SDL 3.4.16):

**Device.** `SDL_CreateGPUDeviceWithProperties` with
`SDL_PROP_GPU_DEVICE_CREATE_SHADERS_DXBC_BOOLEAN` on Windows and
`..._SHADERS_MSL_BOOLEAN` on macOS, `..._DEBUGMODE_BOOLEAN` in debug builds,
and `SDL_PROP_GPU_DEVICE_CREATE_D3D12_ALLOW_FEWER_RESOURCE_SLOTS_BOOLEAN =
true` (the renderer binds one storage texture and at most a couple of
storage buffers, well under the 8-resource limit that property imposes; it
admits tier 1 Intel iGPUs). Read the driver with `SDL_GetGPUDeviceDriver`
for the log. Claim the window, then `SDL_SetGPUSwapchainParameters(device,
window, SDR, VSYNC)`. The ImGui backend picks DXBC on `direct3d12` and MSL
on Metal by itself.

**Texture.** Format `SDL_GPU_TEXTUREFORMAT_R16_UINT`, usage
`SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ` (plus `COMPUTE_STORAGE_READ`
once the compute centroid exists). Integer formats cannot carry the
`SAMPLER` usage, and `SAMPLER` cannot be combined with
`GRAPHICS_STORAGE_READ`. Query `SDL_GPUTextureSupportsFormat(device,
R16_UINT, SDL_GPU_TEXTURETYPE_2D, usage)` at startup and log the result; on
`false` use the fallback chain of §6.2 (`R16_UNORM` + `SAMPLER` nearest with
`round(v * 65535)`, then `R32_FLOAT` storage read). Recreate the texture
when the frame size changes; keep two and alternate like `textures[0..1]`.

**Upload.** One `SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD` transfer buffer of
`w * h * 2` bytes. Each frame whose `FrameSlot` sequence changed: map with
`cycle = true`, copy rows tightly packed (row pitch `w * 2`; 2048-pixel rows
are 4096 bytes, which satisfies D3D12's 256-byte row alignment), unmap,
then in a copy pass `SDL_UploadToGPUTexture(copyPass, transferInfo, region,
cycle: true)`. Do the copy pass before any render pass in the same command
buffer.

**Stretch pass.** One graphics pipeline: primitive `TRIANGLESTRIP`, no
vertex buffers (`num_vertex_buffers = 0`; positions come from `SV_VertexID`
/ `[[vertex_id]]` and a uniform holding the NDC rect), color target format
from `SDL_GetGPUSwapchainTextureFormat`, no depth, no blend. Uniforms:

- Vertex slot 0: `struct QuadRect { float x0, y0, x1, y1; }` from
  `ImageLayout.ndcRect(viewWidth:viewHeight:)` (§8.3), in NDC with +Y up.
- Fragment slot 0: `StretchUniforms { float black, white, amount, nearest,
  mode; uint clipADU; float texW, texH; }` (8 scalars, 32 bytes, so HLSL
  cbuffer packing and MSL layout agree).

Push with `SDL_PushGPUVertexUniformData(cmd, 0, …)` and
`SDL_PushGPUFragmentUniformData(cmd, 0, …)`; bind the texture with
`SDL_BindGPUFragmentStorageTextures(pass, 0, &texture, 1)`. Shader create
info: vertex `num_uniform_buffers = 1`; fragment `num_storage_textures = 1`,
`num_uniform_buffers = 1`, `num_samplers = 0`.

**Binding conventions (verified from `SDL_gpu.h`).** SDL fixes the register
layout; the shaders must match it exactly:

| Stage | HLSL (DXBC SM 5.1) | MSL |
|---|---|---|
| Vertex uniforms | `cbuffer QuadRect : register(b0, space1)` | `constant QuadRect& rect [[buffer(0)]]` |
| Fragment storage texture | `Texture2D<uint> tex : register(t0, space2)` | `texture2d<ushort, access::read> tex [[texture(0)]]` |
| Fragment uniforms | `cbuffer Stretch : register(b0, space3)` | `constant StretchUniforms& u [[buffer(0)]]` |
| Compute read-only storage texture | `Texture2D<uint> : register(t0, space0)` | `[[texture(0)]]` |
| Compute read-write storage buffer | `RWStructuredBuffer<T> : register(u0, space1)` | `[[buffer(1)]]` (after uniforms) |
| Compute uniforms | `cbuffer : register(b0, space2)` | `[[buffer(0)]]` |

Read-only storage textures are SRVs, so HLSL uses `Texture2D<uint>` with
`Load(int3(x, y, 0))`, never `RWTexture2D`. HLSL varyings use `TEXCOORD0`
semantics.

**Shader sources.** Two hand-written sources of the same program, kept in
`ShaderSource.swift` as string literals with a shared comment naming
`StretchParams.apply` as the reference:
- MSL: port of `MetalRenderer.shaderSource` with the argument attributes
  changed to the table above. Passed as source text; SDL compiles it with
  `newLibraryWithSource:` at runtime. Entry points `stretchVertex` and
  `stretchFragment`.
- HLSL: same math in SM 5.1 syntax. HLSL has no `asinh`, `fract`, or `mix`
  intrinsics: define `float asinhf(float x) { return log(x + sqrt(x * x +
  1.0)); }` (exact for the non-negative inputs used here) and use `frac` and
  `lerp`. Compiled at runtime with `D3DCompile` from `d3dcompiler_47.dll`
  (ships with Windows 10 and 11) for targets `vs_5_1` and `ps_5_1`; SDL's
  D3D12 backend ingests the resulting DXBC directly (verified). Call
  `D3DCompile` through `import WinSDK.DirectX` (module `D3DCompiler`, links
  `d3dcompiler.lib`); read the blob through the `ID3DBlob` vtable
  (`GetBufferPointer`, `GetBufferSize`); on failure the error blob text goes
  to the log and the startup failure box (§9.5). Do not use SM 5.0 targets:
  without register spaces the root signature does not match (verified from
  an SDL issue).
- Linux (not a release target): SPIR-V would have to be produced offline
  with the `shadercross` CLI from SDL_shadercross; leave a `.spv` loading
  branch stubbed with a clear error.

Fragment logic, unchanged from Metal: clamp the texel coordinate; nearest
read when `nearest > 0.5`, else four `Load`s and manual bilinear; paint
clipped texels (`>= clipADU`) red; normalize by 65535; apply MTF or
arcsinh.

**Per-frame command buffer order** (copy passes cannot be nested in render
passes, verified; the ImGui example is the reference): if the window is
minimized, `SDL_Delay(16)` and continue before any ImGui frame; otherwise
acquire the command buffer → copy pass with the texture upload (only when
the `FrameSlot` sequence changed) → `cimgui_sdlgpu3_prepare_draw_data` →
`SDL_WaitAndAcquireGPUSwapchainTexture` → if a texture came back, render
pass with `LOADOP_CLEAR` (the dark background color from `MetalRenderer`),
draw the stretch quad, `cimgui_sdlgpu3_render_draw_data`, end pass → always
`SDL_SubmitGPUCommandBuffer`, even when nothing was rendered, so the
recorded upload is not lost and the command buffer does not leak.

**Stabilization centroid.** Milestone 3 uses the existing CPU path
`StabilizationController.process(frame, viewWidth:, viewHeight:)` once per
new frame before drawing; it measures the same `Frame` the GPU path measures.
A GPU version (port of `GPUCentroid.swift`: peak pass, reduce, moment pass,
reduce, `SDL_DownloadFromGPUBuffer` into a `DOWNLOAD` transfer buffer,
`SDL_SubmitGPUCommandBufferAndAcquireFence`, `SDL_WaitForGPUFences`) is a
stretch item after parity. Compute passes need explicit pass boundaries
between dependent dispatches (verified).

**Equivalence test.** `stretch shader math` renders a synthetic 64×64 frame
through the CPU `StretchParams.apply` and compares against the shader's
formula re-implemented in Swift line by line, for MTF and arcsinh (the HLSL
column evaluates the log form of `asinh`), nearest and bilinear.

### 9.5 Main loop and main-actor draining

```
init: SDL_SetAppMetadata("Collimation Camera", version, "local.collimation-camera")
      Diagnostics.start()                            // before SDL_Init: open the log, Log.sink = file, SDL_SetLogOutputFunction → same file
      SDL_Init(SDL_INIT_VIDEO)                       // main thread; no SDL_main needed; calls timeBeginPeriod(1) on Windows
      scale = SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay())
      window (RESIZABLE | HIGH_PIXEL_DENSITY, 1280 × scale by 820 × scale; scale is 1.0 on macOS, 2.0 at 200% on Windows)
      GPU device (§9.4); SDL_ClaimWindowForGPUDevice; swapchain VSYNC; window icon (§9.6)
      ImGui context; load fonts (§9.6); style.FontSizeBase = 13; style.ScaleAllSizes(pointScale); style.FontScaleDpi = pointScale
      ImGui_ImplSDL3_InitForSDLGPU(window); cimgui_sdlgpu3_init(device, swapchainFormat)
      engine = CollimationEngine(); engine.connect()  // same as ContentView.onAppear

loop:
  while SDL_PollEvent(&e):
      ImGui_ImplSDL3_ProcessEvent(&e); Input.handle(e)   // quit, wheel/pinch zoom, shortcuts, resize, DPI change
  RunLoop.main.limitDate(forMode: .default)              // drains DispatchQueue.main and @MainActor jobs
  if minimized: SDL_Delay(16); continue
  cimgui_sdlgpu3_new_frame(); ImGui_ImplSDL3_NewFrame(); igNewFrame()
  MenuBar.draw; Sidebar.draw; LiveChrome.draw (HUD via scenes)
  engine.viewWidth/viewHeight = live region size in view points; engine.updateStabilization()
  igRender()
  renderer.draw(frames: engine.frameSlot, state: engine.renderStateSlot,
                stabilization: engine.stabilization, drawData: igGetDrawData())   // §9.4 order
on quit: engine.shutdown(); SDL_WaitForGPUIdle; ImGui and SDL shutdown in the ImGui example's order
```

Why the `RunLoop.main` call: on Windows, `@MainActor` jobs are enqueued on
the libdispatch main queue, and nothing drains it unless the main thread
runs the run loop (verified from the runtime and CoreFoundation sources).
`limitDate(forMode:)` performs one non-blocking pass that services the main
queue. At 60 Hz this bounds main-actor latency to one frame, which the
engine's polling loops (`waitForCentroid`, auto exposure) tolerate. On macOS
the call is harmless. Do not use an `async main` or `dispatchMain()`: on
Windows `dispatch_main()` ends the calling thread.

Timer resolution: SDL's `SDL_HINT_TIMER_RESOLUTION` defaults to "1", so
`SDL_Init` calls `timeBeginPeriod(1)` on Windows (verified:
`src/timer/SDL_timer.c`, from `SDL_InitMainThread` for any `SDL_Init`
flags). Keep that default; do not set the hint to "0". It makes
`Thread.sleep` and `Task.sleep` 1 ms-accurate in the app, which the engine's
`Task.sleep` polling loops rely on. It does not apply to `capture-cli`, and
Windows 11 withdraws it while the window is minimized or occluded, so the
capture loop uses `preciseSleep` (§7.3) and does not depend on it.

Startup failures: every `init` call that returns `nil` or `false`
(`SDL_Init`, window, GPU device, claim, `D3DCompile`, shader and pipeline
creation, font loading) calls `Diagnostics.fail(step)`, which appends
`SDL_GetError()` (or the `D3DCompile` error blob) to the log, shows
`SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Collimation Camera",
"<step> failed: <error>\n\nLog: <path>", nil)`, and calls `exit(1)`.
`SDL_ShowSimpleMessageBox` is documented as usable before `SDL_Init` and
without a window (spike, §6.1 task 3). Never use `fatalError` in the
portable app: with `/SUBSYSTEM:WINDOWS` it aborts with no visible output. A
missing DLL is not this path; the Windows loader shows its own dialog.

Log file: `%LOCALAPPDATA%\Collimation Camera\collimation.log` on Windows
(same directory as `GuideCalibrationStore.defaultURL()`) and
`~/Library/Logs/Collimation Camera/collimation.log` on macOS. On launch
rename the existing file to `collimation.log.1` and start a new one; flush
after every line; guard writes with a lock; timestamp each line. Log the SDL
version, `SDL_GetGPUDeviceDriver`, the `R16_UINT` support result, the
display scale, and the font paths at startup.

Thread rules: everything in the portable app runs on the main thread except
the engine's existing capture and analysis queues and SDL's dialog thread on
Windows (§9.6). `Thread.isMainThread` is unreliable inside `@MainActor` on
Windows; do not use it. SDL's own macOS setup gives an unbundled executable
a Dock icon and menu bar; do not create an `NSApplication` yourself.

### 9.6 UI, input, DPI, fonts, dialogs

**Coordinate units.** All layout math (`ImageLayout`, HUD scenes, zoom)
works in view points, as in the macOS app. Define
`pointScale = SDL_GetWindowDisplayScale(window) / SDL_GetWindowPixelDensity(window)`,
which is 2.0 on Windows at 200% (window coordinates are pixels there) and
1.0 on a Retina Mac (window coordinates are points); recompute it on
`SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`. ImGui coordinates are window
coordinates, so every HUD coordinate and text size is multiplied by
`pointScale`, and the live region size is divided by it before it reaches
the engine. On a scale change reset the style, apply
`style.ScaleAllSizes(pointScale)` and `style.FontScaleDpi = pointScale`
again (the ImGui SDL3 backend does not do this itself, verified). On macOS,
`io.DisplayFramebufferScale` is filled by the backend from
`SDL_GetWindowDisplayScale`.

**Fonts.** Dear ImGui's embedded ProggyClean maps only U+0000 to U+00FF and
U+20AC (verified from the vendored `imgui_draw.cpp`), so the strings in
`CollimationEngine` and `MetricText` ("—", "…", "″") and the menu glyphs
"⌘" and "⌥" would render as "?". Ship three TrueType files in
`Resources/Fonts/`: DejaVu Sans (proportional, tabular digits by default,
which the metric rows need because ImGui cannot enable OpenType features),
DejaVu Sans Mono, and DejaVu Sans Mono Bold (Bitstream Vera license, in
`LICENSES/`). Each face must contain U+00B0 ° U+00B7 · U+00D7 × U+2014 —
U+2026 … U+2033 ″, and the proportional face also U+2318 ⌘ and U+2325 ⌥.
Load them once at startup, after `igCreateContext` and before
`ImGui_ImplSDL3_InitForSDLGPU`, with `ImFontAtlas_AddFontFromFileTTF(io.Fonts,
path, 0, nil, nil)` (size 0: the 1.92 dynamic atlas rasterizes any size on
demand); the first font loaded becomes the default, so load the proportional
face first. `style.FontSizeBase = 13` (macOS body); secondary text uses
`igPushFont(nil, 10)` (macOS caption and caption2 are 10 pt); HUD labels are
8 pt. Do not reload fonts on a display-scale change; `style.FontScaleDpi`
already rescales them. In debug builds assert `ImFont_IsGlyphInFont` for
every codepoint above and log the font path on failure. `AppPaths` resolves
`Resources/Fonts/` the same way it resolves the icon.

**Sidebar** (ImGui window pinned to the left, width 300 points, full height,
no title bar, no move):
- **Camera**: device combo (`engine.devices`, gated by `canSelectDevice`),
  the `connect` and `refreshDevices` commands, Save TIFF, Save Stacked with
  frame-count combo (`FrameStacker.subframeCounts`, `canSelectStackCount`),
  Save Constellation, exposure log slider with the `autoExpose` command,
  gain slider, status text. Sliders commit on release
  (`igIsItemDeactivatedAfterEdit`) to match `CommitSlider`.
- **Filter wheel**, **Mount**, **ROI & zoom**, **Stretch**, **Collimation**:
  port `SidebarView.swift` section by section; all labels from
  `Command.shortTitle` or `title`, all enablement from the engine predicates,
  all text from `MetricText` and `HelpText`, tooltips via `igSetItemTooltip`
  after each item, the histogram and dial from the scenes. The live-region
  legend, ROI map, and star profile get the same tooltips.

**Live region**: the stretched image fills the area right of the sidebar.
HUD over it, drawn on `igGetBackgroundDrawList_Nil()` (rendered after the
stretch pass because ImGui renders last, and below ImGui windows):
`OverlayScene`, `StatusChip`, zoom and fps label, `LegendScene`,
`StarProfileScene`, `ROIMapScene`, positioned as in `ContentView.chrome`.

**Menu bar**: one ImGui main menu bar with Camera, Mount, Filter Wheel,
View, built from `CommandCatalog`; shortcuts shown as "Ctrl+K" or "⌘K".
Dispatch shortcuts with `igShortcut_Nil(chord, ImGuiInputFlags_RouteGlobal)`
where `Shortcut.primary` maps to `ImGuiMod_Ctrl` (ImGui swaps it to Cmd on
macOS by itself), `.option` to `ImGuiMod_Alt`, and `.return` to
`ImGuiKey_Enter`; ImGui routing skips them while a text field has focus.

**Zoom input**: a mouse wheel event over the live region multiplies zoom by
1.08 or 0.92 by the sign of `wheel.y`, once per event, as
`LiveMTKView.onScroll` does (a trackpad gesture is many small events on
both platforms; record the rule in `PARITY.md`). macOS trackpad pinch
arrives as `SDL_EVENT_PINCH_UPDATE` with `event.pinch.scale` (SDL 3.4+);
multiply zoom by it. Windows has no pinch events; precision touchpads are
expected to deliver pinch as Ctrl + wheel, which the wheel path handles
(spike, §6.1 task 4).

**Errors**: when `engine.errorMessage` is non-nil, open an ImGui modal
titled "Error" with an OK button that clears it. The same text reaches the
log through `Log.info` (§7.3), so the log holds the sequence that led to
the error.

**Save dialogs**: `SDL_ShowSaveFileDialog(callback, userdata, window,
filters, 1, defaultLocation)` with one filter `{ "TIFF image", "tif;tiff" }`
kept in static storage (it must outlive the call), `defaultLocation` set to
`engine.snapshotDirectory` path with a trailing slash plus the suggested
file name. The callback runs on a worker thread on Windows and on the main
thread on macOS (verified), so the C callback only copies the first path
and schedules `Task { @MainActor in completion(url) }`. A `filelist` of
`nil` is an error (`SDL_GetError`); a list whose first entry is `nil` is a
cancel. The `UIHost` keeps `dialogOpen` set until the completion runs.

**Window**: title "Collimation Camera". Icon: `SDL_LoadPNG(path)` on
`Resources/AppIcon-256.png` (available since SDL 3.4.0; `SDL_SetWindowIcon`
converts to ARGB8888 itself), then `SDL_SetWindowIcon`, then
`SDL_DestroySurface`. `AppPaths` resolves the file next to the executable
first, then `<repo>/Resources/` (the same fallback order as `applyAppIcon`
in `CollimationApp.swift`); a missing icon logs and continues. On macOS
SDL's Cocoa backend sets `NSApp.applicationIconImage`, so an unbundled
`swift run` gets the Dock icon. On Windows this sets the title bar, taskbar
button, and Alt-Tab icon of the running window; the icon Explorer, Start,
and shortcuts show comes from the PE resource linked in release (§4
manifest, §11.2). Handle `SDL_EVENT_QUIT` and
`SDL_EVENT_WINDOW_CLOSE_REQUESTED`.

### 9.7 macOS run of the portable app

`swift run CollimationCamera` from the repo works with Homebrew SDL3. The app
must behave identically to the SwiftUI app with the simulator: connect,
auto stretch, stabilize, search, stacking to TIFF. Use this for daily
development; Windows for hardware and packaging tests. If an unbundled run
is not Retina on the Mac, package it (§11.1) or embed an `Info.plist` with
`NSHighResolutionCapable` via `-sectcreate __TEXT __info_plist` (spike).

### 9.8 Acceptance

- Portable app runs on macOS and Windows with the simulator and with Player
  One and ZWO cameras. CI builds `CollimationCamera` on both runners.
- Live view at 30 fps with a 2048 ROI on Windows with a USB3 Player One
  camera and with a ZWO camera (ZWO is software-paced only; `engine.fps`
  shows 30 ± 1 for both, also after the window was minimized for 10 s and
  restored); stacking 1000 frames of 256 crops completes at the camera's
  unlimited rate (compare with the macOS number for the same camera).
- Every command in `CommandCatalog` is reachable from the menu or the
  sidebar and by keyboard on Windows.
- HUD geometry matches the macOS app for the same simulator state: every
  primitive's position and size within 1 point and the same colors, checked
  by overlaying screenshots; font rendering (face, hinting, anti-aliasing)
  is excluded. No UI string renders a fallback "?" glyph (check the FWHM
  row, status text with "—" and "…", and the menu shortcut labels).
- Release build with `SDL_GPU_DRIVER=vulkan` set on a machine without Vulkan
  shows the startup error box naming the failing step and the log path; it
  does not exit silently. After a mount session on Windows,
  `collimation.log` contains the `EQ6 TX/RX` lines.
- Unplug during live view, during a 1000-frame stack, and during Center, on
  macOS and Windows with Player One and ZWO: the error modal opens, the
  render loop keeps drawing (fps label keeps updating; no stall longer than
  the 3 s bound), and reconnect succeeds.
- `PARITY.md` rows for milestone 3 checked.

## 10. Milestone 4: mount and filter wheel on Windows

### 10.1 Serial port

Split `Mount/SerialPort.swift`:

```swift
protocol SerialPortDriver: AnyObject, Sendable {
    var isOpen: Bool { get }
    func open(path: String, baud: Int) throws
    func close()
    func flush()
    func write(_ data: Data) throws
    func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int) throws -> Data
}
enum SerialPortScanner { static func availablePaths() -> [String] }
```

- `SerialPortPOSIX.swift` (`#if canImport(Darwin) || canImport(Glibc)`):
  the existing implementation; `baud: Int` mapped to `B9600`/`B115200`.
- `SerialPortWindows.swift` (`#if os(Windows)`, `import WinSDK`):
  - open `\\.\COMn` with `CreateFileW(GENERIC_READ|GENERIC_WRITE, 0, nil,
    OPEN_EXISTING, 0, nil)`; `GetCommState`/`SetCommState` with `BaudRate`,
    `ByteSize 8`, `NOPARITY`, `ONESTOPBIT`, `fDtrControl =
    DTR_CONTROL_ENABLE`, `fRtsControl = RTS_CONTROL_ENABLE`, no flow control
    (matches the POSIX code's DTR and RTS assertion at
    `SerialPort.swift:142-143`);
  - `SetCommTimeouts` with `ReadIntervalTimeout = MAXDWORD`,
    `ReadTotalTimeoutMultiplier = MAXDWORD`, `ReadTotalTimeoutConstant = 50`
    so `ReadFile` returns within 50 ms, and loop until the terminator or the
    deadline like `readUntil` does today;
  - `WriteFile` synchronous; `PurgeComm(PURGE_RXCLEAR | PURGE_TXCLEAR)` for
    flush; `CloseHandle`.
  - Scanner: enumerate `HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM`
    with `RegOpenKeyExW` and `RegEnumValueW`; values are `COM3`, `COM7`, and
    so on. Present them through `MetricText.serialPortName` (§8.2); open
    with the `\\.\` prefix.
- `EQ6Mount` takes a `SerialPortDriver` (default: the platform driver) and
  `connect(path:baud:)` takes an `Int` baud; keep the `EQ6 TX/RX` logs
  through `Log.info` (§7.3) so they reach the file log in release builds.
- Keep the same probe order (SkyWatcher, SynScan, LX200) and timings. EQDIR
  adapters appear as FTDI or CH340 COM ports. Guide pulses are software
  timed (`EQ6Mount.swift:230,258`) and use `preciseSleep`.

### 10.2 Filter wheel

`POAPWNative` uses `DynamicLibrary` with `PlayerOnePW.dll`; the SDK API is
identical (verified: same header on all platforms). No other change. The
wheel has no simulator; hardware is the only test.

### 10.3 Tests and acceptance

- Unit: `windows com scanner parsing` (registry value names → paths) behind
  `#if os(Windows)`; a `ScriptedSerialPortDriver` test double that replays
  canned responses, with tests for `EQ6Mount.connect` probe order
  (SkyWatcher, then SynScan, then LX200, then `unrecognized`) and for pulse
  command sequences. The existing `lx200 pulse command`, `skywatcher hex24`,
  and centering tests cover the encoders.
- Manual on Windows without a telescope: a com0com virtual pair or a USB
  serial loopback to check that the scanner lists ports and `connect` fails
  with `unrecognized` rather than a crash.
- Hardware: on Windows connect an EQDIR or SynScan cable, run Calibrate and
  Center on an artificial star; filter wheel connect, alias read, goto. Same
  results as macOS. Unplug the camera during Center: mount work ends with
  the disconnect error (not `noStar` 4 s later), the mount stays connected,
  and Calibrate works after camera reconnect.

## 11. Milestone 5: packaging and documentation

### 11.1 macOS

- `package-app.sh`: also copy `libASICamera2.dylib` (universal) and
  `libusb-1.0.0.dylib` into `Contents/Frameworks`, `LICENSES/` into
  `Contents/Resources/LICENSES/`, and set `LSMinimumSystemVersion` 14.0.
- `package-portable-mac.sh`: bundle `CollimationCamera` with the relocated
  `libSDL3.0.dylib` (§9.2), the vendor dylibs, `Resources/Fonts/`,
  `AppIcon.icns`, and `LICENSES/`; an `Info.plist` that sets
  `CFBundleIconFile` to `AppIcon` and `NSHighResolutionCapable`, as
  `package-app.sh` does; add `-rpath @executable_path/../Frameworks`; ad-hoc
  codesign the dylibs and the bundle. The libusb license applies to the two
  macOS packages only.

### 11.2 Windows

`scripts/package-win.ps1`:

1. `swift build -c release --product CollimationCamera` (release links
   with `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`, so no console window,
   verified; release builds write to the log file of §9.5, debug builds also
   keep the console). The release link embeds `Resources\CollimationCamera.res`
   (generated by `fetch-sdk.ps1`), so the exe carries its own icon for
   Explorer, Start, and pinned shortcuts; the script fails early if the
   `.res` is missing.
2. Create `dist/CollimationCamera-win-x64/` with the exe, `SDL3.dll`,
   `PlayerOneCamera.dll`, `PlayerOnePW.dll`, `ASICamera2.dll`,
   `AppIcon-256.png`, `Resources/Fonts/`, `LICENSES/` (everything except
   `libusb-COPYING`), and `README-windows.txt` (driver installation before
   first launch, the VC++ redistributable, the log file location, a pointer
   to `LICENSES/`; nothing to add to `PATH`).
3. Copy the Swift runtime DLLs from
   `$env:LOCALAPPDATA\Programs\Swift\Runtimes\6.3.3\usr\bin` (or
   `C:\Program Files\Swift\Runtimes\...`). The set for 6.3.3 (verified from
   the installer manifest): `swiftCore, swiftCRT, swiftWinSDK,
   swift_Concurrency, swift_Differentiation, swift_RegexParser,
   swift_StringProcessing, swiftRegexBuilder, swiftDistributed,
   swiftObservation, swiftSynchronization, swiftSwiftOnoneSupport,
   BlocksRuntime, dispatch, swiftDispatch, Foundation, FoundationEssentials,
   FoundationInternationalization, FoundationNetworking, FoundationXML,
   _FoundationICU`. Copy all of them; an unused DLL is harmless. Do not link
   the runtime statically in this release (the 6.3.3 driver links the wrong
   registrar object for static builds, verified).
4. Install the Microsoft Visual C++ 2015-2022 redistributable on the target
   machine (documented in the README, not bundled). `PlayerOneCamera.dll`
   itself needs no CRT (statically linked, verified); SDL3.dll and
   ASICamera2.dll do.
5. Zip. Test on a clean Windows VM without Swift installed. Check the exe
   icon in Explorer and the window and taskbar icon while running.

### 11.3 CI: final shape

The workflow from §7.7, extended in §9.2, is complete by now; this is the
end state for reference:

```yaml
name: CI
on: [push, pull_request]
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        os: [macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v6
      - if: runner.os == 'Windows'
        uses: compnerd/gha-setup-swift@v0.4.1
        with: { swift-version: swift-6.3.3-release, swift-build: 6.3.3-RELEASE }
      - if: runner.os == 'Windows'
        uses: compnerd/gha-setup-vsdevenv@v6
      - if: runner.os == 'Windows'
        run: scripts/fetch-sdk.ps1 -SDL3Only
      - if: runner.os == 'macOS'
        run: brew install sdl3
      - name: Import guard
        shell: bash
        run: "! grep -rEn '^import (Combine|Darwin|AppKit|SwiftUI|Metal|MetalKit|ImageIO)' --exclude-dir=Platform --exclude='SerialPort*.swift' Sources/CollimationCore Sources/CollimationUI"
      - run: swift build --product core-tests
      - run: swift run core-tests
      - run: swift build --product capture-cli
      - run: swift build --product CollimationCamera
      - if: runner.os == 'macOS'
        run: swift build --product CollimationApp
```

### 11.4 Documentation

- README: platform matrix (macOS 14+, macOS 15+ for ZWO on Apple silicon,
  Windows 10 22H2+ x64), camera support, driver links and driver-first
  install order, build and run for each app, packaging, the `UserDefaults`,
  calibration file, and log file locations on each platform, and a
  troubleshooting section: Gatekeeper "Open Anyway" and `xattr -d
  com.apple.quarantine` for the unsigned macOS bundle, SmartScreen "More
  info → Run anyway" for the unsigned Windows zip, a "camera not listed"
  checklist (driver installed, cable, another app holding the camera, log
  file), and a "Third-party licenses" section with one row per component
  (SDL3, Dear ImGui, cimgui, Player One SDK, ZWO ASI SDK, libusb on macOS,
  DejaVu fonts, Swift runtime on Windows) pointing at `LICENSES/`.
- `Vendor/ZWO/README.md` and `Vendor/SDL3/README.md` like
  `Vendor/PlayerOne/README.md`, with the download sources of §5.2.
- `PARITY.md` complete.

## 12. Keeping the two UIs in sync

### 12.1 Working agreements

1. Every feature lands first in `CollimationCore` or `CollimationUI` with a
   test, then in both apps in the same pull request. A pull request that
   changes one app's behavior without the other is incomplete unless
   `PARITY.md` records a deliberate platform difference.
2. `CollimationCore` and `CollimationUI` never import a UI or platform
   framework. Platform code in the core lives only in
   `CollimationCore/Platform/` and `Mount/SerialPort*.swift`, guarded with
   `#if`. CI greps for these imports (§7.7).
3. UI code contains layout and input mapping only. Labels, tooltips, and
   enablement for buttons and toggles come only from `CommandCatalog`;
   sliders, pickers, and status rows are the only hand-laid sidebar items,
   and their text and predicates come from `MetricText`, `HelpText`, and
   the engine. If a view needs a formula, a predicate, or a string, it goes
   into the engine or `CollimationUI`. (A fully generic `SidebarModel` that
   both apps walk was considered and rejected: it would turn the SwiftUI
   sidebar into a form walker and lose per-row layout.)
4. HUD widgets are scenes (primitive lists). Adding a widget means a scene
   plus a test; each app renders it through its rasterizer.
5. Commands are declared once in `CommandCatalog`; no app defines its own
   menu items or shortcuts.
6. Shader changes: update the Metal, MSL, and HLSL sources and the
   equivalence test in the same commit.
7. CI must be green on both platforms before merge (milestone 0 spike
   branches are exempt because they never merge).
8. Bumping cimgui or imgui replaces `Sources/CImGui/vendor/` wholesale
   through `scripts/vendor-cimgui.sh`, updates `UPSTREAM.md`, and re-checks
   the generated names listed in §9.3 against the new `cimgui.h`. Never edit
   vendored files in place.

### 12.2 Pull request checklist

- [ ] Core or UI-model change has a test in `CoreTests`.
- [ ] Both apps updated, or `PARITY.md` explains the difference.
- [ ] `swift run core-tests` green on macOS and Windows (CI).
- [ ] Simulator smoke test on the portable app on macOS.
- [ ] Hardware note if capture, mount, or wheel code changed.
- [ ] A new vendored binary or library has its license text in `LICENSES/`
      and a README row.

### 12.3 `PARITY.md`

A table with one row per feature and columns macOS app, portable app,
notes. Initial rows: connect/disconnect, device list (POA, ZWO, simulators),
exposure and gain, auto exposure, auto stretch, MTF and arcsinh curves,
zoom and fit (wheel rule: one factor per event by sign), auto-center,
stabilize, search full frame, overlay and legend, ROI map, star profile,
histogram, compass dial, status chip, save TIFF, save stacked, save
constellation, mount connect, calibrate, center, filter wheel connect and
goto, keyboard shortcuts (Return connects on both), tooltips, error dialog,
log file, fonts (macOS: system SF and SF Mono; portable: bundled DejaVu),
remembered save folder, remembered serial port and wheel (per app on macOS),
settings location. The calibrate, center, search-full-frame, and connect-mount
rows carry a note that enablement is the engine's `can*` predicate on every
surface, tightened from the pre-port macOS menu.

## 13. Risks and fallbacks

| Risk | Signal | Fallback |
|---|---|---|
| `R16_UINT` storage read unsupported on a GPU | `SDL_GPUTextureSupportsFormat` false in the spike or at startup | `R16_UNORM` + `SAMPLER` nearest with `round(v * 65535)`, then `R32_FLOAT` storage read; last resort Win32 + D3D11 |
| SDL 3.4.x D3D12 needs Shader Model 6 for its blit shaders | Device creation fails on old hardware | Startup error box names the failed device creation and the log path (§9.5); README documents the requirement; SDL 3.6 removes it |
| Windows timer resolution quantizes sleeps to 15.6 ms | `engine.fps` 20 to 24 instead of 30 on Windows, guide pulses jitter, stacking slower than on macOS | `preciseSleep` in the capture loop and mount pulses (§7.3); `timeBeginPeriod(1)` on non-SDL paths (§6.2, `capture-cli`); spike task 6 numbers |
| Swift toolchain regression on Windows | CI red after a toolchain bump | Pin the toolchain version in CI and in the README; upgrade deliberately |
| Swift-on-Windows allocation or copy throughput below macOS (8 MB `[UInt16]` per grab at the 2048 ROI) | §6.1 task 5 or §9.8 fps below the macOS number | Reuse the grab-side pixel buffer first (the device already keeps `grabBuffer`); profile before considering pooled `Frame` storage |
| SDK `stopVideo`/`close` stall after device removal | Portable app freezes for seconds after unplug; second `stopVideo` overlaps the capture thread's after the 3 s timeout | Measured in milestone 1 (§7.5); fallback is the detached post-error `stop()` with `isClosing` gating `connect()` |
| ZWO RAW16 alignment differs on some model | Clipped pixels never paint red, or saturate at 4095 | Read `BitDepth` from `ASI_CAMERA_INFO` and shift left by `16 - BitDepth` in `grabFrame` when the max observed value stays below 4096 after a saturated exposure |
| `@Observable` and property observers interact badly with Swift 6 isolation | Compile errors in milestone 1 | Call the update functions from the setters' call sites instead of `didSet`, keeping the `init` ordering of §7.4 |
| SDK thread safety on Windows when closing during a blocked grab | Crash on disconnect | Already mitigated by `CaptureSession.stop()` order; keep `waitMs` slices short (200 ms) so the loop exits quickly |
| `UserDefaults` location on Windows is odd | Settings not found | Acceptable for now; a JSON settings file in `%LOCALAPPDATA%\Collimation Camera` can replace it later on both platforms |
| cimgui names drift from imgui | Build errors when bumping | §12.1 item 8; the shim is 40 lines |
| `SDL_GPUTextureFormat` constants disappear in a whole-module-optimized Windows build that also imports `WinSDK.DirectX` | `cannot find SDL_GPU_TEXTUREFORMAT_* in scope`, release only; the type itself still resolves | The formats the app names are re-exported from `Sources/CSDL3/shim.h` as typed constants (`CSDL3_TEXTUREFORMAT_*`); `-no-whole-module-optimization` also works but costs the optimization |
| Homebrew has no Intel-Mac bottle for `sdl3` | `brew install` builds from source on Intel Macs | Acceptable (non-goal); or use the SDL3 DMG's xcframework |
| Vendor download URLs change | `fetch-sdk` fails | Env-var overrides per file and the manual steps the scripts print |

## 14a. Milestone 0 spike results (Windows, 2026-09-09)

Measured by `Sources/SDLSpike` on branch `spike/sdl3-gpu`. Machine: Windows 11
Pro 26200, Intel Iris Xe integrated graphics, Swift 6.3.3, SDL 3.4.16, Dear
ImGui 1.92.9b. **The macOS half of the spike has not been run.**

**Gate: passed on this machine.** SDL3 GPU is viable; the Win32 + D3D11
fallback of §13 is not needed.

- **Toolchain (§6.1 task 3).** `CImGui` builds under SwiftPM on Windows:
  cimgui, the imgui subset, both backends, and `backends_shim.cpp` compile as
  one C++17 target, and `import CImGui` from Swift resolves `igBegin`,
  `igCreateContext`, `ImGui_ImplSDL3_InitForSDLGPU`, and `cimgui_sdlgpu3_init`.
  `SDL_GPUDevice` is the same type through `CSDL3` and `CImGui`. The umbrella
  header and macro split of §9.3 works exactly as written.
- **`igText` is unusable from Swift**: it is variadic, and Swift cannot import
  a variadic C function (`error: 'igText' is unavailable`). Every label must be
  formatted in Swift and drawn with `igTextUnformatted(text, nil)`. This
  applies to the whole portable app, not just the spike.
- **`SDL_CreateGPUTransferBuffer`** takes a pointer to a
  `SDL_GPUTransferBufferCreateInfo`; the struct cannot be written as a Swift
  array literal.
- **Texture formats (§6.2 gate).** Driver `direct3d12`, shader formats DXBC and
  DXIL, so Shader Model 6 is available. On Intel Iris Xe:

  | Format and usage | Supported |
  |---|---|
  | `R16_UINT` + `GRAPHICS_STORAGE_READ` | yes |
  | `R16_UNORM` + `SAMPLER` | yes |
  | `R32_FLOAT` + `GRAPHICS_STORAGE_READ` | yes |
  | `R32_FLOAT` + `SAMPLER` | yes |

  The primary path works; no fallback is needed on this hardware.
- **Upload rate (§6.1 task 3).** A 2048×2048 `R16_UINT` storage-read texture
  re-uploaded every frame through a transfer buffer with `cycle: true`, with
  the ImGui demo window drawing on top: **steady 60.0 fps, 16.65 ms per frame,
  0.5 to 0.9 ms of it upload**. Vsync-bound, with headroom.
- **Timer resolution (§6.1 task 6).** Median of five, in milliseconds:

  | Call | Before `SDL_Init` | After `SDL_Init` |
  |---|---|---|
  | `Thread.sleep(0.0002)` | 15.867 | 0.956 |
  | `Thread.sleep(0.0333)` | **47.655** | 33.596 |
  | `preciseSleep(200 µs)` | 0.650 | 0.671 |
  | `preciseSleep(33333 µs)` | 33.533 | 33.642 |

  This confirms §7.3 exactly, including the predicted failure: a 33 ms pacing
  sleep phase-locks to about 47 ms without `timeBeginPeriod`, which is a 21 fps
  live view instead of 30. `preciseSleep` is correct with or without SDL, which
  is what `capture-cli` needs since it never calls `SDL_Init`.

Still open, and needing hardware or a Mac: the macOS side of tasks 3 and 4
(Metal, MSL, Retina, trackpad pinch), the Windows precision-touchpad pinch, the
compute-pass reduction, `SDL_ShowSimpleMessageBox` before `SDL_Init`, and task 5
(camera frame rates).

## 14b. Milestone 3 to 5 acceptance, checked on Windows (2026-09-09)

Same machine as §14a: Windows 11 Pro 26200, Intel Iris Xe, Swift 6.3.3,
SDL 3.4.16, Dear ImGui 1.92.9b. Everything here was run; anything not listed
was not.

- **The portable app runs against the simulator.** Menu bar, sidebar with all
  six sections, live view with the donut through the HLSL stretch shader, the
  overlay and legend, the ROI map, the star profile, the histogram, the
  compass dial, the status chip, and the zoom and fps readout. Confirmed from
  a screen capture of the window at 2560×1640 (200% scale).
- **Point scale.** `SDL_GetWindowDisplayScale` 2.0 and
  `SDL_GetWindowPixelDensity` 1.0 at 200%, so window coordinates are pixels
  and the style scales by 2. The live region works out to 980×795 points
  beside a 300-point sidebar, which is what the engine is given.
- **The live texture.** R16_UINT storage read, 512×512 while tracking and
  2048×2048 on the first full frame, uploaded through a cycled transfer
  buffer inside the same command buffer that draws it.
- **The window icon** loads from `Resources/AppIcon-256.png` through
  `SDL_LoadPNG` and shows in the title bar.
- **The release build is a GUI subsystem image** (PE subsystem 2; the debug
  build is 3) and carries two icon resources, so Explorer and Start show the
  app icon.
- **The package runs on its own.** `dist\CollimationCamera-win-x64.zip`
  unzipped into a fresh directory outside the repository starts, finds its
  fonts and the vendor DLLs beside the executable, and logs — with no Swift
  toolchain on `PATH`.
- **Pacing is not quantized any more.** `capture-cli --frames` measures the
  grab rate without a window, and measuring it found the simulator pacing
  itself with `Thread.sleep`: its 12.5 ms wait rounded up to 15.6 ms, capping
  it at 62.5 fps. With `preciseSleep` and `timeBeginPeriod(1)` in the tool it
  runs at 77.5 fps against an 80 fps cap, interval 12.9 ms. The apps were not
  affected — `SDL_Init` raises the resolution — but the core no longer depends
  on that. §7.3's risk, seen and closed on the simulator; the camera side of
  it still needs hardware.
- **`capture-cli` works on Windows.** `--list` reports both SDK versions and
  the two simulators; `--simulator --output frame.tif` writes a valid
  little-endian 16-bit TIFF whose donut, stretched with the same black point
  and midtones the app uses, matches what the live view shows.
- **All three vendor libraries load.** `CollimationCamera --check` reports
  Player One camera 3.10.1, ZWO 1.41, and Player One filter wheel 1.2.3.0
  through `DynamicLibrary`, and lists COM3 from the registry scanner. No
  camera or wheel was attached, so only the load path is confirmed.
- **Frame rate against the simulator.** The log now carries a heartbeat line a
  minute. The packaged release runs at 72 to 77 fps with a 2048 ROI, the full
  analysis pipeline, and the HUD; the debug build runs at 14 to 17, which is
  `-Onone` in the analysis code and in the simulator's own frame synthesis, not
  the renderer. Never judge the port's speed from a development build. §9.8's
  30 fps figure is about a camera and still needs one.
- **Minimize, restore, and resize do not stall it.** `window-stress-win.ps1`
  minimizes the window for ten seconds, restores it, and resizes it from
  700×500 to 2400×1500 and back, checking after each step that the window
  still answers messages. It passes on the packaged release and on a
  development build. The fps recovery number of §9.8 still needs the UI in
  front of somebody.
- **A 200-second soak of the packaged release** against the simulator holds
  steady: working set oscillates between 94 and 104 MB with no trend, private
  bytes 80 to 90 MB, handle count 336 to 344. Nothing leaks over that window.
  CPU runs at about 1.3 cores, which is the simulator synthesizing a
  6252×4176 sensor frame per grab rather than the render loop; measure it
  again with a real camera before reading anything into it.
- **A failed GPU device is reported, not swallowed.** With
  `SDL_GPU_DRIVER=vulkan` on this machine the release build logs
  `FATAL SDL_CreateGPUDevice: SDL_HINT_GPU_DRIVER vulkan unsupported!` and
  blocks on the message box naming the step and the log path (§9.8).
- **Two release-only traps found and fixed**, both recorded in §13: the
  trapping `FileHandle.write(_:)` on a subsystem-Windows process with no
  standard output, and whole-module optimization losing the
  `SDL_GPU_TEXTUREFORMAT_*` constants when `WinSDK.DirectX` is in the module.

Still open on Windows, and needing hardware: every camera, mount, and filter
wheel item in §7.8, §9.8, and §10.3 — nothing has been plugged in. Still open
everywhere else: the whole macOS side, including the portable app's first run
there and §9.8's screenshot comparison between the two apps.

## 14. Verified facts and sources

Checked on 2026-09-08 against primary sources. Items marked "spike" are to
be confirmed in milestone 0.

**Swift on Windows**
- Swift 6.3.3 is the current Windows release (x64 and arm64 installers);
  requires VS 2022 MSVC v143 and a Windows 11 SDK. https://www.swift.org/install/windows/
- SwiftPM builds C and C++ targets with the toolchain's clang; GNU-style
  flags; `.linkedLibrary` maps to `-l`. WinSDK module map autolinks User32,
  AdvAPI32, Ole32; Direct3D and `D3DCompile` need `import WinSDK.DirectX`
  (`stdlib/public/Platform/winsdk_um.modulemap`).
- `import WinSDK` covers `CreateFileW`, `SetCommState`, `SetCommTimeouts`,
  `EscapeCommFunction`, `RegOpenKeyExW`, `RegEnumValueW`, `LoadLibraryW`,
  `GetProcAddress`, `SetProcessDpiAwarenessContext`,
  `CreateWaitableTimerExW`.
- No per-platform target exclusion in SwiftPM (SE-0236, SE-0273); `#if os()`
  in `Package.swift` is host-evaluated. `unsafeFlags` restrict the package
  to root use (SE-0238). Linker-only flags need `-Xlinker` each. A Swift
  target that depends on a C target receives only `-fmodule-map-file` and
  `-I <include>`, never the C target's defines
  (`BuildPlanSwift.swift`). SwiftPM compiles only files under a target's
  `path`; `sources:` filters that walk (`TargetSourcesBuilder.swift`).
  Manifest evaluation is cached on manifest text, tools version, and
  environment (`ManifestLoader.swift`).
- SwiftPM's librarian lookup on Windows: `AR`, else `-use-ld=`, else `link`
  on `PATH`; failure reads `could not find CLI tool 'link'`.
- GUI subsystem: `.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker",
  "/ENTRY:mainCRTStartup"])` (forums.swift.org thread 53349; used by
  The Browser Company's windows-samples and Painst2005/SwiftSurvivor).
- `lld-link` fails on ReFS/Dev Drive with 6.3.x: https://github.com/swiftlang/swift/issues/88961
- Runtime DLL list for 6.3.3: swift-installer-scripts `rtl/legacy/lib/rtllib.wxs`.
- Static stdlib on Windows exists in the Experimental SDK but the 6.3.3
  driver links the wrong registrar object; do not use `-static-stdlib`.
- Foundation on Windows: `UserDefaults` → `%LOCALAPPDATA%\<name>.plist`;
  `applicationSupportDirectory` → `%LOCALAPPDATA%`; `String(format:)`,
  `DateFormatter`, `JSONEncoder`, `NSLock`, `DispatchQueue.concurrentPerform`
  all implemented. `Thread.sleep(forTimeInterval:)` on Windows is
  `CreateWaitableTimerW` + `SetWaitableTimer` + `WaitForSingleObject` with
  no high-resolution flag and no `timeBeginPeriod` (swift-corelibs-foundation
  release/6.3 `Thread.swift`); accuracy equals the process timer resolution.
  Spike: measured sleep durations (§6.1 task 6).
- Observation ships in the Windows toolchain (`swiftObservation.dll`; macros
  since Swift 5.9.1).
- Main actor: jobs are enqueued on the libdispatch main queue
  (`DispatchGlobalExecutor.cpp`, `PlatformExecutorWindows.swift`);
  `RunLoop.main.limitDate(forMode:)` and `run(mode:before:)` drain it on the
  main thread (`CFRunLoop.c` with `_dispatch_main_queue_callback_4CF`);
  `dispatch_main()` on Windows calls `_endthreadex`. `Thread.isMainThread`
  is false inside `@MainActor` on Windows: https://github.com/swiftlang/swift-corelibs-libdispatch/issues/846
- Bessel: ucrt exports `_j1`; the POSIX name `j1` imports as deprecated.
  The plan uses a pure Swift `j1` instead.
- C `long` is 32-bit on Windows; C enums import as `Int32` on Windows and
  `UInt32` elsewhere (forums.swift.org thread 60547).
- `@Published` emits in `willSet`; property observers on `@Observable`
  properties fire for assignments made in methods called from `init`.

**ZWO ASI SDK 1.41** (https://www.zwoastro.com/software/product-sdk/, `ASICamera2.h`)
- Windows: `ASI SDK/lib/x64/ASICamera2.dll`; macOS: `lib/mac` (i386 +
  x86_64) and `lib/mac_arm64` (arm64, `LC_BUILD_VERSION` minos 15.0), both
  dynamically linking `libusb-1.0.0.dylib` which is not bundled; arm64
  hard-codes `/opt/homebrew/opt/libusb/lib/`.
- ROI: `iWidth % 8 == 0`, `iHeight % 2 == 0`, ASI120 `iWidth*iHeight % 1024 == 0`;
  sizes are post-binning. `ASISetROIFormat` requires capture stopped;
  `ASISetStartPos` may be called while streaming.
- `ASIGetVideoData(id, buf, size, waitms)` blocks up to `waitms`;
  `ASI_ERROR_TIMEOUT` when no frame; recommended wait `exposure*2 + 500 ms`.
- RAW16 is MSB-aligned (12-bit × 16, max 65520): ZWO forum answers and
  SharpCap reports; not in the header. Verify on hardware in milestone 1.
- `ASI_EXPOSURE` in microseconds; `ASI_BANDWIDTHOVERLOAD` range from control
  caps (typically 40 to 100); `ASI_HIGH_SPEED_MODE` selects 10-bit ADC.
- Windows needs the ZWO native driver (V3.28); macOS needs none. License is
  MIT-style and allows redistribution. Download: `dl.zwoastro.com`
  redirect with a short-lived signed URL.
- Error codes: `ASI_SUCCESS=0, INVALID_INDEX=1, INVALID_ID=2,
  INVALID_CONTROL_TYPE=3, CAMERA_CLOSED=4, CAMERA_REMOVED=5, INVALID_PATH=6,
  INVALID_FILEFORMAT=7, INVALID_SIZE=8, INVALID_IMGTYPE=9,
  OUTOF_BOUNDARY=10, TIMEOUT=11, INVALID_SEQUENCE=12, BUFFER_TOO_SMALL=13,
  VIDEO_MODE_ACTIVE=14, EXPOSURE_IN_PROGRESS=15, GENERAL_ERROR=16,
  INVALID_MODE=17, GPS_*=18..22, END=23`.

**Player One SDK 3.10.1 and filter wheel 1.2.3** (https://player-one-astronomy.com/service/software/)
- Windows zips have direct URLs under
  `https://player-one-astronomy.com/download/softwares/` and contain
  `lib/x64/PlayerOneCamera.dll` (filter wheel `PlayerOnePW.dll`). Header
  byte-identical to the macOS one. DLL imports only SETUPAPI, USER32,
  KERNEL32 (static CRT). Separate kernel driver required on Windows.
- `POA_FRAME_LIMIT` range [0, 2000], 0 = no limit. `POA_USB_BANDWIDTH_LIMIT`
  range from attributes, default 100.
- macOS dylibs are universal and reference `@rpath/libusb-1.0.0.dylib`.
- No thread-safety documentation; INDI joins the capture thread before
  `POAStopExposure` and `POACloseCamera`, as this code does.

**SDL3 3.4.16** (https://github.com/libsdl-org/SDL/releases/tag/release-3.4.16, `include/SDL3/SDL_gpu.h`)
- Stable GPU backends: Vulkan, Direct3D 12, Metal. The D3D11 GPU backend was
  removed before 3.2.0 (PR #11456). D3D12 needs Windows 10, feature level
  11_0, resource binding tier 2 (tier 1 admitted by
  `SDL_PROP_GPU_DEVICE_CREATE_D3D12_ALLOW_FEWER_RESOURCE_SLOTS_BOOLEAN` when
  the app uses 8 or fewer storage resources). Metal needs macOS 10.14 and an
  Apple silicon or Intel Mac2-family GPU.
- Shader formats: Vulkan SPIR-V only; D3D12 DXBC (SM 5.1) always and DXIL
  when the device reports SM 6; Metal MSL source (compiled at runtime with
  `newLibraryWithSource:`) and metallib. The D3D12 backend only checks the
  `DXBC` fourcc and passes the blob to the pipeline. SDL's own D3D12 blit
  shaders are DXIL in 3.4.x (fixed on main for 3.6). Root-signature mismatch
  with SM 5.0 DXBC: issue #11458.
- `SDL_GPU_TEXTUREFORMAT_R16_UINT` exists; integer formats cannot have
  `SAMPLER` usage, and `SAMPLER` cannot combine with `GRAPHICS_STORAGE_READ`
  (`src/gpu/SDL_gpu.c` debug validation). Read-only storage textures are
  SRVs (`Texture2D` + `Load`) in D3D12 and sampled images in Vulkan.
  `SDL_GPUTextureSupportsFormat` queries per-device support. `R16_UNORM` is
  not on the universal `SAMPLER` list; `R32_FLOAT` is universal for both
  `SAMPLER` and storage.
- Binding conventions (`SDL_CreateGPUShader` and
  `SDL_CreateGPUComputePipeline` docs): graphics HLSL vertex `t/s space0`,
  `b space1`; pixel `t/s space2`, `b space3`; compute `t/s space0`,
  `u space1`, `b space2`. MSL: `[[texture]]` sampled then storage,
  `[[buffer]]` uniforms then storage; vertex buffers from `[[buffer(14)]]`.
- Upload: transfer buffer, `SDL_MapGPUTransferBuffer(cycle)`, copy pass,
  `SDL_UploadToGPUTexture(cycle)`; D3D12 prefers 256-byte row pitch. Copy
  passes cannot run inside render or compute passes. Compute: storage
  buffers, `SDL_DownloadFromGPUBuffer`, fences.
- Coordinates: +Y down for textures, NDC handled per backend by SDL.
- Windowing: `SDL_WINDOW_HIGH_PIXEL_DENSITY`; `SDL_GetWindowSize` (window
  units), `SDL_GetWindowSizeInPixels`, `SDL_GetWindowDisplayScale`,
  `SDL_GetWindowPixelDensity`, `SDL_GetDisplayContentScale`; Windows reports
  pixels with display scale, macOS reports points. SDL sets per-monitor-v2
  DPI awareness itself on Windows.
- Timer: `SDL_InitTicks` registers `SDL_HINT_TIMER_RESOLUTION` (default "1")
  whose callback calls `timeBeginPeriod(1)` on Windows; runs from
  `SDL_InitMainThread` for any `SDL_Init` flags (`src/timer/SDL_timer.c`,
  `src/SDL.c`). `SDL_DelayNS` itself uses
  `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`.
- Input: `SDL_MouseWheelEvent.x/y` are floats; `SDL_EVENT_PINCH_*` with
  `scale` since 3.4.0 (macOS and Wayland only; no Windows backend).
  `SDL_KMOD_CTRL`, `SDL_KMOD_GUI`. Spike: Windows precision touchpad pinch
  as Ctrl + wheel.
- Dialogs: `SDL_ShowSaveFileDialog(callback, userdata, window, filters,
  nfilters, default_location)`, native on both platforms; callback on a
  worker thread on Windows, on the main thread on macOS; `filters` must
  outlive the call.
- Images and icons: `SDL_LoadPNG`, `SDL_LoadPNG_IO`, `SDL_SavePNG` since
  3.4.0 (`SDL_surface.h`). `SDL_SetWindowIcon` converts the surface to
  ARGB8888 (`SDL_video.c`); the Windows backend sends `WM_SETICON`
  `ICON_SMALL` and `ICON_BIG`; the Cocoa backend calls
  `setApplicationIconImage`. Neither sets the executable's own icon; that
  needs an `RT_GROUP_ICON` resource compiled from an `.rc` with `rc.exe`
  and linked as a `.res`.
- Entry point: `SDL_main.h` is not included by `SDL.h`; `SDL_Init` works
  from a plain `main` on Windows and macOS without `SDL_SetMainReady`.
  `SDL_Init` must run on the main thread. `SDL_SetAppMetadata` sets the
  app name shown by macOS for unbundled runs.
- Spike: `SDL_ShowSimpleMessageBox` before `SDL_Init` and with a `nil`
  window; `SDL_SetLogOutputFunction` replaces SDL's default output (stderr
  plus `OutputDebugString` on Windows).
- SwiftPM: `SDL_DECLSPEC` is empty for consumers (no `dllimport`);
  `SDL_WINDOW_*` flags are `SDL_UINT64_C` macros Swift cannot import;
  `link "SDL3"` → `/DEFAULTLIB:SDL3.lib`; pkg-config `sdl3` from Homebrew on
  macOS. Homebrew rewrites install names to `/opt/homebrew/opt/sdl3/...`.
  Reference projects: JackPilley/SwiftWindowsSDLTemplate,
  Painst2005/SwiftSurvivor, navjack/Codexitma, gay-pizza/SDL3Swift.

**Dear ImGui 1.92.9b and cimgui**
- SDL3 platform backend: `ImGui_ImplSDL3_InitForSDLGPU`, `ProcessEvent`,
  `NewFrame`, `Shutdown`; it fills `io.DisplaySize` and
  `io.DisplayFramebufferScale` every frame but does not handle content
  scale or `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`.
- SDLGPU3 renderer backend (since 1.91.7): `InitInfo{Device,
  ColorTargetFormat, MSAASamples, SwapchainComposition, PresentMode}`,
  `PrepareDrawData` mandatory before the render pass, `RenderDrawData(draw,
  cmd, pass, pipeline = nullptr)`; picks DXBC on `direct3d12`, MSL or
  metallib on Metal; supports `RendererHasTextures`.
- cimgui master tracks imgui 1.92.9b; `cimgui.cpp` includes `imgui.h` then
  `cimgui.h`; `cimgui.h` guards its C block with a bare `#ifdef
  CIMGUI_DEFINE_ENUMS_AND_STRUCTS`; cimgui's own builds put that macro and
  `CIMGUI_USE_*` only on C consumers. Committed `cimgui_impl.h` wraps
  `CIMGUI_USE_SDL3` but not SDLGPU3; the generator strips default member
  initializers, so C callers zero-fill structs. Function names verified:
  `igGetBackgroundDrawList_Nil`, `igIsKeyChordPressed_Nil`, `igShortcut_Nil`,
  `igPushFont`, `ImGuiStyle_ScaleAllSizes`, `ImDrawList_AddLine`,
  `ImDrawList_AddCircle`, `ImDrawList_AddText_Vec2`,
  `ImDrawList_AddText_FontPtr`.
- ImGui 1.92 dynamic fonts: `style.FontSizeBase`, `style.FontScaleDpi`,
  `style.ScaleAllSizes`; fonts load once; `AddText(font, size, …)` takes the
  scaled size. Embedded ProggyClean covers U+0000 to U+00FF and U+20AC only;
  missing glyphs draw as "?". `ImGuiMod_Ctrl` means Cmd on macOS;
  `ImGuiMod_Super` means Ctrl on macOS.
- Swift C++ interop with ImGui on Windows is fragile (static
  `swiftCxxStdlib`, header generation bugs); cimgui's C API avoids it.

**CI**
- `compnerd/gha-setup-swift` v0.4.1 installs Swift on `windows-latest`;
  Swift ≥ 6.1 needed there. https://github.com/compnerd/gha-setup-swift
  Hosted Windows runners have MSVC tools off `PATH`; Git's coreutils
  `link.exe` satisfies SwiftPM's librarian lookup by accident, so
  `compnerd/gha-setup-vsdevenv` is the insurance.
