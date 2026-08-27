# Player One SDKs

This app loads Player One dylibs at runtime (no link-time dependency):

- `libPlayerOneCamera.dylib` — cameras (Poseidon-M and other SDK cameras)
- `libPlayerOnePW.dylib` — Phoenix filter wheel (PW5 / PW7 / PW8)

## Official SDK

Download the macOS Camera SDK and Filter Wheel SDK from:

https://www.player-one-astronomy.com/service/software/

Copy the dylibs into this folder.

## Convenience fetch

From the repo root:

```bash
scripts/fetch-sdk.sh
```

The fetch script uses the macOS binaries redistributed with INDI when official zip URLs are not set. Prefer the official SDKs for production use.

The dylibs are gitignored. The simulator camera works without them; filter-wheel controls stay disconnected until `libPlayerOnePW.dylib` is present and a Phoenix wheel is plugged in.
