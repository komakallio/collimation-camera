# Collimation Camera — Implementation Plan

A macOS application for telescope collimation against an artificial star, using a
Player One camera (target: Poseidon-M). The user defocuses the star into a donut;
the app shows a live, GPU-rendered view and computes a numeric coma metric
(magnitude + direction) from the donut's asymmetry.

## Decisions made

| Topic | Decision |
|---|---|
| Stack | Swift + SwiftUI + Metal, native macOS app |
| Camera SDK | Official Player One Camera SDK for macOS (C library `libPlayerOneCamera.dylib`) |
| Architecture | Universal binary (Apple Silicon + Intel) |
| Star analysis | Defocused star (diffraction donut): ring concentricity + annulus intensity asymmetry |
| Scope v1 | Live view + analysis only (no snapshots, no metric history, minimal camera controls: exposure/gain) |

## Architecture

Four layers, each isolated behind a small interface:

```
┌───────────────────────────────────────────────┐
│ UI (SwiftUI)                                  │
│  live view window · controls sidebar · overlay│
├───────────────────────────────────────────────┤
│ Rendering (Metal / MTKView)                   │
│  16-bit texture upload · stretch shader · zoom│
├───────────────────────────────────────────────┤
│ Processing (Swift + Accelerate)               │
│  histogram/auto-stretch · star detection ·    │
│  ROI tracking state machine · coma analysis   │
├───────────────────────────────────────────────┤
│ Capture (Swift wrapper over C SDK)            │
│  POACamera bindings · frame loop thread ·     │
│  ROI/exposure/gain control · reconnect        │
└───────────────────────────────────────────────┘
```

### 1. Capture layer

- **SDK integration**: SPM target with a C `module.modulemap` exposing `PlayerOneCamera.h`.
  The dylib is bundled in the app (`Frameworks/`, rpath-linked) so the app is
  self-contained. No kernel driver is needed on macOS; the SDK talks USB directly.
- **`POACameraDevice`** Swift class wrapping the C API: enumerate, open/close,
  get/set exposure, gain, image format (RAW16 preferred, RAW8 fallback), ROI
  (`POASetImageStartPos` / `POASetImageSize`), binning for full-frame search.
- **Frame loop**: a dedicated background thread runs the SDK's video-stream mode
  (`POAStartExposure` continuous + `POAGetImageData` polling). Frames land in a
  small recycled buffer pool (3 buffers, 16-bit grayscale) and are handed to the
  processing layer without copies. Latest-frame-wins; no queuing.
- **ROI changes** require stopping/restarting the stream — the frame loop owns
  this so callers just request "move ROI to (x, y, w, h)" and get a seamless switch.
- **Simulator device**: an alternate `CameraDevice` implementation that renders a
  synthetic defocused star (donut with configurable coma, drift, noise, seeing
  wobble). All development and testing of tracking/analysis works without hardware.

### 2. Processing layer

Runs on the frame-loop thread (cheap per-frame work) plus Accelerate/vImage where useful.

- **Histogram** (256-bin over 16-bit range) each frame — feeds auto-stretch and the UI.
- **Auto-stretch**: black point at ~0.1 percentile, white point at ~99.9 percentile,
  midtones gamma from median (same idea as astro "STF" auto-stretch). One button;
  results populate the manual sliders so the user can fine-tune from there.
- **Star detection**:
  - In-ROI: background estimate (median), threshold at background + k·σ, largest
    connected blob, intensity-weighted centroid.
  - Full-frame search: switch to max ROI with 2×2 or 4×4 binning for speed, same
    detection, then compute the unbinned sensor position and re-center the ROI.
