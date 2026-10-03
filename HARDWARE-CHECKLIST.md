# First session with hardware

This is the order to work through, Player One first and ZWO after, with the
commands to run and what a pass looks like. Each step's output belongs in the
log file, so a failure can be sent on rather than described.

**Where this stands.** Steps 0 to 7 all pass on Player One — a Xena 585M, a
Poseidon-M PRO, an EQDIR cable and a Phoenix wheel — including every unplug.
What is left: the seven fixes those sessions produced re-tested, and all of
ZWO. `PLAN-MULTIPLATFORM.md` §14c has the numbers and every defect found; §14b
is what was verified without hardware.

**Reading the log while the app is running.** Open it and read the bytes. A
directory listing shows 0 and a stale timestamp for as long as the app holds
the file, because Windows does not update the directory entry until the handle
is flushed or closed. The log is not empty; the listing is lying.

**The EQDIR is an FTDI FT232R** (VID 0403, PID 6001). Windows ships the driver;
if the port does not appear, check Device Manager rather than looking for one.
The app reads `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`, which lists FTDI ports —
WMI's `Win32_SerialPort`, which many tools use, does not.

Log file: `%LOCALAPPDATA%\Collimation Camera\collimation.log` on Windows,
`~/Library/Logs/Collimation Camera/collimation.log` on macOS. The previous run
is kept beside it as `collimation.log.1`.

## 0. Before plugging anything in

Install the vendor **driver** first, then connect the camera. The SDK DLLs in
the package are not drivers.

```powershell
CollimationCamera.exe --check
```

Pass: it names the GPU driver, says `R16_UINT storage read: yes`, says
`stretch pipeline: ok`, lists all three fonts, and reports the SDK versions for
whichever vendors you have. A `not found` for an SDK you do not use is fine.

## 1. The camera appears

```powershell
capture-cli.exe --list
```

Pass: the camera is in the list with its sensor size, next to the two
simulators. If it is not, the app will not see it either — check the driver,
the cable, and whether another program has the camera open.

## 2. One frame

```powershell
capture-cli.exe --device poa-0 --output frame.tif
```

Pass: a 16-bit mono TIFF whose size matches the ROI printed. Open it and look
at it. Defocus until the secondary shadow is a clear hole before trusting
anything downstream.

## 3. The frame rate (§7.8, §9.8)

```powershell
capture-cli.exe --frames 100 --device poa-0 --roi 2048 --exposure 20
```

Pass: 30 fps or the camera's own limit, whichever is lower, with an interval
spread of a few milliseconds rather than tens. A mean interval near 15.6 ms or
a multiple of it means something is sleeping on the default Windows timer.
Compare the number against the same camera on the Mac.

Which limit applies depends on the sensor, so measure before reading anything
into it. A Xena 585M holds the app's 30 fps cap at both 512 and 2048; a
Poseidon-M PRO reads out at 30.0, 22.8 and 11.6 fps at 512, 1024 and 2048.

Repeat with `--roi 512` and with a short exposure. Also check the ADU range it
reports: `clipped` means lower the exposure or the gain.

## 4. The app, with the camera

Start it, pick the camera, connect. Then, in order:

- **Auto exposure**, then **Auto stretch**. The donut should be visible and not
  clipped; clipped pixels paint red. The camera window follows the star on its
  own — the fps line in the log should not drop while it moves.
- Move the star off the ROI by hand. The app should switch to a binned
  full-frame search and recenter itself.
- **Stabilize view**, then **zoom** with the wheel. One zoom step per wheel
  click, not per accumulated tick.
- **Save TIFF**, then **Save Stacked** with 1000 frames. The stack should run
  at the camera's unlimited rate, faster than the live view.
- Leave it running for ten minutes and read the heartbeat lines in the log: one
  a minute, with the rate, the tracking state, the zoom, and the ROI.
- With a tightly focused star, check that the collimation circles and arrow
  remain present and follow the core rather than jumping out into the sky.

On 2 October 2026, a headless comparison on the Xena 585M (`poa-0`), at
0.546 ms exposure and gain 0 with focus unchanged, fed the same 300 frames to
the old and corrected coma analyzers. Tracking succeeded in every frame.
The old analyzer returned usable collimation measurements in **72/300**;
the corrected analyzer returned **300/300**, with footprint radii of
**2.25–3.25 pixels**. The fix accepts compact cores, requires a visible ring
rise near the core before selecting an Airy minimum, and verifies that an
inferred secondary shadow has a dark interior. This tested the shared
analysis; the window overlay was not visually inspected during this run.

## 5. Unplug it (§7.8)

Pull the cable while the live view is running, then again during a 1000-frame
stack, then again during Center.

Pass, each time: the error dialog opens, the app keeps drawing (the fps label
keeps updating; no stall longer than three seconds), and reconnecting works
after the camera is plugged back in.

Reconnecting means pressing **Connect** again, not replugging alone — the app
does not poll for a camera that has gone. What it must not do is what it used
to: freeze the picture, say nothing, and leave the button reading Disconnect.
The error takes a couple of grab timeouts to arrive, so at a long exposure give
it a few seconds.

## 6. The mount (§10.3)

With an EQDIR or SynScan cable:

- **Refresh** lists the port. **Connect** should report which protocol was
  detected — SkyWatcher, SynScan, or LX200 — within a couple of seconds.
- The log carries every exchange as `EQ6 TX` and `EQ6 RX` lines. Keep them.
- **Calibrate**, then **Center** on an artificial star. Compare the calibration
  numbers with the macOS ones for the same mount.
- EQDIR/SynScan calibration uses 750 ms RA jogs at 8x. First it takes up RA
  backlash until one jog visibly moves the star; that time is excluded from
  the measured rate. Dec (and LX200) retains 3-second guide pulses. Each axis
  must move at least 30 sensor pixels, with separate 15-second motor-time
  limits for RA take-up and each outbound measurement. Verify that a delayed
  RA start does not reduce the measured rate, and Cancel stops the jog. Each
  return uses the same speed and motor time as its measured outbound move.
  Check `mount centroid sample` against the calibration coordinates: both X
  and Y must remain plausible after waiting for frames.
- From a centred star, run **Save Constellation**. The first tile must remain
  at the sensor centre; then check all eight outer positions. The log records
  the full-frame readout, measured centroid, target and each correction. A
  changed detection during the readout switch must stop before a new slew.
- Unplug the camera during Center: the mount work should end with the
  disconnect error rather than `noStar` four seconds later, the mount should
  stay connected, and Calibrate should work again after the camera reconnects.

Without a mount, a com0com virtual pair or a USB serial loopback is enough to
check that the port is listed and that Connect fails with `unrecognized`
rather than crashing.

## ESATTO focuser

- Select the ESATTO USB port in **Focuser** (COM4 on this computer) and Connect.
  Allow about three seconds for controller startup; check the position and
  calibrated maximum against the vendor application, with that application
  closed before this app takes the port.
