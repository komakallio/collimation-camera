# Feature parity

One row per feature, one column per app. Every pull request that changes what a
user sees updates this table, or explains the difference in Notes.

- **macOS app** — `CollimationApp`, SwiftUI and Metal. The release build on macOS.
- **Portable app** — `CollimationCamera`, SDL3 and Dear ImGui. The release build
  on Windows; on macOS it is a development and parity build (milestone 3).

Legend: ✅ shipped · ⏳ planned for a later milestone · — not applicable.

| Feature | macOS app | Portable app | Notes |
|---|---|---|---|
| Connect / disconnect | ✅ | ⏳ | Always enabled on both surfaces. |
| Device list (Player One, ZWO, simulators) | ✅ | ⏳ | One list; ZWO devices follow Player One. |
| Exposure and gain | ✅ | ⏳ | 100 µs to 100 ms. |
| Auto exposure | ✅ | ⏳ | `canAutoExpose`. |
| Auto stretch | ✅ | ⏳ | Always enabled. |
| MTF and arcsinh curves | ✅ | ⏳ | Shader math must match `StretchParams.apply`. |
| Zoom and fit | ✅ | ⏳ | One factor per scroll event by sign, not per tick. |
| Auto-center | ✅ | ⏳ | `canToggleAutoCenter`. |
| Stabilize view | ✅ | ⏳ | Always enabled. |
| Search full frame | ✅ | ⏳ | `canSearchFullFrame`. The macOS menu item is still ungated; milestone 2 switches it over. |
| Collimation overlay and legend | ✅ | ⏳ | Always enabled. |
| ROI map | ✅ | ⏳ | 140×94 max. |
| Star profile | ✅ | ⏳ | 148×102. |
| Histogram | ✅ | ⏳ | |
| Compass dial | ✅ | ⏳ | 88×88. |
| Status chip | ✅ | ⏳ | |
| Save TIFF | ✅ | ⏳ | `canSaveSnapshot`. |
| Save stacked | ✅ | ⏳ | `canSaveStacked`. |
| Save constellation | ✅ | ⏳ | `canSaveConstellation`. |
| Mount connect | ✅ | ⏳ | `canConnectMount`. The macOS menu item is still ungated; milestone 2 switches it over. |
| Mount calibrate | ✅ | ⏳ | `canCalibrateMount`. The sidebar uses it now; the menu item still has its own looser predicate until milestone 2. |
| Center star | ✅ | ⏳ | `canCenterStar`. Same as calibrate: sidebar now, menu at milestone 2. |
| Filter wheel connect and goto | ✅ | ⏳ | `canConnectFilterWheel`, `canSelectFilter`. |
| Keyboard shortcuts | ✅ | ⏳ | Return connects on both. |
| Tooltips | ✅ | ⏳ | |
| Error dialog | ✅ | ⏳ | |
| Log file | ⏳ | ⏳ | `Log.sink` is in place; neither app writes a file yet. |
| Fonts | ✅ | ⏳ | macOS: system SF and SF Mono. Portable: bundled DejaVu. Deliberate difference. |
| Remembered save folder | ✅ | ⏳ | `engine.snapshotDirectory`, key `snapshot.directory`. |
| Remembered serial port and wheel | ✅ | ⏳ | Keys `mount.serialPort` and `filterWheel.id`. Per app on macOS, because the two apps have separate `UserDefaults` domains. Deliberate difference. |
| Settings location | ✅ | ⏳ | macOS: `UserDefaults` per bundle id. Windows: `%LOCALAPPDATA%\<executable name>.plist`. |

## Deliberate differences

- The two macOS apps do not share settings. Remembered ports, wheels, and
  folders are per app, because `UserDefaults` is keyed on the bundle
  identifier. The portable app on macOS is a development build, so this is
  acceptable.
- Fonts differ: the macOS app uses the system faces, the portable app bundles
  DejaVu so Windows and macOS render identically to each other.
- Enablement is the engine's `can*` predicate. The sidebar reads it today; the
  macOS menu still carries its own inline predicates and moves over in
  milestone 2, when the menus are rebuilt from `CommandCatalog`. That will
  tighten four items — Calibrate Mount, Center Star, Search Full Frame, and
  Connect Mount — because the pre-port menu was looser than both the sidebar
  and the engine's own early returns.
