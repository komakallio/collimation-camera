# SDL3

The portable app links SDL3 (`CollimationCamera`); the SwiftUI macOS app does
not use it.

- Windows: this folder holds `include/` and `lib/x64/` from the
  `SDL3-devel-<version>-VC.zip` release, and `SDL3.dll` ships beside the
  executable.
- macOS: SDL3 comes from Homebrew through `pkg-config`, so this folder is
  unused. `brew install sdl3`.

The version the Windows build is pinned to is in `scripts/fetch-sdk.ps1`
(`$sdlVersion`). SDL 3.4 or newer is required: the app uses `SDL_LoadPNG` for
the window icon and `SDL_EVENT_PINCH_UPDATE` for trackpad zoom.

## Official download

https://github.com/libsdl-org/SDL/releases

Take the `-VC.zip` for Windows.

## Convenience fetch

From the repository root:

```powershell
scripts\fetch-sdk.ps1 -SDL3Only
```

`-SDL3Only` skips the camera and filter wheel SDKs, which is what CI wants.
The script also copies `SDL3.dll` into the SwiftPM output directories, since
SwiftPM has no post-build hook.

## Notes

- The include path must be the directory holding `SDL3/`, because SDL's
  headers include each other as `<SDL3/SDL_x.h>`.
- `Sources/CSDL3/shim.h` redefines the `SDL_WINDOW_*` flags as plain
  literals: SDL spells them with the function-like macro `SDL_UINT64_C(...)`,
  which Swift's importer cannot evaluate. The values are ABI, not
  implementation detail.
- Everything but this README is gitignored.