- The read-only `--check-focuser COM4` diagnostic uses the same native driver
  and sends no motor commands. COM4 read-only queries on 1 October 2026
  reported ESATTO30136, firmware 3.05.28, position 317000 / 731000, stopped.
  The application's native driver also connected and polled the same values.
- With room in both directions, choose a small step and check In decreases
  and Out increases the physical position by that step. Go to the original
  position, then check Stop during a longer move.
- Check negative/out-of-range targets and non-positive/oversized steps are
  disabled, and that repeated moves wait for the motor to stop.
- Disconnect during movement, reconnect, and check its actual position.
  Unplug USB during a move: the window should remain responsive, the error
  should allow reconnect, and a later response must not restore stale state.
- Quit during movement and confirm the motor stops. Stacking and mount work
  should disable new focus moves; active focus movement should disable new
  stacks, auto exposure and mount calibration/centering.

Physical movement was subsequently exercised through the autofocus scan
below. Manual Stop, unplug and quit acceptance on real hardware remain pending.

### Autofocus

- Read-only COM4 check on 1 October 2026: ESATTO30136, position
  319000 / 731000 steps, stopped; identity and repeated status/position polls
  succeeded with the native application driver.
- With a real camera tracking an artificial star, choose an
  **Autofocus step** that samples a supported curve on both flanks. Keep
  **Autofocus take-up** separate (initially 4000 steps), and confirm the
  complete nine-position scan and full outward approaches fit within travel.
- Confirm each measured approach settles for one second, discards three
  fresh frames and measures five usable frames. Nine positions are sampled
  outward and the supported fitted target is approached outward. Final HFR
  is recorded in three blocks and cannot invalidate or change that position.
  Check repeatability of focus positions, curve diagnostics and stopped status.
- Stop during a move and during frame collection; no later scan moves may
  follow. Repeat with camera disconnect, focuser disconnect, USB removal and
  quitting. Confirm reconnect permits a new run.
- Begin with a clipped star: exposure must shorten automatically before any
  motor move. Check the chosen exposure and final result in the log.
- Start defocused so the star clips later: autofocus must shorten exposure
  and remeasure the complete curve. All retained points must use one exposure.
- Start with focus outside the initial scan: a supported HFR slope must
  re-centre the scan toward the improving edge until focus is bracketed.
  Check multiple shifts, both directions, exposure recovery and final approach.
- A weak/inconsistent edge slope must not initiate another scan. Confirm
  continuing slopes stop at calibrated travel, with every preload in range.
- Cover the camera: autofocus must report a measurement failure. Saturation
  persisting at minimum exposure or a flat curve must fail clearly.
- Confirm manual focus, exposure/gain, stacking, mount work and filter moves
  are blocked throughout autofocus, including its frame-collection periods.

On 1 October 2026, the shared engine completed an optical autofocus run on the
Xena 585M (`poa-0`) and ESATTO30136 on COM4, using the artificial star confirmed
by the user. Exposure 0.5 ms, gain 0, autofocus step 1000. The scan covered
309967–317967 steps with nine five-frame medians; final verification placed
the focuser at **315969 steps**, HFR **1.049 sensor pixels**, down from 2.182.
The scan minimum was 1.083 pixels at 315967; both surrounding samples were
1.335–1.336. The headless command exited successfully and sent Stop on close.

Earlier attempts exercised two failure paths: the native controller returned
`BUSY=0` during `MST=dec`, requiring the driver to wait for the non-stop phase;
and the star clipped as focus improved at 5 ms, correctly aborting frame
measurement in the original implementation. The final run used shorter exposure to keep the whole scan
unsaturated. No calibration, speed or controller backlash settings changed.

Automatic exposure was then verified on the same camera/focuser: a clipped
20 ms starting exposure was reduced to 4 ms, 0.8 ms and finally **0.627 ms**,
peak **32368 ADU**, before any motor move. The 311829–319829 scan completed
with final focus **315930 steps**, HFR **1.023 sensor pixels**. A separate
native-driver poll confirmed the motor stopped at 315930. The Windows release
build, all **133 tests**, and the portable sidebar render passed. Synthetic
optical tests additionally verified exposure recovery during scanning and
final verification, complete curve replacement, and Stop during selection.

Scan re-centering was then exercised from **332930 steps** on COM4. Four
inward shifts moved the centre to 328930, 324930, 320930 and 316930, bracketing
focus near 315939; four exposure recoveries completed replacement curves.
The final HFR quality check rejected that run. An immediate follow-up passed
at **315942 steps**, HFR **1.052 pixels**, exposure **0.532 ms**, without any
range shifts. All **139 core tests** passed, including both search directions,
travel exhaustion, slope rejection and cancellation during re-centering.

The original autofocus Windows release build and its 127 core tests passed. The portable sidebar
rendered at 1280×1000 with no widget conflicts. Full optical acceptance used
the same engine through `capture-cli`; clicking the autofocus control and
unplug/quit testing during autofocus remain manual acceptance items. The
macOS sidebar is wired to the same commands but could not be built or run
on this Windows host.

### Imaging-system tilt

Connect the camera, focuser and calibrated mount. Choose **Measure Tilt…**
and a TIFF destination. Confirm the star visits C, N, NE, E, SE, S, SW, W,
NW; each location records a verified autofocus minimum and a stack captured
at the initial centre focus, exposure and gain. Confirm the final centre
autofocus leaves the motor at its new optimum and reports drift separately.
Reopen the TIFF and check the focus captions, fit and drift are restored.

Cancel during autofocus and during a mount move. Both motors must stop;
no return-to-centre motion follows cancellation. Completed measurements
should survive in a uniquely named partial TIFF. Test a weak outer star,
camera/focuser/mount/filter-wheel disconnect, USB removal, quit, insufficient
valid outer points and an unwritable destination. Stop and Disconnect must
remain available while other camera, focus, mount and filter controls are
locked throughout the sequence.

On 2 October 2026, preflight identified Xena 585M (`poa-0`, 3856×2180),
ESATTO30136 on **COM4**, and an **EQDIR motor** mount on **COM10**. It used
the mount calibration recorded earlier that day. A real autofocus
cancellation after two samples stopped COM4 at **312413 steps**. A separate
cancellation during the first outer-position mount move stopped both
devices, left COM4 at **316215 steps**, and saved the completed centre
measurement and image to a partial TIFF. That TIFF reopened in the portable
results viewer with its cancelled status, focus caption and missing-image
placeholders; the 1280×1000 offscreen render exited cleanly.
After the user reported audible motor noise, explicit Stop commands were
acknowledged on both axes. Read-only status queries returned `=301` for RA
and `=101` for Dec (both stopped); position counters were unchanged over two
seconds. The user also confirmed no visible movement. COM4 remained stopped.