- **Tracking state machine**:
  - `TRACKING`: star found in ROI. If centroid drifts more than ~15% of ROI size
    from center, move the ROI on the sensor to re-center (hysteresis + rate limit
    so the view doesn't chatter).
  - `LOST` (no star for N consecutive frames): switch to full-frame search.
  - `SEARCHING`: full-frame binned capture until a star is found, then back to
    `TRACKING` with the ROI centered on it. UI shows the current state.
- **Coma analysis** (defocused donut), computed per frame on the ROI:
  1. Segment the donut: threshold, keep the largest blob.
  2. **Outer boundary**: circle fit (least squares) to the outer edge → center O, radius R.
  3. **Inner hole**: centroid of the dark region inside the blob (secondary shadow)
     → center I, radius r.
  4. **Concentricity vector** `C = I − O`: direction = coma direction, magnitude
     reported both in pixels and normalized as `|C| / (R − r)` (fraction of the
     annulus width) so it's comparable across defocus amounts.
  5. **Intensity asymmetry**: mean brightness in 16 angular sectors of the annulus;
     report peak-to-peak variation and the phase of the 1st Fourier harmonic
     (should agree with the concentricity direction; a robust second opinion).
  - Output smoothed with a short exponential moving average to tame seeing/noise.

### 3. Rendering layer

- **MTKView** with a fragment shader doing the stretch on the GPU: the raw frame is
  uploaded as an `r16Uint` texture and the shader applies black/white point + gamma
  per pixel. Upload is the only per-frame CPU cost; all scaling/stretching is GPU.
- **Zoom**: 25% – 800% by scaling the textured quad; nearest-neighbor sampling at
  ≥100% (pixel-accurate for judging rings), linear below. Scroll/pinch to zoom,
  fit-to-window button.
- **Overlay** (drawn in a second pass or SwiftUI canvas on top): crosshair at ROI
  center, fitted outer/inner circles, coma vector arrow scaled for visibility,
  tracking-state indicator.

### 4. UI layer (SwiftUI)

Single window:

- **Left / main**: live view (Metal) with overlay, zoom control.
- **Right sidebar**:
  - Camera: device picker (incl. Simulator), connect/disconnect, exposure, gain.
  - ROI: size picker (e.g. 128 / 256 / 512 / 1024 / full), auto-center toggle.
  - Stretch: black point, white point, gamma sliders + histogram strip + **Auto** button.
  - Collimation readout: coma magnitude (normalized + pixels), direction (degrees,
    plus a compass-style dial matching the overlay arrow), sector-asymmetry value,
    signal quality indicator (SNR / "star lost").

## Project structure

```
collimation-camera/
├── Package.swift                     # SPM; app built via Xcode project or xcodegen
├── Sources/
│   ├── POACameraC/                   # C SDK headers + modulemap
│   ├── CollimationCore/              # capture, processing, analysis (UI-free, testable)
│   │   ├── Camera/                   # CameraDevice protocol, POA impl, Simulator impl
│   │   ├── Pipeline/                 # frame loop, buffer pool, histogram, stretch math
│   │   ├── Tracking/                 # detection, state machine, ROI controller
│   │   └── Analysis/                 # donut segmentation, circle fits, coma metric
│   └── CollimationApp/               # SwiftUI app, MTKView wrapper, shaders (.metal)
├── Tests/CollimationCoreTests/       # unit tests vs. synthetic frames
└── Vendor/PlayerOne/                 # SDK dylib + headers (downloaded, not committed if license unclear)
```

`CollimationCore` has no UI dependencies, so detection, tracking, and coma math are
unit-tested against synthetic images with known ground truth (inject a donut with
coma X at angle θ → assert the metric recovers it within tolerance).

## Milestones

1. **Scaffolding + SDK bring-up** — repo layout, download/vendor the macOS SDK,
   C bindings, enumerate + open the Poseidon-M, capture one RAW16 frame, save as PNG
   from a CLI target. *Proves the SDK works on this Mac before any UI exists.*
2. **Live view** — frame loop, buffer pool, MTKView + stretch shader with fixed
   stretch, window shows live video. Simulator device added here.
3. **Camera + display controls** — exposure, gain, ROI size selection, zoom,
   fit-to-window.
4. **Stretch controls** — histogram, manual sliders, auto-stretch button.
5. **Star tracking** — detection, centroid, auto-centering ROI moves, full-frame
   search on loss, state machine + UI indicator.
6. **Coma analysis** — segmentation, circle fits, concentricity + sector asymmetry,
   overlay graphics, numeric readout, smoothing. Unit tests with ground truth.
7. **Polish** — camera disconnect/reconnect handling, error surfaces, universal
   binary build, bundle + codesign (ad-hoc for personal use), README.

Milestones 1–2 carry the main integration risk (SDK behavior on macOS, USB
permissions, streaming stability); everything after is incremental and mostly
testable against the simulator.

## Risks and mitigations

- **ROI change latency**: stopping/restarting the stream for each ROI move may cause
  visible hiccups. Mitigation: hysteresis so moves are rare; if too disruptive,
  keep a larger sensor ROI and do fine centering digitally in the display.
- **SDK dylib architecture/signing**: verify the shipped dylib is universal; if
  x86_64-only for older versions, fetch current SDK (v1.6.4+, 2026). Ad-hoc
  codesigning with the bundled dylib must be validated early (milestone 1).
- **Coma metric robustness**: seeing and focus depth change the donut; the
  normalized metric + EMA smoothing address this, and the simulator lets us tune
  thresholds before touching hardware.
- **RAW16 throughput at full frame**: Poseidon-M (IMX571) full frames are ~52 MB/s
  at 1 fps-ish rates over USB3 — fine, but full-frame search uses binning to keep
  the search loop fast.
