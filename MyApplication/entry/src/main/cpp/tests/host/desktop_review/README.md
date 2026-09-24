# Desktop review regressions

The normal host CMake/CTest entry generates these harnesses using Python 3.10+. `scripts/generate-desktop-review-tests.py` extracts the current GLFW functions and applies SDL's ordered unified hunks to a sparse source model. Missing upstream lines are explicit errors if they fall inside a tested function; deleted patch text cannot satisfy the tests.

The tests cover native configuration failure, failed and successful EGL release, thread handoff, surface recovery/auxiliary resize ownership guards, cache rollback, initial monitor submission and presented visibility requests/results. `desktop_egl_core_test.cpp` separately runs the complete production EGL core with injectable driver failures. These are host semantic tests, not GPU or device validation.

After rebuilding SDL, also compare every reconstructed line with the fully applied checkout:

```powershell
python scripts/generate-desktop-review-tests.py --out .tmp-desktop-review-fix/generated --sdl-repo docker/output/sdl3-desktop-review-20260910-repro/source
```

`scripts/test-desktop-arkts-seams.mjs` executes the actual EntryAbility lifecycle methods and LauncherTabsStyle with isolated system modules. It requires the configured SDK TypeScript compiler and runs from `build-hap.ps1`. Renderer routing remains in the regular Hypium suite.