The first complete traversal used a 1000-step autofocus scan and 100-frame
stacks. All nine common-focus images were captured; seven outer autofocus
readings passed the old HFR verification rule. SW's focus reading was excluded
from the tilt fit because final HFR exceeded the scan minimum by more than
15%. This followed the old software policy; it did not prove inaccurate focus. The partial TIFF reopened with all
images and annotations. It reported **103.5 steps** of directional spread,
**−244.4 steps** radial offset, **52.2 steps** residual RMS, and uncorrected
centre drift of **+195 steps**. Initial centre focus was 316078; the return
autofocus finished at **316273 steps**, stopped. The acceptance harness
returned nonzero because it requires all eight valid outer readings for its
full-pass condition; the application's partial-result path completed normally.

A repeat with 500-step sampling also captured all nine images and accepted
seven outer readings, this time skipping NE on the same verification check.
It reported **654.6 steps** spread, **−508.2 steps** radial offset,
**205.1 steps** RMS and **−73 steps** centre drift. Initial centre was
316249; final centre focus was **316176 steps**. Both reports reopened with
their annotations. These fits differ substantially, so precise optical
repeatability and an all-eight-readings hardware pass remain unverified.
The software retained the quality checks and labelled both reports partial.

After the final run, independent native-driver polls confirmed COM4 stopped
at 316176. COM10 status queries reported both axes stopped (`=101` / `=301`),
with unchanged position counters over two seconds. The portable Focuser
controls rendered at 1280×1200 and the saved reports at 1280×1000; all renders
exited cleanly. No hardware test process remained running.

The Windows release build and all **154 core tests** passed. The final binary
also passed all tilt tests after its cancellation-status update. Tests cover
complete and partial optical sequences, fit geometry/curvature, metadata
round trips, queued mount cancellation, Stop/disconnect, communication faults,
and retaining an in-memory result when file writing fails.

The opt-in acceptance harness runs the shared application engine:

```powershell
core-tests.exe --tilt-hardware --device poa-0 --focuser-port COM4 --mount-port COM10 --calibration-file "C:\path\guide-calibration.json" --exposure 0.5 --focus-step 1000 --stack-count 100 --tilt-output "C:\path\tilt.tif"
```

Use `--tilt-hardware-check` instead for preflight without focus or slew moves.
Add `--tilt-cancel-test focus` or `--tilt-cancel-test mount` for automated
Stop acceptance. Normal core tests never open real devices. Physical USB
removal, quit during movement, clicking the controls, and macOS acceptance
remain manual checks.

### Centre-star backlash diagnostic

On 2 October 2026, a separate diagnostic kept COM10 stopped and scanned the
centre star with ESATTO30136 on COM4. Five passes alternated outward, inward,
outward, inward, outward over **313750–318750 steps**, with **250-step**
sampling. Each pass started with a separate **4000-step** directional take-up
move. Every sample waited for the exact position and stopped motor, settled
for one second, restarted capture, discarded three frames and measured the
median of 15 fresh frames. Exposure stayed at **0.5 ms**, gain at zero. The
star remained central and unsaturated throughout the **1605 measured frames**.

The analysis matched equal-HFR crossings on both defocused flanks and
interpolated between the outward scans surrounding each inward scan to
account for linear drift. Giving both flank medians equal weight yielded
inward-minus-outward offsets of **669.0** and **815.5 steps**: an effective
optical backlash/hysteresis estimate of **742.3 steps**, best reported as
roughly **750 steps**. The individual flank medians ranged from 598.2 to
849.7 steps. Frame bootstrap intervals were 648.3–701.8 and 787.1–845.1;
they cover frame noise only, not curve changes or nonlinear drift. The
146.5-step difference between repeats limits the precision of the estimate.

The existing 500-step autofocus take-up is below this measured offset.
However, even with 4000-step take-up, returning to the last scan's measured
minimum at **316750 steps** gave HFR **1.104**, versus **0.935** during that
scan, an 18% increase that exceeds the usual 15% verification limit. The
experiment therefore supports backlash as a contributor without proving
that it explains all autofocus verification failures. No application or
controller compensation settings were changed. Independent final polls
confirmed COM4 stopped at 316750 and both COM10 axes stopped, with unchanged
mount position counters over two seconds.

The opt-in diagnostic harness saves raw frames' measurements and each point
incrementally; normal core tests do not run it:

```powershell
core-tests.exe --backlash-hardware --device poa-0 --focuser-port COM4 --mount-port COM10 --focus-step 250 --half-span 2500 --preload 4000 --exposure 0.5 --backlash-output "C:\path\backlash.json"
python scripts\analyze-backlash.py "C:\path\backlash.json"
```

Create `<output>.stop` to cancel before the next motion or during polling;
cancellation stops the focuser and preserves completed samples. Analysis
saves a CSV and an analysis JSON beside the raw JSON. It also produces focus
curve plots when Matplotlib is installed. Its synthetic checks recover zero,
positive and negative offsets with linear drift. The Windows release build,
synthetic checks and the real diagnostic run passed. This is a diagnostic
tool, not an application calibration command.

### HFR variability with focus held fixed

A follow-up on 2 October 2026 recorded **1800 consecutive frames over 60
seconds** at **316750 steps**, the last backlash scan's measured minimum.
It issued no focuser move commands and kept COM10 stopped. The camera used
the same centre 512-pixel ROI, **0.5 ms** exposure and gain zero. Every frame
produced an unsaturated valid HFR measurement. The motor was stopped at the
same position before and after recording; independent mount status/counter
queries also confirmed both axes remained stopped and their counters unchanged.

Individual-frame HFR averaged **1.030 pixels**, with sample standard
deviation **0.103 pixels (10.0%)** and a 5th–95th percentile interval of
**0.883–1.165 pixels**. Disjoint groups of five consecutive frames, using the
same median aggregation as autofocus, had standard deviation **0.080 pixels
(7.7%)** and 5th–95th percentiles **0.926–1.139**. Fifteen-frame medians still
had standard deviation **0.079 pixels (7.6%)**, with percentiles
**0.930–1.129**. Ten-second median HFR values varied from 0.936 to 1.119;
longer blocks therefore did not remove all variation in this recording.

Of 359 adjacent five-frame block comparisons, **14 (3.9%)** increased by
more than 15%, despite the unchanged motor position. This demonstrates that
the existing final-verification threshold can be exceeded without a focuser
move; it does not establish the cause of every earlier autofocus failure.
The measured spread includes image/optical variation as well as estimator
noise. The star centroid spanned 1.33 pixels in X and 1.59 in Y while the
mount counters stayed fixed. No autofocus or compensation settings changed.

The opt-in fixed-focus diagnostic and analysis are reproducible with:

```powershell
core-tests.exe --focus-stability-hardware --device poa-0 --focuser-port COM4 --mount-port COM10 --expected-position 316750 --seconds 60 --exposure 0.5 --stability-output "C:\path\focus-stability.json"
python scripts\analyze-focus-stability.py "C:\path\focus-stability.json"
```

