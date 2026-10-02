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
  **Autofocus step** that changes HFR visibly and exceeds backlash. Confirm
  there is room for five inward and four outward steps. Start Autofocus.
- Confirm five initial frames precede motion, nine positions are sampled
  outward, the fitted target is approached outward, and final HFR is within
  15% of the scan minimum. Check the logged samples and inspect the star.
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
readings passed verification. SW was correctly skipped when final HFR was
worse than the accepted scan minimum. The partial TIFF reopened with all
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
