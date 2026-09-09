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
  clipped; clipped pixels paint red.
- **Auto-center star**. The ROI should follow the star without the stream
  restarting — the fps line in the log should not drop while it moves.
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
- Unplug the camera during Center: the mount work should end with the
  disconnect error rather than `noStar` four seconds later, the mount should
  stay connected, and Calibrate should work again after the camera reconnects.

Without a mount, a com0com virtual pair or a USB serial loopback is enough to
check that the port is listed and that Connect fails with `unrecognized`
rather than crashing.

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