The recording saves all frame measurements, including rejection reasons,
incrementally; create `<output>.stop` to cancel. Analysis writes a CSV and
JSON report beside the recording. The Windows release build, summary sanity
checks and real recording passed. Normal core tests do not run this diagnostic.

### HFR from a 15-frame pixel stack

Two further 60-second recordings compared three measurements on each exact
group of 15 consecutive frames: median individual-frame HFR, HFR measured
once on an unaligned pixel-average image, and HFR measured once on the app's
centroid-registered pixel-average image. All measurements used the existing
HFR estimator. The registered stack used bilinear shifts onto the first
frame's centroid. Float averages stayed at the original ADU scale and were
rounded to UInt16 for the estimator. COM4 remained stopped at **316750**;
COM10 stayed stopped with unchanged counters. Exposure was **0.5 ms**, gain
zero and the centre ROI 512 pixels. No autofocus settings changed.

The first recording captured 1690 valid frames, giving **112 paired groups**;
the repeat captured 1793 valid frames, giving **119 paired groups**. The
10 and 8 trailing frames were omitted from the stack comparison. All
individual and stacked measurements were unsaturated and valid.

| Measurement | First recording: mean HFR / SD / relative SD | Repeat: mean HFR / SD / relative SD |
|---|---|---|
| Median of 15 HFR readings | 0.949 / 0.021 px / **2.23%** | 1.133 / 0.018 px / **1.57%** |
| HFR of unaligned 15-frame mean | 0.943 / 0.063 px / **6.65%** | 1.137 / 0.019 px / **1.64%** |
| HFR of registered 15-frame mean | 1.217 / 0.170 px / **13.99%** | 1.202 / 0.049 px / **4.05%** |

In the first recording, 0 of 111 adjacent median-HFR comparisons increased
by more than 15%, versus 4 unaligned-stack and 25 registered-stack
comparisons. None exceeded 15% in the repeat. The registered stacks also
increased average HFR relative to the individual-frame median by 28.3% and
6.1%. These results do not support switching autofocus to the current pixel
stacking method. They establish repeatability at a held motor position,
not the precision of a best-focus estimate. The median HFR changed by about
19% between recordings while the motor stayed fixed; this also limits
comparisons between separate acquisition sessions. Both stack kernels were
checked against independent arithmetic-mean and bilinear references; the
saved example TIFFs retained their 512-pixel size and original ADU scale.

Add `--compare-stacks` to the fixed-focus diagnostic command. Analysis
validates that each stack's individual-HFR median matches its source frames
and writes an additional `-stack-comparison.csv`, alongside the normal CSV
and analysis JSON. The first group's raw image, pixel mean and registered
mean are saved as example TIFFs. The Windows release build, paired analysis
checks, kernel reference checks and both real recordings passed.

### HFR stability on both defocused flanks

The next hardware test held the focuser at **314250** and **319250 steps**,
2500 steps either side of the 316750 focus reference, for **120 seconds per
position**. Both targets were reached with an outward approach after
**4000 steps** of take-up. Recording began only after the exact target and
stopped motor were verified, one second of settling and three discarded
startup frames. No motor moves occurred during either recording. Exposure
stayed at **0.5 ms**, gain zero and the centre ROI 512 pixels. The final
return to 316750 used the same outward approach and recorded a further
**60-second focus control**. The reference is the last scan's measured
minimum; no new autofocus was performed.

| Held position | Frames / duration | Mean HFR | Individual-frame SD / relative SD | Five-frame median SD / relative SD | Fifteen-frame median SD / relative SD |
|---|---|---|---|---|---|
| 314250 (−2500) | 3595 / 120 s | 2.250 px | 0.071 px / **3.15%** | 0.063 px / **2.80%** | 0.061 px / **2.70%** |
| 319250 (+2500) | 3597 / 120 s | 3.234 px | 0.064 px / **1.99%** | 0.057 px / **1.76%** | 0.056 px / **1.73%** |
| Restored reference, 316750 | 1800 / 60 s | 1.129 px | 0.046 px / **4.05%** | 0.034 px / **3.03%** | 0.033 px / **2.90%** |

All **8992 measurements** were valid and unsaturated. Neither defocused
recording had an increase above 15% between successive five-frame medians
(0 of 718 comparisons on each flank). The focus control also had no such
increase (0 of 359). Median HFR changed by **+2.08%** and **−1.35%** between
the first and second one-minute halves on the low and high flanks,
respectively, so variation over time remains present without motion.

The out-of-focus measurements had lower relative variability, especially
on the high side, but their **absolute** HFR scatter was higher than the
restored-focus control. These observations support using the defocused
flanks as useful measurements, without establishing that near-focus HFR is
always unreliable. The previous focused recordings varied more, indicating
that acquisition time and image variation also matter.

Paired 15-frame pixel stacks again gave no improvement over median HFR:
unaligned-stack relative SD was **3.12% / 2.18%** on the low/high flanks,
and registered-stack SD was **3.42% / 2.16%**, versus **2.70% / 1.73%** for
the paired individual-frame medians. Both stack methods and medians used
the exact same 15-frame blocks. No autofocus algorithm or controller
compensation settings were changed.

To prepare a defocused held position, add `--focus-position <steps>` and
`--preload 4000` to the fixed-focus diagnostic command. `--expected-position`
checks the connected starting position before setup. Analysis records
60-second summaries as well as frame/block variability. Setup moves have
travel checks, a 60-second motion timeout, exact-position/idle verification
and stop-file cancellation. The original mode still performs no setup moves
unless a target is explicitly supplied.

Independent final driver polls confirmed COM4 stopped at **316750** and
both COM10 axes stopped with unchanged counters over two seconds. The
Windows release build, analysis regression check and all three hardware
recordings passed. No test process remained controlling a device.

### Five-frame HFR repeatability after alternating jumps

The next experiment alternated **314250 / 319250 steps** (−2500 / +2500
relative to 316750) for **20 visits per location**. Each target was approached
outward from 4000 steps below it, keeping the final approach direction and
take-up distance consistent. Every move was verified at the exact target
with BUSY zero and motor phase stopped; acquisition then waited one second,
restarted capture, discarded three startup frames and measured **exactly five
consecutive valid frames**. A missing star, invalid metric or clipped frame
would abort the jump experiment rather than replace a frame silently.
Exposure stayed at **0.5 ms**, gain zero and the centre ROI 512 pixels.
COM10 remained stopped throughout.

The 40 target acquisitions spanned **165.2 seconds** and used **200 frames**.
All measurements were valid and unsaturated; maximum target peak was 10560
ADU. Variability below is the sample standard deviation **across the 20
five-frame medians at each location**, not across pooled individual frames:

| Target | Mean HFR | SD across returns | Relative SD | Range of five-frame medians |
|---|---|---|---|---|
| 314250 (−2500) | **2.331 px** | **0.058 px** | **2.47%** | 2.214–2.419 px |
| 319250 (+2500) | **3.188 px** | **0.055 px** | **1.73%** | 3.098–3.322 px |

