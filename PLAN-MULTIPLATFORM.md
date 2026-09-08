# Collimation Camera — multiplatform plan (high level)

Status: draft for approval, 2026-09-08. A detailed plan follows once the
decisions at the end are made.

## Goal

Make the app multiplatform: a Windows UI next to the existing macOS SwiftUI
app, ZWO and Player One cameras on both platforms, readout as fast as today
(30 fps live cap, unlimited readout for stacking, 16-bit GPU stretch, GPU
centroid for stabilization), and a structure that keeps both UIs in sync as
development continues.

## Recommendation

Keep the core in Swift, make it build on Windows, and add a second UI that is
itself cross-platform (Swift + Dear ImGui). Both UIs render from a new shared
UI-model layer.

The Windows-specific claims in this plan were checked against primary sources:
the Swift 6.3.3 toolchain, libdispatch and Foundation source, and the ZWO 1.41
and Player One 3.10.1 SDK headers. See "Sources checked" at the end.

## Options weighed

| Option | Pros | Cons |
|---|---|---|
| **A. Swift core + Swift/ImGui second UI** (recommended) | No rewrite. 12k lines and 62 tests carry over. One language. The second UI also runs on macOS, so you develop it on the Mac and only test on Windows. | Swift-on-Windows tooling is younger: debugging, runtime DLL packaging. ImGui does not look native. |
| **B. Rewrite core in C++** | Best Windows tooling. Camera SDKs and ImGui are C/C++. | Rewrite about 10k lines plus tests. The macOS app needs a C bridge. The engine's async logic gets redone. |
| **C. Rewrite core in Rust** | Memory safety, cargo, and wgpu/egui could give one UI everywhere. | Full rewrite. Swift-to-Rust bridging for the macOS app. Two languages maintained by one person. |
| **D. One cross-platform UI replacing SwiftUI** | The sync problem disappears. | Discards the working macOS app. Option A keeps this open as a later choice. |

Why A holds up: the Apple-only surface in `CollimationCore` is small. It is two
dlopen loaders, the POSIX serial port, `usleep`, one Bessel function, and
Combine in the engine. Everything else has verified Windows code paths.

Combine has no maintained Windows port, so the engine moves to the Observation
framework (`@Observable`), which ships in the Windows toolchain. That raises the
macOS minimum from 13 to 14. The fallback is a small property-wrapper shim that
keeps macOS 13.

## Facts that shaped the design

- **Main actor on Windows.** `@MainActor` jobs land on the libdispatch main
  queue. A frame-paced loop that drains it each frame through `RunLoop.main`
  is enough. No private symbols are needed.
- **ZWO SDK 1.41.** ROI width must be a multiple of 8 and height a multiple
  of 2. The ROI position can move while streaming, so tracker recentering
  needs no stream restart. Size changes need stop and start. RAW16 is
  MSB-aligned like Player One, so the existing clip threshold applies. The
  macOS dylib is not universal and needs a bundled libusb. Windows needs
  ZWO's native driver.
- **Player One 3.10.1.** The C header is byte-identical on all platforms.
  Windows uses `PlayerOneCamera.dll` and `PlayerOnePW.dll` plus Player One's
  kernel driver. `POA_FRAME_LIMIT` 0 means unlimited, as the code assumes.
- **SwiftPM.** There is no per-platform target exclusion. Platform-specific
  targets are guarded with `#if os()` in `Package.swift` and built with
  `swift build --product`.
- **Windows runtime.** Ship the Swift runtime DLLs beside the executable.
  Static linking of the runtime is not reliable in Swift 6.3.3 on Windows.

## Keeping the two UIs in sync

1. **The engine stays the only view model.** Remaining UI-side logic moves
   into it: enablement rules, status and metric text, the remembered save
   folder.
2. **A new platform-free UI-model module** holds:
   - a command catalog: menu items, shortcuts, enablement predicates;
   - the text formatters for metrics and status;
   - the HUD widgets as primitive lists (crosshair, circle, polyline, label):
     overlay, ROI map, star profile, histogram, compass dial.
   SwiftUI Canvas and ImGui each get a short rasterizer for the primitives. A
   feature added to the catalog appears in both apps, and a missing primitive
   case fails to compile.
3. **One documented stretch formula.** A test checks each GPU shader against
   the CPU function `StretchParams.apply`.
4. **CI matrix** on macOS and Windows builds both apps and runs the core tests
   on both. A parity checklist in the repo is updated with each feature.

## Milestones

0. **Spike, about a week.** Core and tests build on Windows with Swift 6.3.
   SDL3 + ImGui hello world with a 16-bit texture and a compute pass. Gate: if
   SDL3's GPU API disappoints, the Windows build falls back to Win32 +
   Direct3D 11.
1. **Core portability.** Observation refactor, ZWO support on both platforms,
   Player One and filter-wheel DLL loading on Windows, capture-cli writes
   TIFF instead of PNG.
2. **Shared UI-model module.** The macOS app is refactored onto it with no
   behavior change.
3. **ImGui app.** Live view with GPU stretch and centroid, sidebar, HUD,
   menus and shortcuts, save dialogs.
4. **Mount serial port on Windows**, filter wheel, full feature parity.
5. **Packaging, CI, README.** Windows zip with Swift runtime and SDK DLLs.
   macOS bundle gains ZWO and libusb.

## Decisions needed

1. Approve option A, or explore B or C in depth instead?
2. Is a macOS 14 minimum acceptable? Otherwise the plan uses the shim.
3. Are mount and filter wheel on Windows in scope for the first release?
4. Second UI portable via SDL3, or Windows-only via Win32 + Direct3D 11?
   Recommendation: portable, confirmed by the spike.

## Sources checked

- Swift on Windows: https://www.swift.org/install/windows/ and
  https://forums.swift.org/t/towards-static-stdlib-support-on-windows/77728
- Main-queue draining on Windows: swift-corelibs-libdispatch `src/queue.c`,
  swift-corelibs-foundation `CFRunLoop.c`, and
  https://github.com/swiftlang/swift-platform-executors
- SwiftPM platform handling: SE-0236 and SE-0273
- Observation on Windows: `stdlib/public/Observation` CMake lists and
  `utils/build.ps1` in swiftlang/swift
- ZWO ASI SDK 1.41: `ASICamera2.h` and https://www.zwoastro.com/software/product-sdk/
- Player One SDK 3.10.1: `PlayerOneCamera.h` and
  https://player-one-astronomy.com/service/software/
- Dear ImGui and cimgui: https://github.com/cimgui/cimgui and
  https://github.com/ocornut/imgui/blob/master/docs/FAQ.md
- GitHub Actions for Swift on Windows: https://github.com/compnerd/gha-setup-swift
