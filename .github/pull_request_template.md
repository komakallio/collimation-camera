## What changed

<!-- One or two sentences. What a reader needs to know that the diff does not say. -->

## Checklist

- [ ] Core or UI-model change has a test in `CoreTests`.
- [ ] Both apps updated, or `PARITY.md` explains the difference.
- [ ] `swift run core-tests` green on macOS and Windows (CI).
- [ ] Simulator smoke test on the portable app.
- [ ] Hardware note if capture, mount, or wheel code changed.
- [ ] A new vendored binary or library has its license text in `LICENSES/` and
      a row in `LICENSES/README.md`.
- [ ] A change to one copy of the stretch shader changes all three — the CPU
      `StretchParams.apply`, the MSL shader, the HLSL shader — and the
      `stretch shader math` test.
