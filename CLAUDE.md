# Working in this repository

Read this before changing anything. It is the conventions and the traps, not a
tour — `README.md` builds and runs, `PARITY.md` is the feature table,
`PLAN-MULTIPLATFORM.md` is the design and what has actually been verified, and
`HARDWARE-CHECKLIST.md` is the order to work through with a camera attached.

## The shape

Two apps, one engine.

```
CollimationCore    capture, stretch, tracking, coma analysis. No UI framework.
                   Platform/ holds the only #if os() code, plus the two serial drivers.
CollimationUI      commands, formatters, HUD scenes. Platform-free, no UI framework.
CollimationApp     macOS: SwiftUI + Metal. The macOS release.
CollimationPortableApp   SDL3 + Dear ImGui. The Windows release; on macOS a parity build.
```

`CollimationEngine` is the only view model. Both apps read it each frame and
call the same commands. If you find yourself adding state to an app, it belongs
in the engine.

## Rules that are enforced, and how

| Rule | What enforces it |
|---|---|
| `CollimationCore` and `CollimationUI` import no UI, platform, or windowing framework | `make lint` / `scripts/check-core-imports.sh`, in CI |
| Every command is reachable in **both** apps | `command reachability` reads both sidebar sources |
| A sidebar-only command has no keyboard shortcut (macOS takes shortcuts from menu items) | `command reachability` |
| Shortcuts use only Return, A–Z, 0–9 (the portable app's key table) | `shortcut uniqueness` |
| No UI string uses a character the bundled fonts lack | `ui glyph coverage` reads the DejaVu cmap tables |
| HUD strokes stay between 0.5 and 4 points | `hud stroke widths` |
| The two MSL shaders do not drift apart | `stretch shader copies` reads both files |

A rule with no test in that table is a rule someone will break.

## Traps

**The stretch maths exists in four places, not three.** `StretchParams.apply`
(the CPU reference), `MetalRenderer.shaderSource` (what the macOS release
renders), `ShaderSource.metal` (what the portable app renders), and
`ShaderSource.hlslFragment`. The two MSL strings are separate and identical
from the fragment stage down. Change one, change all four.
`stretch shader math` will **not** catch a miss — it re-implements the maths in
Swift rather than reading the strings. `stretch shader copies` will. The right
end state is one shared MSL source; nobody has done it because it edits a
renderer whose output cannot be seen from Windows.

**`StretchUniforms` has no room and two overloaded fields.** Eight 4-byte
scalars, fixed by HLSL cbuffer packing. `mode` is 0 for MTF and 1 for arcsinh;
`amount` is the midtones balance or the arcsinh factor depending on `mode`.
Both renderers pack them with `==`, not a switch, so a third `StretchCurve`
case compiles, arrives as `mode = 0`, and renders as MTF with the wrong
parameter — and no test fails. The doc comment on `StretchUniforms` lists
everything a new curve has to touch.

**Swift cannot import a variadic C function.** `igText`, `igTextDisabled`,
`igTextWrapped`, and `igSetItemTooltip` are all unavailable. `ImGuiText` in
`HUDDrawList.swift` rebuilds each from its non-variadic parts.

**ImGui identifies a widget by its label.** Two buttons that read `Connect` are
one widget: clicking one can operate the other, and ImGui throws a modal
"conflicting ID" dialog over the live view. Sidebar buttons carry `##` plus the
command id for that reason — which also keeps a button's identity stable when
its title flips between `Connect` and `Disconnect`. `--snapshot` exits non-zero
if a conflict appears; nothing else catches it.

**Nothing runs the portable app's quit path except `quit-win.ps1`.** That is
how a quit that never quit survived: `--snapshot` sets the loop's flag itself
and `run-win.ps1 -Seconds` kills the process, so the close button reached
nothing that was ever exercised. If you touch the event loop, run it.

**Whole-module optimization loses SDL's texture-format constants** when
`WinSDK.DirectX` is imported anywhere in the same module — release only, and
the type still resolves while every `SDL_GPU_TEXTUREFORMAT_*` vanishes. The
formats the app names are re-exported from `Sources/CSDL3/shim.h` as
`CSDL3_TEXTUREFORMAT_*`.

**A Windows release build has no standard output.** It links
`/SUBSYSTEM:WINDOWS`, so the trapping `FileHandle.write(_:)` aborts on the
first log line. Use the throwing call. Never `fatalError` in the portable app —
it aborts with nothing on screen. Startup failures go through
`Diagnostics.fail`, which shows a message box naming the step and the log path.

**Windows quantizes sleeps to 15.6 ms** unless something raised the timer
resolution. SDL_Init does it for the apps; `capture-cli` calls
`TimerResolution.raise()`. Anything pacing a loop uses `preciseSleep`, never
`Thread.sleep`.

**The debug build is roughly five times slower** than release against the
simulator — 15 fps versus 75 — almost all of it `-Onone` in the analysis
pipeline. Never judge performance from a development build.

## Windows

Nothing on `PATH` works by default. Use the scripts:

```powershell
scripts\fetch-sdk.ps1                                  # SDL3, vendor SDKs, icon resource
scripts\build-win.ps1 build --product CollimationCamera
scripts\run-win.ps1 CollimationCamera                  # stages runtime + SDL3 + Resources first
scripts\package-win.ps1                                # dist zip
scripts\window-stress-win.ps1                          # minimize/restore/resize
scripts\quit-win.ps1                                   # close the window, time the exit
```

`win.cmd` wraps `build-win.ps1` through cmd, because PowerShell 5.1 turns a
native tool's stderr into a failure even on exit 0. All of them share the
`.build-win` scratch path. Every one of them prints
`'vswhere.exe' is not recognized` first; it comes from `Enter-VsDevShell`
shelling out through cmd, the developer shell is entered anyway, and it cannot
be redirected away from inside PowerShell.

`quit-win.ps1` covers the one path the others cannot: `run-win.ps1 -Seconds`
kills the process and `--snapshot` ends the loop by itself, so from the close
button to a clean exit went untested for a long time and was broken.

A build directory holds only the executable. Without the Swift runtime, SDL3,
and `Resources/` beside it, Windows raises a loader box that suspends the
process with **no window and no log** — a confusing failure that comes back
every time the output directory is cleaned. `stage-win.ps1` puts them there.

## Diagnosing without a screen

The app can answer for itself, which is how it gets debugged over remote
desktop or with the display asleep:

```powershell
CollimationCamera.exe --check                              # GPU, formats, pipeline, fonts, SDKs, ports
CollimationCamera.exe --snapshot shot.png --snapshot-after 8 --window-size 1280x820
capture-cli.exe --frames 100 --device poa-0 --roi 2048 --exposure 20
```

Check `--snapshot`'s exit status, not just the PNG: it is non-zero on a widget
id conflict. And run it through `run-win.ps1` or `Start-Process -Wait`, because
the release build is a GUI subsystem image and PowerShell's `&` does not wait
for one — it returns immediately and leaves `$LASTEXITCODE` empty.

`--snapshot` renders through the same code the window uses, so the PNG is what
the window would have shown. `--window-size` is in **points**, so the same
argument lays both apps out identically — that is what the §9.8 HUD comparison
needs. Compare by eye, not pixel by pixel: the simulator drifts, and the
geometry is already pinned by the scene tests.

The log carries a rate line once a minute. `%LOCALAPPDATA%\Collimation Camera\`
on Windows, `~/Library/Logs/Collimation Camera/` on macOS, one generation of
history beside it.

## Things that are not there

Worth knowing before you go looking:

- **No fallback texture format.** §13 sketches one; none of it is written. The
  app checks `R16_UINT` + `GRAPHICS_STORAGE_READ` at startup and refuses to run
  without it, because the alternative is a black live region and no clue why.
- **The SwiftUI app cannot snapshot itself.** `--snapshot` belongs to the
  portable app. Producing the macOS half of the §9.8 HUD comparison still means
  a screen grab by hand, at the same window size.
- **The version number is written out in three places** — `SDL_SetAppMetadata`
  in `main.swift` and `CFBundleVersion` in both packaging scripts — and there is
  no release procedure, tag convention, or changelog. Bumping a version means
  editing all three.
- **`swift build` on Windows always warns** that it could not create a symbolic
  link for the `debug`/`release` convenience path. It is SwiftPM wanting
  Developer Mode; the build is fine and nothing depends on those links.
- **`engine.connect()` runs before the first frame.** With a camera attached
  that is a blocking SDK call, so a slow or wedged camera shows as a window
  that never appears. The log stops after the ImGui version line — if that is
  the last thing in it, the camera is why.

## Adding a feature

1. Engine state and behaviour in `CollimationCore`, with a test in `CoreTests`.
2. Labels, help text, enablement, and shortcut in `CollimationUI` —
   `CommandCatalog`, `MetricText`, `HelpText`. Never inline a user-visible
   string in an app.
3. HUD geometry as a scene in `CollimationUI` returning `[HUDPrimitive]`. Both
   apps replay the same primitives: `HUDCanvas` on macOS, `HUDDrawList` in the
   portable app.
4. Wire it into **both** sidebars.
5. Update `PARITY.md`, or say there why the apps differ.
6. If it added a widget to the portable sidebar, run `--snapshot` once and
   check the exit status. ImGui identifies a widget by its label, so two
   controls that read the same word are the same widget — clicking one can
   operate the other, and ImGui puts a modal error over the live view. The
   snapshot run exits non-zero on that; nothing else catches it. Buttons built
   from `CommandCatalog` are already keyed by command id, so this is about
   anything hand-written.

`.github/pull_request_template.md` is the checklist.

## What is not verified

Everything has been run on Windows against the simulator, and the camera side
has now had one session with two Player One cameras. No mount, no filter wheel,
no ZWO camera, and the macOS side compiles in CI but has never been launched.
`PLAN-MULTIPLATFORM.md` §14b and §14c are the honest list of what was actually
checked and what was not. Do not read a ✅ in `PARITY.md` as "someone saw this
work".

That session found six defects in a couple of hours: a camera that only opens
after the bus has been scanned, a tool that reported failure as a stack trace,
an acquisition path that believed a single noise peak, an ImGui fill that
assumed convexity, three buttons sharing one widget id — and an app that could
not be quit, because the close event set the loop's `running` flag to true
instead of false and nothing had ever closed the window before. Expect the same
ratio from the mount and the wheel.

## Conventions

Commit messages say what changed and why, in prose, no trailers. British
spelling in prose, US in code identifiers where the platform uses it. Comments
explain why, not what.
