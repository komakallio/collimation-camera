# Feature parity

One row per feature, one column per app. Every pull request that changes what a
user sees updates this table, or explains the difference in Notes.

- **macOS app** — `CollimationApp`, SwiftUI and Metal. The release build on macOS.
- **Portable app** — `CollimationCamera`, SDL3 and Dear ImGui. The release build
  on Windows; on macOS it is a development and parity build (milestone 3).

Legend: ✅ shipped · ⏳ planned for a later milestone · — not applicable.

The portable app column is shipped as of milestone 3 and verified on Windows
with the simulator. Hardware, and the portable app on macOS, are still open;
see Not yet verified at the end.

| Feature | macOS app | Portable app | Notes |
|---|---|---|---|
| Connect / disconnect | ✅ | ✅ | Always enabled on both surfaces. |
| Device list (Player One, ZWO, simulators) | ✅ | ✅ | One list; ZWO devices follow Player One. |
| Exposure and gain | ✅ | ✅ | 100 µs to 100 ms. |
| Auto exposure | ✅ | ✅ | `canAutoExpose`. |
| Auto stretch | ✅ | ✅ | Always enabled. |
| MTF and arcsinh curves | ✅ | ✅ | Shader math must match `StretchParams.apply`; the `stretch shader math` test keeps the CPU, MSL, and HLSL columns in step. HLSL has no `asinh` and uses the log form. |
| Zoom and fit | ✅ | ✅ | One factor per scroll event by sign, not per tick. |
| Trackpad pinch to zoom | ✅ | macOS only | SDL sends `SDL_EVENT_PINCH_UPDATE` on macOS and Wayland only. Windows precision touchpads send Ctrl and wheel, which the wheel path already covers. |
| Auto-center | ✅ | ✅ | `canToggleAutoCenter`. |
| Stabilize view | ✅ | ✅ | Always enabled. Both run the CPU `StabilizationController` once per new frame. |
| Search full frame | ✅ | ✅ | `canSearchFullFrame`. Tightened at milestone 2: the macOS menu item was ungated. |
| Collimation overlay and legend | ✅ | ✅ | Always enabled. `OverlayScene` and `LegendScene` primitives, drawn in SwiftUI on macOS and on an ImGui draw list in the portable app. |
| ROI map | ✅ | ✅ | 140×94 max. |
| Star profile | ✅ | ✅ | 148×102. |
| Histogram | ✅ | ✅ | |
| Compass dial | ✅ | ✅ | 88×88. |
| Status chip | ✅ | ✅ | |
| Save TIFF | ✅ | ✅ | `canSaveSnapshot`. Native save panel on macOS, `SDL_ShowSaveFileDialog` in the portable app. |
| Save stacked | ✅ | ✅ | `canSaveStacked`. |
| Save constellation | ✅ | ✅ | `canSaveConstellation`. |
| Mount connect | ✅ | ✅ | `canConnectMount`. Tightened at milestone 2: the macOS menu item was ungated. |
| Mount calibrate | ✅ | ✅ | `canCalibrateMount`. Tightened at milestone 2: the menu item now also needs a connected camera and no stack in flight. |
| Center star | ✅ | ✅ | `canCenterStar`. Same tightening as calibrate. |
| Filter wheel connect and goto | ✅ | ✅ | `canConnectFilterWheel`, `canSelectFilter`. |
| Keyboard shortcuts | ✅ | ✅ | Return connects on both. ImGui maps `.primary` to Cmd on macOS itself, so one chord reads Cmd-K there and Ctrl-K on Windows. |
| Menus | system menu bar | in-window menu bar | Both built from `CommandCatalog`; the portable app has no system menu bar to put them in. |
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
  rebuilt the macOS menus from `CommandCatalog`, which tightened four items —
  Calibrate Mount, Center Star, Search Full Frame, and Connect Mount — because
  the pre-port menu was looser than both the sidebar and the engine's own
  early returns.

## Not yet verified

The rows above are read from the code and from a Windows run against the
simulator. These checks are still open, and a ✅ is a claim about the code
until they pass:

- Hardware acceptance (§7.8): a Player One camera first, then a ZWO camera.
- The portable app on macOS, and the macOS half of the milestone 0 spike.
- HUD geometry compared by overlaying screenshots of the two apps for the same
  simulator state (§9.8).
