# Autofocus implementation and validation plan

1. Measure background-subtracted half-flux radius (HFR) from the tracked star
   on raw camera frames. Reject weak, saturated and aperture-clipped stars.
2. Scan nine positions from current position minus four steps to plus four.
   Use a one-step preload below the first point and an increasing final
   approach. Validate all travel, including preload, before commanding a move.
3. Wait for idle feedback at the exact requested position, discard frames
   spanning movement/settling, and take the median of five distinct frames.
   Validate five fresh star frames at the starting position before any move.
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
