# Feature parity

One row per feature, one column per app. Every pull request that changes what a
user sees updates this table, or explains the difference in Notes.

- **macOS app** — `CollimationApp`, SwiftUI and Metal. The release build on macOS.
- **Portable app** — `CollimationCamera`, SDL3 and Dear ImGui. The release build
  on Windows; on macOS it is a development and parity build (milestone 3).

Legend: ✅ shipped · ⏳ planned for a later milestone · — not applicable.

The portable app column is shipped as of milestone 3 and verified on Windows
with the simulator. Windows hardware evidence is recorded in
`HARDWARE-CHECKLIST.md`; macOS execution and the remaining hardware checks
are listed under Not yet verified.

| Feature | macOS app | Portable app | Notes |
|---|---|---|---|
| Connect / disconnect | ✅ | ✅ | Always enabled on both surfaces. |
| Device list (Player One, ZWO, simulators) | ✅ | ✅ | One list; ZWO devices follow Player One. |
| Exposure and gain | ✅ | ✅ | 100 µs to 100 ms. |
| Auto exposure | ✅ | ✅ | `canAutoExpose`. |
| ESATTO autofocus | ✅ | ✅ | Independent take-up control (4000 steps), full weighted symmetric/asymmetric hyperbolic fit, approximate position uncertainty and leave-one-out sensitivity; fresh five-frame medians after settling and three discards; three final HFR diagnostic blocks with no HFR acceptance veto or correction. Acceptance uses curve support and position stability; missing final HFR remains diagnostic only. Shared saturation recovery, bounded re-centering, travel validation and Stop/disconnect cancellation. Windows acceptance evidence is in `HARDWARE-CHECKLIST.md`; macOS interface is wired but execution is untested here. |
| Imaging-system tilt | ✅ | ✅ | Shared nine-position autofocus sequence, common-centre-focus mosaic, six-point minimum tilt/radial fit, embedded TIFF report, separate centre drift, partial results, whole-run interlocks and cancellation. Hardware acceptance details in `HARDWARE-CHECKLIST.md`. |
| Auto stretch | ✅ | ✅ | Always enabled. |
| MTF and arcsinh curves | ✅ | ✅ | Shader math must match `StretchParams.apply`; `stretch shader math` keeps the maths in step and `stretch shader copies` keeps the two MSL strings — `MetalRenderer.shaderSource` for this app, `ShaderSource.metal` for the portable one — from drifting apart. HLSL has no `asinh` and uses the log form. |
| Zoom and fit | ✅ | ✅ | One factor per scroll event by sign, not per tick. |
| Trackpad pinch to zoom | ✅ | macOS only | SDL sends `SDL_EVENT_PINCH_UPDATE` on macOS and Wayland only. Windows precision touchpads send Ctrl and wheel, which the wheel path already covers. |
| ROI follows the star | ✅ | ✅ | Always. The 2048 window recenters as the star moves. Held during mount moves and stacking. |
| Stabilize view | ✅ | ✅ | Own Image stabilization panel. Always enabled. Both run the CPU `StabilizationController` once per new frame. |
| Quarter view | ✅ | ✅ | Same panel. Top-left stays; the right pair swaps vertically and the lower pair swaps horizontally, so both seams join quadrants that did not originally touch. |
| Full-frame search | ✅ | ✅ | Always. A lost star switches to a binned full-frame search until it is found. |
| Collimation overlay and legend | ✅ | ✅ | Two toggles: collimation indicators (rings and coma) and sensor marks (center cross, tracking grid, star). `OverlayScene` and `LegendScene` primitives, drawn in SwiftUI on macOS and on an ImGui draw list in the portable app. While tracking, a faint grid every 200 sensor pixels; the sensor-center cross fades out to that colour by halfway along each arm. |
| ROI map | ✅ | ✅ | 140×94 max. |
| Star profile | ✅ | ✅ | 148×102. |
| Histogram | ✅ | ✅ | |
| Compass dial | ✅ | ✅ | 88×88. |
| Status chip | ✅ | ✅ | |
| Save TIFF | ✅ | ✅ | `canSaveSnapshot`. Native save panel on macOS, `SDL_ShowSaveFileDialog` in the portable app. |
| Save stacked | ✅ | ✅ | `canSaveStacked`. |
| Save constellation | ✅ | ✅ | `canRecordConstellation`; focus sweep additionally requires autofocus. |
| Save grid constellation | ✅ | ✅ | Separate 35-position 7×5 rectangular capture across the sensor width and height, including corners with a 128-pixel crop margin. Centre first, then alternating rows. Uses `canRecordConstellation`; mount capture needs hardware verification. |
| Constellation focus sweep | ✅ | ✅ | Optional for both layouts: centre autofocus, shared ±4000-step range at 250-step increments (33 positions), mount outer loop, focuser inner loop, increasing backlash-compensated approaches. Streaming multi-page float TIFF; cancel, Stop and disconnect stop both devices. Simulated capture is tested; real mount/focuser capture needs hardware verification. |
| Constellation results | ✅ | ✅ | Nine circular or 35 rectangular float stacks, shared star-centred 1×–8× zoom, independent histogram and stretch, and Open Constellation. Focus recordings add a recorded-position slider that preserves zoom/stretch, loads float strips in bulk, and caches the eight most recent layers. No popup help on the focus slider. Native macOS UI needs runtime verification. |
| Mount connect | ✅ | ✅ | `canConnectMount`. Tightened at milestone 2: the macOS menu item was ungated. |
| Mount calibrate | ✅ | ✅ | `canCalibrateMount`. Tightened at milestone 2: the menu item now also needs a connected camera and no stack in flight. |
| Center star | ✅ | ✅ | `canCenterStar`. Same tightening as calibrate. |
| Filter wheel connect and goto | ✅ | ✅ | `canConnectFilterWheel`, `canSelectFilter`. |
| ESATTO focuser connect, step, goto and stop | ✅ | ✅ | Native USB JSON, 115200 8N1. Independent remembered port (`focuser.serialPort`), live position and calibrated limits. Serial work runs off the main actor; Stop and Disconnect remain available while moving. |
| Keyboard shortcuts | ✅ | ✅ | Return connects on both. ImGui maps `.primary` to Cmd on macOS itself, so one chord reads Cmd-K there and Ctrl-K on Windows. |
| Menus | system menu bar | in-window menu bar | Both built from `CommandCatalog`; the portable app has no system menu bar to put them in. |
| Quit | app menu | File ▸ Quit | Not a `CommandCatalog` entry: it acts on the process, not the engine, and macOS supplies its own. The portable app draws its own File menu with the platform's shortcut. |
| Tooltips | ✅ | ✅ | |
| Error dialog | ✅ | ✅ | Both read and clear `engine.errorMessage`. The ImGui modal takes the keyboard while it is open, so Return does not reach Connect behind it. |
| Log file | ✅ | ✅ | Same format and rotation from `LogFile` in the core, one generation of history beside each. Release builds write `collimation.log`: `~/Library/Logs/Collimation Camera/` on macOS, `%LOCALAPPDATA%\Collimation Camera\` on Windows. On macOS the portable app writes `collimation-portable.log` instead, so the two can run side by side for the HUD comparison. The portable app also routes SDL's own log into its file, and writes a rate line once a minute. |
| Startup failure box | — | ✅ | The portable app reports a failed `SDL_Init`, GPU device, or pipeline in a native message box naming the step and the log path, rather than exiting with nothing on screen. A SwiftUI app cannot fail this way. |
| Window icon | ✅ | ✅ | Both derived from `Resources/AppIcon-1024.png` by `scripts/make-icon.sh`: `AppIcon.icns` for the bundle, `AppIcon-256.png` for `SDL_SetWindowIcon`. On Windows the icon Explorer and Start show comes from the PE resource instead (milestone 5). |
| Fonts | ✅ | ✅ | macOS: system SF and SF Mono. Portable: bundled DejaVu. Deliberate difference. |
| Remembered save folder | ✅ | ✅ | `engine.snapshotDirectory`, key `snapshot.directory`. |
| Remembered serial port and wheel | ✅ | ✅ | Keys `mount.serialPort` and `filterWheel.id`. Per app on macOS, because the two apps have separate `UserDefaults` domains. Deliberate difference. |
| Settings location | ✅ | ✅ | macOS: `UserDefaults` per bundle id. Windows: `%LOCALAPPDATA%\<executable name>.plist`. |

## Deliberate differences

- The two macOS apps do not share settings. Remembered ports, wheels, and
  folders are per app, because `UserDefaults` is keyed on the bundle
  identifier. The portable app on macOS is a development build, so this is
  acceptable.
- Fonts differ: the macOS app uses the system faces, the portable app bundles
  DejaVu so Windows and macOS render identically to each other. Dear ImGui's
  built-in face covers only Latin-1, so the "—", "…", "″", "·", and "×" the
  shared strings use would render as "?". Text metrics therefore differ
  slightly between the two apps; HUD geometry does not.
- Enablement is the engine's `can*` predicate on every surface. Milestone 2
  rebuilt the macOS menus from `CommandCatalog`, which tightened three items —
  Calibrate Mount, Center Star, and Connect Mount — because
  the pre-port menu was looser than both the sidebar and the engine's own
  early returns.

## Not yet verified

The rows above describe implementation parity. Windows simulator and
hardware checks are recorded separately; a ✅ does not imply macOS execution.
On 2-3 October 2026, the autofocus release passed 159 core checks, built all
Windows products and rendered the portable sidebar successfully. Twenty
interleaved 1000-step trials on Xena585M/COM4 had ten successes per policy:
final-position SD was 82.4 steps old and 35.4 new. Both stopped mount axes
on COM10 retained their counters, and the reference was restored through
4000-step take-up. Smaller-spacing results and limitations are in
`HARDWARE-CHECKLIST.md`. These checks are still open:

- Remaining hardware acceptance (§7.8), including a ZWO camera; Player One
  evidence is in `HARDWARE-CHECKLIST.md`.
- The portable app on macOS, and the macOS half of the milestone 0 spike.
- HUD geometry compared by overlaying screenshots of the two apps for the same
  simulator state (§9.8).
- Interactive ESATTO Stop during a real motor move remains untested in this
  session. The shared production Stop command was exercised during measured
  motor travel, confirmed stopped and initiated no restoration; a separate
  explicit cleanup restored the reference. One post-cancellation setup move
  had an unresolved command/position mismatch, retained in the checklist.
  Native GOTO, both movement directions, full outward approaches,
  exact-position feedback and stopped restoration were exercised on COM4
  (ESATTO30136, calibrated maximum 731000). Automated regressions cover Stop,
  disconnect, cancellation in every autofocus phase, command encoding,
  errors, travel limits, startup retries and polling. The macOS focuser
  interface has not been run here.
