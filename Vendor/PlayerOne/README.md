# Player One Camera SDK

This app loads `libPlayerOneCamera.dylib` at runtime (no link-time dependency).

## Official SDK

Download the macOS Camera SDK from:

https://www.player-one-astronomy.com/service/software/

Copy `libPlayerOneCamera.dylib` into this folder.

## Convenience fetch

From the repo root:

```bash
scripts/fetch-sdk.sh
```

The fetch script uses the macOS binary redistributed with INDI when the official zip URL is not set. Prefer the official SDK for production use.

The dylib is gitignored. The simulator camera works without it.