Average individual-frame SD within each five-frame visit was 0.039 and
0.032 pixels on the low/high targets. Mean HFR changed by +0.58% / −0.17%
between the first and last ten visits at each target. No successive return
to the same target increased HFR by more than 15%; the largest increases
were 7.85% and 5.56%. The return-to-return spread was comparable to the
earlier held-position five-frame medians (2.80% / 1.76%), although those
recordings were taken at a different time. This experiment includes image
variation, focus drift and mechanical return repeatability and does not
isolate those contributions.

The opt-in diagnostic reuses the stopped-position and fresh-frame checks
from the backlash harness:

```powershell
core-tests.exe --focus-jump-hardware --device poa-0 --focuser-port COM4 --mount-port COM10 --focus-reference 316750 --half-span 2500 --preload 4000 --visits-per-position 20 --exposure 0.5 --jump-output "C:\path\focus-jumps.json"
python scripts\analyze-focus-jumps.py "C:\path\focus-jumps.json"
```

The reference must match the stopped starting position. The experiment
saves each visit incrementally and checks `<output>.stop` during motion and
acquisition. Cancellation stops the focuser and does not start a return
move. Successful completion returns to the reference with the same outward
take-up and saves a final five-frame measurement. The analysis verifies the
alternating sequence, target positions and five-frame medians, and writes
per-visit and per-location summary CSVs plus an analysis JSON. Normal core
tests do not run this diagnostic.

The Windows release build, independent per-location summary checks and real
40-visit experiment passed. No autofocus or controller compensation settings
were changed. Independent native-driver polls confirmed COM4 stopped at
**316750** and both COM10 axes stopped with unchanged position counters over
two seconds. No device-controlling test process remained running.

### Production autofocus acquisition and fit policy

Autofocus now separates sample spacing from **4000-step outward take-up**.
The full first-position approach, every reversed baseline, re-centred scan,
fitted focus, recovery target and tilt common-focus restoration must fit
calibrated travel. Near a boundary the search may select a different fully
valid window; it never shortens take-up. Controller compensation is unchanged.
Both applications and `capture-cli --focus-take-up` use the shared engine.
Settings are snapshotted for the whole autofocus or tilt run.

Production acquisition confirms the exact stopped position, settles for one
second, restarts capture on the camera worker, discards three fresh frames,
and measures five usable raw-frame HFRs. Retrieval timestamps alone cannot
identify old sensor exposures in an SDK queue, so the acknowledged restart
is part of the freshness protocol. Timestamp gates also reject motion-era,
duplicate and future frames. A block has a timeout and at most 24 rejected
frames; rejected readings and high-resolution timestamps are retained.
Exposure changes discard the entire curve. Gain remains fixed. No pixel
stack is used for autofocus.

The fit normalises motor coordinates about the middle sample by the scan
half-span. It fits all nine positions with damped QR least squares and one
Huber reweighting pass (2.5 block uncertainties, minimum robust weight 0.05).
It does not iteratively remove points. Block uncertainty is the maximum of
the scaled MAD, **0.05 px**, and **3% of that block's HFR**. These are initial
policy floors, not universal camera constants. The baseline and middle
sample revisit the same position; their absolute difference can raise the
floor for that curve. Five adjacent readings are not assumed independent
and their scatter is not divided by the square root of five.

The symmetric model is `sqrt(h0^2 + k^2*u^2)`. The restrained asymmetric
model adds `t*u`, with `|t/k| <= 0.45`; the implementation uses the actual
minimum `centre - t*h0/(k*sqrt(k^2-t^2))`. Asymmetry requires an AICc
improvement greater than six and stable leave-one-out estimates. Otherwise
the symmetric model is preferred. Each fit needs two supporting points on
both flanks, a rise exceeding both 5% of the fitted minimum and two block
uncertainties, acceptable robust residuals, and a minimum inside the scan.
At most one point may have robust weight below 0.5. Optimisation uses three
fixed starting centres and at most 100 iterations per start. Each omission
must move focus by at most 0.75 scan steps; the approximate position
uncertainty must be at most one scan step. The reported uncertainty is the
larger of linearised model sensitivity and jackknife sensitivity. It is
**not an empirically calibrated confidence interval or a guaranteed 95%
interval**. Diagnostics include predictions, residual RMS, block
uncertainties, robust weights, downweighted indices and all nine omissions.
The displayed fit uncertainty describes the nine-point position estimate.

**Current policy: final HFR is diagnostic only.** Acceptance requires the
supported curve, bounded residuals, stable leave-one-out position estimates,
valid travel and confirmation that the focuser reached the fitted target and
stopped. Three five-frame final blocks are recorded with approximately one
second between them and no intervening movement. Their HFR level or variation
cannot reject focus, request a bracket, change position, retune exposure or
restart the curve. A saturated or unavailable final HFR is recorded explicitly
with timestamps and partial readings; the supported result retains its position
and has an optional final HFR. Cancellation, disconnect and motor errors still
interrupt the run. Saturation during curve acquisition still restarts the
complete curve at one exposure. Search remains limited to 16 re-centres,
four saturation restarts and 24 curve attempts.

Earlier recordings below used prediction/baseline HFR guards and one local
recovery bracket. Those are historical results, not validation of the current
policy. Recovery fields remain readable in old reports, but production no
longer invokes a final-HFR-based bracket. The opt-in legacy comparison harness
alone retains its historical 15% rejection rule for an old-routine baseline.

Tilt schema 2 carries the acquisition settings and focus diagnostics while
retaining exactly nine primary autofocus samples; recovery samples stay
separate. Schema 1 reports remain readable. Plane fitting and its weighting
are unchanged. Detailed TIFF metadata has a bounded 2 MiB capacity and the
constellation file limit is 6 MiB to accommodate it.

The opt-in comparison uses the production shared engine and retains the old
three-point/one-step/single-verification policy only for comparison:

```powershell
core-tests.exe --autofocus-repeatability --device poa-0 --focuser-port COM4 --mount-port COM10 --focus-step 1000 --focus-take-up 4000 --half-span 2500 --trials 10 --exposure 0.5 --focus-output .build-win/autofocus-comparison-20261002.json
python scripts/analyze-autofocus-repeatability.py .build-win/autofocus-comparison-20261002.json
```

It first reads hardware state and establishes a fresh production reference,
then performs ten trials per policy with alternating starting sides and
balanced interleaving. All attempted runs, failures, exposure changes,
durations, verification and recovery are saved. A `.stop` file beside the
output stops the current attempt and prevents restoration. Successful
completion restores the recorded reference through full outward take-up and
confirms COM10's stopped axes and unchanged counters. Smaller-spacing trials
are separate; `--production-only --focus-step 500` skips the old policy.
`--autofocus-preflight` performs hardware checks without a focus scan.

### Autofocus implementation acceptance, 2-3 October 2026

