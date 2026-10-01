# Autofocus implementation and validation plan

1. Measure background-subtracted half-flux radius (HFR) from the tracked star
   on raw camera frames. Reject weak, saturated and aperture-clipped stars.
   Before moving, tune exposure from five fresh raw peak readings toward
   50% of full scale (45–60% accepted), within 100 µs–100 ms. Clipping reduces
   exposure by a factor of five before proportional tuning. Drain three SDK
   frames after exposure changes, in addition to the timestamp/settle gate.
2. Scan nine positions from current position minus four steps to plus four.
   Use a one-step preload below the first point and an increasing final
   approach. Validate all travel, including preload, before commanding a move.
3. Wait for idle feedback at the exact requested position, discard frames
   spanning movement/settling, and take the median of five distinct frames.
   Validate five fresh star frames at the starting position before any move.
   Clipping at a scan point or verification retunes exposure while stopped,
   discards the partial curve and repeats the baseline and complete scan at
   one exposure. Keep the shorter exposure when returning to the defocused
   starting point. Limit selection to 12 adjustments and recovery to four
   restarts; fail clearly if the star clips at minimum exposure.
4. Require an interior minimum with both endpoints at least 5% worse.
   Interpolate a quadratic in HFR squared through its three neighbours and
   verify the final position with another five frames (15% tolerance).
5. Keep serial work off the main actor. Stop/disconnect/camera loss cancel the
   run and prevent queued motion from continuing. Time out moves and samples.
   Lock manual focus, exposure/gain changes, stacking, mount work and filter
   changes for the run; keep Stop and Disconnect available.
6. Expose step size, Autofocus and progress/results through shared UI models
   and both sidebars. Record each scan point and the result in the app log.
7. Test synthetic stars/donuts, noisy curves, travel limits/overflow,
   freshness gates, cancellation, failures and engine enablement. Build the
   Windows app, run the full core suite and render the portable sidebar.
8. Check COM4 identity/status. Exercise a bounded motor move and full optical
   autofocus only when the connected camera supplies a usable tracked star.

`capture-cli --autofocus COM4 --device poa-0 --focus-step 1000 --exposure 5`
runs the shared engine without a window for repeatable hardware acceptance.
It applies the requested exposure after the camera connection loads controls.
That is the starting exposure; autofocus selects and retains a usable setting.
Each retained sample records its exposure for diagnostics. Stop cancels both
exposure selection and focuser movement.

Hardware testing found that this ESATTO can report `BUSY=0` while `MST=dec`.
The driver now treats any non-stop motor phase as movement as well as BUSY,
so autofocus and manual controls wait for complete deceleration. A protocol
regression test covers this transition and malformed phase replies.

The scan intentionally does not expand travel automatically. It leaves the
focuser at its current position on failure/cancellation and sends Stop; the
user can adjust the step or starting point before retrying. The one-step
approach must exceed the system's backlash. This first version focuses the
single tracked star and does not include temperature/filter compensation.

HFR scanning and consistent-direction approaches follow the general method
documented in the [KStars focus manual](https://kstars-docs.kde.org/en/user_manual/ekos-focus.html).

## Validation completed on 1 October 2026

- Windows release build: all products, including application and capture CLI.
- Core suite: 127 passing tests, including optical simulation, cancellation,
  stale/duplicate frames, motor faults, flat/edge curves, verification failure,
  Gaussian/donut HFR, adjacent stars, travel overflow and deceleration status.
- Portable sidebar: 1280×1000 offscreen render; no ImGui widget conflicts.
- Real optical run: Xena 585M and ESATTO30136 on COM4, 0.5 ms exposure,
  1000-step spacing, final position 315969; HFR 2.182 → 1.049 sensor pixels.
  The initial connection was read-only; subsequent movement and final
  verification used the same engine as the graphical application.

Recorded scan:

| Position (steps) | Median HFR (sensor pixels) |
|---|---|
| 309967 | 6.544 |
| 310967 | 5.443 |
| 311967 | 4.363 |
| 312967 | 3.249 |
| 313967 | 2.189 |
| 314967 | 1.336 |
| 315967 | 1.083 |
| 316967 | 1.335 |
| 317967 | 2.236 |
| 315969 (verification) | 1.049 |

The successful hardware command was:

```powershell
scripts\run-win.ps1 -Product capture-cli -Configuration release --autofocus COM4 --device poa-0 --focus-step 1000 --exposure 0.5
```

Manual GUI cancellation/unplug/quit acceptance and macOS execution remain
to be checked. Unit tests cover cancellation and device faults with simulated
hardware.

## Automatic exposure validation, 1 October 2026

- Windows release build passed for all products; all 133 core tests passed.
  New coverage includes clipped/faint startup, buffered exposures, saturation
  during the scan and verification, minimum-exposure failure, and cancellation
  during exposure selection or before the task starts. Recovery tests retain
  nine samples at one exposure and stay inside the original travel bounds.
- Real Xena 585M / ESATTO30136 run started at 315829 steps with deliberately
  clipped 20 ms exposure. Exposure selected automatically: 20 → 4 → 0.8 →
  **0.627 ms**, peak **32368 ADU**, before the first motor command.
- Scan 311829–319829, 1000-step spacing; verified **315930 steps**, HFR
  **1.023 sensor pixels** (baseline 1.100). No scan restart was needed after
  the initial exposure selection. A separate status check confirmed stopped
  at 315930. Clipping recovery during scanning and verification was tested
  with the deterministic optical fixture; this real run tested clipped startup.
- Portable sidebar rendered at 1280×1000 with no widget conflicts.

```powershell
scripts\run-win.ps1 -Product capture-cli -Configuration release --autofocus COM4 --device poa-0 --focus-step 1000 --exposure 20
```
