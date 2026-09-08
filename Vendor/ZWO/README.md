# ZWO ASI SDK

The app loads the ZWO camera library at run time; there is no link-time
dependency.

- macOS: `libASICamera2.dylib` (universal, built here with `lipo` from the
  vendor's x86_64 and arm64 slices) plus `libusb-1.0.0.dylib`
- Windows: `ASICamera2.dll`

## Official SDK

https://www.zwoastro.com/software/product-sdk/

Copy the x64 library from the package into this folder.

## Convenience fetch

From the repository root:

```bash
scripts/fetch-sdk.sh
```

```powershell
scripts\fetch-sdk.ps1
```

## Notes

- The vendor's arm64 macOS slice is built with a macOS 15 minimum, so ZWO
  cameras need macOS 15 on Apple silicon. The rest of the app runs on macOS 14.
- Both slices link `libusb-1.0.0.dylib`, which the vendor does not bundle, and
  the arm64 one hard-codes the Homebrew path. `fetch-sdk.sh` copies libusb next
  to the dylib, rewrites the reference to `@loader_path`, and re-signs — Apple
  silicon rejects a modified dylib whose signature no longer matches.
- Windows needs the ZWO camera driver (V3.28 or newer) installed separately.
  macOS needs no driver.
- Only RAW16 mono is used. RAW16 data is MSB-aligned, so a 12-bit camera
  saturates at 65520 and the shared clip threshold holds.
- The binaries are gitignored. Without them the app simply lists no ZWO
  cameras.