Record timestamps are UTC; final validation continued after local midnight
in Helsinki. Files retain the date of their particular acquisition series.

The original ignored recordings were preserved. Re-analysis in
`.build-win/autofocus-historical-noise-analysis-20261002.json` confirms 14
consecutive five-frame median increases above 15% in the stationary
`focus-stability-center` recording, despite no motor movement. The two
defocused stationary blocks had 2.80% and 1.76% relative SD; increasing to
15 readings gave 2.70% and 1.73%. Twenty alternating visits per flank with
4000-step take-up had absolute SD 0.0577 and 0.0551 px. These describe this
setup and acquisition period, and do not calibrate focus-position confidence.

Preflight identified **Xena585M / poa-0**, **ESATTO30136 / COM4**, stopped at
**316750**, with calibrated maximum **731000**. COM10's raw axis status and
counter responses were `=101`, `=301`, `=EA5177`, `=4F1799`, unchanged over
two seconds. No ESATTO controller compensation was changed.

An initial engineering reference attempt is retained in
`.build-win/autofocus-comparison-20261002.json`: its global symmetric fit was
316186 with approximate uncertainty 50 steps, but stable verification HFR
1.007/1.022/1.019 exceeded the model minimum 0.868. It failed its narrow
recovery bracket. This led to including the observed residual envelope in
verification, with a regression test for that exact recording.

The next balanced experiment is retained in
`.build-win/autofocus-comparison-20261002-final.json` and its `-analysis.json`
and `-attempts.csv` companions. Despite the filename, this is the **initial
verification policy**, before independent local-prediction recovery. A fresh
reference attempt succeeded at 316040 with one 52-step correction. Ten old
and ten initial-production trials alternated starts at 313540 and 318540;
ordering was balanced within pairs. Both used 1000-step spacing. Requested
exposure was 0.5 ms and gain 0; actual curve exposures were 0.567-1.418 ms
for old and 0.569-3.335 ms for initial production, including saturation
restarts. Every attempt was retained.

| Initial-policy comparison | Old | Initial production |
|---|---:|---:|
| Successes / attempts | 10 / 10 | 6 / 10 |
| Successful-position mean (steps) | 316038.4 | 316079.7 |
| Successful-position SD (steps) | 97.0 | 98.0 |
| Range (steps) | 315916-316243 | 315897-316174 |
| High-start minus low-start mean (steps) | -77.6 | -120.5 |
| Recovery attempts / successes | 0 / 0 | 4 / 0 |
| Mean run duration (seconds) | 44.6 | 83.1 |
| Approximate fitted uncertainty, mean (steps) | unavailable | 92.5 |
| Descriptive time slope (steps/minute) | -8.1 | -11.6 |

This series **does not establish improvement**. Initial-production successes
were censored by four verification failures, and starting-side success counts
were unequal (two low, four high). Detrended SD was 75.7 old and 26.5 initial
production, but subtracting a fitted trend from such a small series does not
prove better repeatability. The near-focus HFR mismatch motivated the bounded
local-prediction recovery tested in the next series.

This experiment restored **316040**, confirmed the focuser stopped, and
confirmed the same four COM10 responses and unchanged counters over two
seconds. The cancelled path is tested separately and never starts restoration.

An intermediate local-prediction policy was tested in a separate balanced
series, `.build-win/autofocus-comparison-local-recovery-20261002.json`, with
its analysis and CSV companions. Its source is archived under
`.build-win/autofocus-policy-v2-source` and its source/binary hashes are in
`.build-win/autofocus-local-recovery-manifest-20261002.json`. Both policies
used 1000-step spacing, with starts 2500 steps either side of fresh reference
316062. All ten attempts per policy were retained.

| Intermediate-policy comparison | Old | Intermediate production |
|---|---:|---:|
| Successes / attempts | 10 / 10 | 7 / 10 |
| Successful-position mean (steps) | 316100.9 | 316048.9 |
| Successful-position SD (steps) | 121.4 | 104.8 |
| Range (steps) | 315938-316359 | 315887-316214 |
| High-start minus low-start mean (steps) | -162.2 | 135.0 |
| Recovery attempts / successes | 0 / 0 | 6 / 3 |
| Mean run duration (seconds) | 41.4 | 99.3 |
| Approximate fitted uncertainty, mean (steps) | unavailable | 50.5 |
| Descriptive time slope (steps/minute) | 0.8 | -8.0 |

Actual curve exposures were 0.478-1.106 ms old and 0.462-3.751 ms production,
gain 0. This series also **does not establish improved repeatability**:
three production failures censored the successful-position statistics, and
fit uncertainty understated their observed spread. Attempt 10 independently
supported position 316082 with bracket HFR 1.2504/0.8919/1.3574, but stable
return blocks 1.0696/1.0722/1.0711 failed the local centre's 15% guard.
Another bracket had inadequate right-flank slope. Those observations led to
the then-current flank-advantage recovery check and stronger bracket spacing,
with a regression test retaining the exact false-rejection values. The
intermediate series restored 316062, confirmed the focuser stopped and the
same four COM10 responses unchanged over two seconds.

The earlier flank-advantage policy completed a fresh balanced comparison in
`.build-win/autofocus-comparison-position-verification-20261003.json`, with
`-analysis.json`, `-attempts.csv`, `-exposure-history.json` and console log
companions. Preflight read stopped position 316062; a new production
reference succeeded at **316049**. Twenty trials alternated starts at
**313549 / 318549**, with ten attempts per policy, **1000-step spacing**,
requested 0.5 ms exposure and gain 0. Ordering was old-first in six pairs and
new-first in four, balanced within the two starting-side strata.

| Earlier same-spacing comparison | Old | Flank-advantage production |
|---|---:|---:|
| Successes / attempts | 10 / 10 | 10 / 10 |
| Successful-position mean (steps) | 315986.6 | 316033.2 |
| Successful-position SD (steps) | 82.4 | 35.4 |
| Range (steps) | 315881-316155 | 315979-316073 |
| High-start minus low-start mean (steps) | -128.8 | 20.8 |
| Failures | 0 | 0 |
| Recovery checks / successful runs after a check | 0 / 0 | 4 / 4 |
| Mean run duration (seconds) | 41.6 | 80.4 |
| Duration range (seconds) | 29.0-54.5 | 50.5-119.1 |
| Approximate fitted uncertainty, mean (steps) | unavailable | 65.6 |
| Descriptive time slope (steps/minute) | -2.7 | 0.4 |

Two recovery brackets supported the original position; two permitted one
bounded correction. Original fitted positions, including the corrected
runs, had SD 41.5 steps. Actual configured scan exposures were
**0.460-3.793 ms old** and **0.499-3.606 ms production**, including restarts.
Old JSON retained only completed curves (0.460-1.275 ms); its console and
exposure-history companion preserve partial-scan medians and control events.
Production retains partial curves with their individual readings.

