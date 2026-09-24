## What changed

<!-- One or two sentences. What a reader needs to know that the diff does not say. -->

## Checklist

- [ ] Core or UI-model change has a test in `CoreTests`.
- [ ] Both apps updated, or `PARITY.md` explains the difference.
- [ ] `swift run core-tests` green on macOS and Windows (CI).
- [ ] Simulator smoke test on the portable app.
- [ ] New portable sidebar widget: `--snapshot` run and its exit status
      checked, which is the only thing that catches two widgets sharing an
      ImGui id.
- [ ] Hardware note if capture, mount, or wheel code changed.
- [ ] A new vendored binary or library has its license text in `LICENSES/` and
      a row in `LICENSES/README.md`.
- [ ] A change to one copy of the stretch shader changes **all four** — the CPU
      `StretchParams.apply`, `MetalRenderer.shaderSource` (what the macOS
      release renders), `ShaderSource.metal` (what the portable app renders),
      and `ShaderSource.hlslFragment` — plus the `stretch shader math` test.
      There are two separate MSL strings; `stretch shader copies` fails if they
      drift, but only after you have already written the change twice.
