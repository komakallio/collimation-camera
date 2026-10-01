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