The final production series had **57% lower observed position SD** and a
smaller starting-side difference. All trials succeeded, so its spread is
not censored by failures. Both policies had zero failures in this particular
comparison; it cannot establish a lower population failure rate. The exact
previous false rejection is covered by a regression test and the revised
recovery criterion. Mean model uncertainty 65.6 steps exceeded the observed
35.4-step SD here, whereas the intermediate policy underestimated spread in
its separate recording. It remains an approximate estimate, not a calibrated
confidence interval.

Old first/second-half position means were 316016.0 / 315957.2; production
means were 316032.8 / 316033.6. Descriptive detrended SDs were 80.0 / 35.3
steps. This provides evidence of improved positional repeatability in this
series, with little production time trend; ten attempts per policy cannot
separate all temporal, acquisition and model effects or establish absolute
optical-focus accuracy. A lower final HFR is not the acceptance evidence.

Record validation checked **335 five-frame blocks**, including baselines:
medians, ordered high-resolution timestamps, three startup discards in
production, uniform gain/exposure within each curve, actual model minima,
and separate primary/recovery samples. The harness restored **316049**
through the full 4000-step outward approach, confirmed the focuser stopped,
and confirmed both mount axes and the same counters unchanged over two
seconds. The smaller-spacing experiment is recorded separately below.

The separate **500-step, production-only** series is retained in
`.build-win/autofocus-smaller-spacing-20261003.json` and its analysis, CSV
and log companions. It established fresh reference **315969**, then retained
all ten alternating trials from **313469 / 318469** with the same 4000-step
take-up and acquisition settings.

| Smaller-spacing result | Production, 500 steps |
|---|---:|
| Successes / attempts | 6 / 10 |
| Inconclusive recovery brackets | 4 |
| Successful-position mean / SD (steps) | 315922.7 / 44.7 |
| Successful-position range (steps) | 315865-315985 |
| High-start minus low-start mean (steps) | -74.8 |
| Successful low / high starts | 1 / 5 |
| Recovery checks / successful runs after a check | 4 / 0 |
| Mean duration / range (seconds), all attempts | 103.0 / 79.8-140.0 |
| Mean approximate fitted uncertainty (steps), successes | 67.9 |
| Original fitted-position SD (steps), all attempts | 51.2 |
| Descriptive time slope (steps/minute), successes | -3.1 |

Actual curve exposures were 0.563-3.683 ms, gain 0. In the first failed
bracket, the centre was 1.121 px and the two flanks only 1.139 / 1.163 px:
their 0.018 / 0.042 px rises did not support a local minimum above the
measurement floor. Its original fit was 315974 with approximate uncertainty
51.3 steps and residual RMS 0.053 px. All four failures remain recorded;
they were not replaced. The success-only spread and side difference are
censored, and this time-separated series has no old 500-step control. It
**does not demonstrate an advantage from smaller spacing**. These four
failures came from the earlier HFR-triggered bracket policy and do not
predict acceptance under the current diagnostic-only policy. Its 500-step
position repeatability has not been revalidated; 1000-step spacing remains
the initial sampling choice, with separately configured 4000-step take-up.
The change of reference and mean between series cannot by itself separate
temporal drift from scan-range/model effects or establish optical accuracy.

Validation checked **297 five-frame blocks**, including baselines, uniform
curve exposure/gain, fresh discards and high-resolution timestamps. The
harness restored **315969** through full outward take-up, confirmed stopped
focus and both stopped mount axes with unchanged counters over two seconds.

Additional cancellation checks are separate from the repeatability trials.
The first active-command cancellation, in
`.build-win/autofocus-motion-cancel-20261003.json`, stopped before measurable
travel and left 315969 unchanged. No automatic restoration was recorded.
A subsequent travel-check setup, retained as
`.build-win/autofocus-motion-cancel-travel-20261003.json`, failed before
autofocus began: MOVE_ABS 311969 was acknowledged, but stopped feedback was
316002. The harness bounded the wait, issued Stop and did not continue the
experiment. The cause of that isolated post-cancellation command/position
mismatch remains unresolved. It is not counted as a successful cancellation
test or omitted from the recordings. An explicit native cleanup restored
315969 through full take-up before one bounded repeat.

That repeat exercised the **production shared engine's Stop during measured
travel**. The motion started at 315969 toward 307969; cancellation was
triggered with BUSY=1 at 312205. Subsequent native preflight confirmed
**312002, stopped**, with the same COM10 status/counters. The console contains
no MOVE_ABS after the Stop, and the cancelled record contains no restoration.
Its expected cancellation exit was 1, rather than a successful autofocus
exit. Evidence is in `.build-win/autofocus-motion-cancel-repeat-20261003.json`,
its `.stop-trigger.json`, `-proof.json`, console and stopped-preflight files.

Only after that stopped-state/no-restoration check, a separate explicit test
cleanup held 312002 fixed for eight seconds (240 frames), then restored
**315969** using **311969 -> 315969**. It is recorded in
`.build-win/autofocus-final-cleanup-20261003.json`. Final native preflight in
`.build-win/autofocus-final-state-20261003.json` confirmed 315969 stopped,
maximum 731000, and unchanged stopped COM10 axes/counters over two seconds.
The cleanup was a separate test command; cancellation itself initiated no
restoration. Hardware disconnect during motion and interactive UI Stop clicks
were not exercised here; their shared-core regressions passed.

The final Windows release `core-tests` passed **159 checks** in
`.build-win/autofocus-position-policy-core-suite.log` (exit 0). This includes analytical
symmetric/asymmetric minima, unequal scatter/outliers, bounded failure,
large coordinates/travel bounds, startup discards/stale exclusion, repeated
verification, significant correction versus preserving a supported position,
exposure recovery/re-centering, cancellation in every phase, interlocks,
disconnect, Windows async coordinates, simulated tilt sequencing, and old/new
metadata round trips. The simulated tilt camera now evaluates its Gaussian
at sensor pixel centres, matching the pipeline; the same 32-pixel centering
tolerance remains in force. No production mount or tilt plane algorithm was
changed for that fixture correction.

Release `capture-cli` and `CollimationCamera` built through `scripts/win.cmd`.
The import check, CLI help and analysis-script regression passed. Runtime
files were staged through `scripts/stage-win.ps1`. The portable sidebar was
rendered at 1280x1200 into `.build-win/autofocus-position-policy-sidebar.png`, inspected,
and exited **0** with no widget ID conflict; the separate 4000-step control
is visible. Both sidebar integrations are source-tested. **macOS compilation
and execution were not performed in this session.** Real hardware acceptance
uses the centre ROI and shared production engine; no full hardware tilt
traversal is repeated. That policy was validated by the earlier comparison above; the
intermediate recordings are retained, rather than pooled across policies.
Source/binary hashes for that earlier policy are retained in
`.build-win/autofocus-position-policy-manifest-20261003.json`, with source
copies under `.build-win/autofocus-policy-v3-source`. The fit regression,
engine verification, metadata, CLI help, import and analysis checks have
separate `autofocus-position-policy-*` logs. Build logs use the same prefix.


