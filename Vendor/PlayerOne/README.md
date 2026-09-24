# Player One SDKs

The app loads the Player One libraries at run time; there is no link-time
dependency.

- macOS: `libPlayerOneCamera.dylib` (cameras) and `libPlayerOnePW.dylib`
  (Phoenix filter wheel, PW5 / PW7 / PW8)
- Windows: `PlayerOneCamera.dll` and `PlayerOnePW.dll`

## Official SDK

Download the Camera SDK and Filter Wheel SDK for your platform from:

https://www.player-one-astronomy.com/service/software/

Copy the libraries into this folder. On Windows they are under `lib\x64\` in
each package.

## Convenience fetch

From the repository root:

```bash
scripts/fetch-sdk.sh
```

```powershell
scripts\fetch-sdk.ps1
```

The macOS script uses the binaries redistributed with INDI when the official
zip URLs are not set. Prefer the official SDKs for production use.

## Notes

- Windows needs the Player One camera driver installed separately
  (`Player_One_Camera_Driver_V1.6.x` from the same page). macOS needs no
  driver.
- The macOS dylibs reference `@rpath/libusb-1.0.0.dylib`. `fetch-sdk.sh` puts
  one copy of libusb next to them, shared with the ZWO library.
- The binaries are gitignored. The simulator camera works without them, and
  the filter-wheel controls stay disconnected until the wheel library is
  present and a Phoenix wheel is plugged in.
