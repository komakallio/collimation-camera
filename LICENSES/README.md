# Third-party licenses

One entry per component that ships inside a package. The verbatim texts in
this directory are the ones whose licenses require them to travel with the
binary; the rest name the license and where its text is.

`scripts/package-app.sh` and `scripts/package-portable-mac.sh` copy this
directory into `Contents/Resources/LICENSES`, and `scripts/package-win.ps1`
copies it next to the executable, minus the libusb entry, which ships only in
the macOS packages.

| Component | Used by | License | Text |
|---|---|---|---|
| SDL3 | portable app | zlib | `SDL3-LICENSE.txt` |
| Dear ImGui | portable app | MIT | `imgui-LICENSE.txt` |
| cimgui | portable app | MIT | `cimgui-LICENSE.txt` |
| DejaVu fonts | portable app | Bitstream Vera and Arev, permissive | `DejaVu-LICENSE.txt`, also `Resources/Fonts/LICENSE.txt` |
| Player One camera and filter wheel SDK | both apps | Player One's own terms, redistribution permitted | `PlayerOne-license.txt` |
| ZWO ASI camera SDK | both apps | ZWO's own terms, redistribution permitted | In the SDK download, <https://www.zwoastro.com/software/product-sdk/> |
| libusb | macOS packages only | LGPL-2.1-or-later | `libusb-COPYING.txt` after `scripts/fetch-sdk.sh` has run on a Mac; otherwise <https://github.com/libusb/libusb/blob/master/COPYING> |
| Swift runtime | Windows package only | Apache-2.0 with the Runtime Library Exception | <https://swift.org/LICENSE.txt> |
| Microsoft C++ runtime | Windows package only | Microsoft's redistributable terms | <https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files> |

## When a pin moves

Nothing refreshes these automatically. Bumping SDL3 in `scripts/fetch-sdk.ps1`
or the vendored cimgui/imgui in `scripts/vendor-cimgui.sh` means copying the
new upstream licence text over the file here in the same commit — the projects
change theirs rarely, but a stale one is a wrong claim about what ships.
`Sources/CImGui/vendor/UPSTREAM.md` records the pinned cimgui SHA and imgui
version; `$sdlVersion` in `fetch-sdk.ps1` records SDL3's.

`scripts/fetch-sdk.ps1` and `scripts/fetch-sdk.sh` save any licence or EULA
file they find in a vendor archive here, named after the vendor, so a package
built after a fetch carries the vendors' own terms rather than only this
pointer.