### Final HFR as diagnostics only, 3 October 2026

The current production policy is **`curve-fit-position-only`**. Final HFR
cannot invalidate a supported fit, initiate a bracket/correction, change
exposure or restart the curve. A bounded diagnostic acquisition may return
unavailable HFR; the focus result and tilt reading retain their position.
Travel validation, stopped-target confirmation, curve support/residuals,
leave-one-out sensitivity and cancellation remain enforced. Old report fields
named `verification` and `recovery` remain readable; production uses the former
for diagnostic blocks and leaves recovery empty. The opt-in legacy comparison
alone retains its old HFR rejection rule.

Windows release core-tests, capture-cli and CollimationCamera builds passed.
The complete core suite passed **158 checks**, including persistently high,
variable, missing and saturated final HFR without a focus veto or extra
movement; scan exposure recovery; re-centering; cancellation during settling,
collection, final diagnostic collection and the inter-block interval; interlocks,
disconnect; Windows async-coordinate regression; both UI integrations; and
old/new tilt metadata round trips, including absent final HFR. The first full
suite had one one-second acquisition timeout in the inward re-centering
fixture, before any final measurement. The isolated re-centering check passed;
the wide-star fixture was given two seconds of scheduling headroom without
changing production timing, counts or optical acceptance. Its diagnostic log
and the initially failing suite are retained. The final complete suite passed
in `.build-win/autofocus-diagnostic-only-final-core-suite.log`.

The import check, CLI help, missing-HFR analysis regression and `git diff
--check` passed. Runtime staging was repeated successfully after the test
process exited. The portable sidebar rendered at 1280x1200 into
`.build-win/autofocus-diagnostic-only-sidebar.png`, was inspected and exited
**0**, with the 1000-step sampling and separate 4000-step take-up controls
visible and no widget ID conflict. Both apps use the shared help/status and
engine. **macOS compilation and execution were not performed here.**

Real hardware used Xena585M `poa-0`, centre 512-pixel ROI, gain 0, COM4 focus
and COM10 mount. Native preflight read **315969 / 731000**, stopped, with
unchanged mount status/counters over two seconds. A new shared-production
reference was **312265**, rather than reusing the previous session's focus.
Twenty old/new trials alternated starts at **309765 / 314765**, five on each
side per policy, with old-first in six pairs and new-first in four. All trials
used 1000-step spacing and requested 0.5 ms exposure; production take-up was
4000 steps. Every attempt, including failure, remains recorded in
`.build-win/autofocus-diagnostic-only-comparison-20261003.json`, with console
log, `-analysis.json`, `-attempts.csv` and `-exposure-history.json` companions.

| Interleaved same-spacing comparison | Old | Diagnostic-only production |
|---|---:|---:|
| Successful attempts / attempted | 9 / 10 | 10 / 10 |
| Mean successful position (steps) | 312269.3 | 312245.6 |
| Successful-position SD (steps) | 104.2 | 56.5 |
| Successful-position range (steps) | 312152-312530 | 312169-312343 |
| High-start minus low-start mean (steps) | -87.6 | -21.2 |
| Successful low / high starts | 4 / 5 | 5 / 5 |
| All measured final targets SD, including rejected target (steps) | 98.7 | 56.5 |
| HFR-based rejections | 1 | 0 |
| Recovery moves | 0 | 0 |
| Mean duration / range (seconds), all attempts | 42.2 / 28.4-55.2 | 69.2 / 50.6-95.8 |
| Mean approximate fitted uncertainty (steps) | unavailable | 51.2 |
| Descriptive time slope (steps/minute) | -10.2 | -5.9 |
| SD after subtracting descriptive linear trend (steps) | 77.3 | 41.0 |

Production finished at its original fitted position in every attempt. Four
production runs (attempts 4, 10, 12 and 15) had saturated final frames and
therefore unavailable final HFR; all three diagnostic issues, timestamps and
partial readings were retained in each. These results were **not rejected or
corrected**. The old routine rejected attempt 14 after reaching **312239**:
its final median was **1.1163 px**, compared with a lowest scan median of
**0.9484 px**, a **17.7%** increase. That is a rejection under the old software
policy, not independent proof of inaccurate focus.

Selected exposure settings ranged **0.550-5.721 ms** old and
**0.676-5.361 ms** production, including exposure-recovery periods. Stored
complete/partial-curve sample exposures ranged 0.550-1.144 ms old and
0.676-3.507 ms production. Legacy partial-scan raw readings are unavailable;
its partial medians and exposure-control events are preserved in the console
and companion history. Production preserves its partial curves and readings.
Validation checked **305 completed five-frame blocks**, including baselines,
uniform curve exposure/gain, medians, fresh discards and high-resolution
timestamps; all ten production results matched the actual fitted minimum and
had no recovery measurements. The final diagnostic issues remain separate
from the nine primary samples.

Observed successful-position SD was **46% lower**; including the old rejected
final target gives a **43% lower** position SD. This is position evidence,
not a conclusion based on lower final HFR. It is a small descriptive sample,
with one censored old success and a downward trend in both series: first/second
half means were 312331/312220 old and 312280.2/312211 production. Interleaving
reduces time-order bias but cannot establish population failure rates,
absolute optical accuracy or a causal attribution to one component. Approximate
fit uncertainty (mean 51.2 steps) is of the same order as observed SD (56.5),
but is **not an empirically calibrated confidence interval**. The 500-step
spacing experiment above used the earlier bracket policy; current 500-step
repeatability has not been revalidated.

The harness restored **312265** using **308265 -> 312265**, confirmed stopped
focus and both stopped mount axes with the original counters over two seconds.
A separate native preflight in
`.build-win/autofocus-diagnostic-only-final-state-20261003.json` again read
**312265**, stopped. COM10 responses remained exactly
`=101`, `=301`, `=EA5177`, `=4F1799`. No full hardware tilt traversal was
repeated. Source/binary hashes and source copies are retained in
`.build-win/autofocus-diagnostic-only-manifest-20261003.json` and
`.build-win/autofocus-policy-v4-source`.

## 7. The filter wheel

Connect a Phoenix wheel, read the aliases stored on it, and move to a slot.
The aliases should show next to the 1-based positions.

## 8. Then ZWO

Repeat 1 through 5. Two things are ZWO-specific:

- ZWO reports only the binnings the model supports, often just 1 and 2. The
  full-frame search clamps to that list; check it still finds the star.
- RAW16 is MSB-aligned, so a 12-bit camera saturates at 65520. Overexpose
  deliberately once and check that clipped pixels paint red.

## What to send back

The log file, and `CollimationCamera.exe --snapshot shot.png --snapshot-after 10`
taken while the camera is connected. That renders the whole window to a PNG
without needing a screen, so it works over remote desktop.
