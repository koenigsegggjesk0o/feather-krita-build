# feather-krita-build

CI builder for the [Feather-Krita](https://github.com/koenigsegggjesk0o/krita) native brush bridge.

This repository exists to compile `krita_bridge.dll` on GitHub Actions Windows runners.
It is public because public repositories receive unlimited GitHub Actions minutes,
while the main project repository is private (quota-limited).

## What is built

- `native/krita_bridge/krita_bridge.cpp` — Qt-only implementation of the
  Krita-compatible brush engine C ABI (`krita_bridge.h`):
  - Soft-round brush dabs (radial-gradient falloff, pressure-scaled, hardness-aware)
  - `.kpp` preset loading via built-in ZIP reader + raw DEFLATE inflater + XML parser
  - Error handling with descriptive messages
- `native/krita_bridge/smoke_test.cpp` — runtime test that loads the DLL
  (LoadLibrary/GetProcAddress — same mechanism as Dart FFI), generates dabs at
  multiple pressures, verifies pixel output, and exercises error paths.

## Workflow

`step2-qt-bridge.yml`:
1. Install Qt 6.6.3 (msvc2019_64) via aqtinstall
2. Compile `krita_bridge.dll` with MSVC (`/std:c++17`, x64)
3. Compile + run the runtime smoke test against the DLL
4. Upload `krita_bridge.dll` as artifact `krita-bridge-dll`
5. Verify exported symbols with dumpbin

## Validation status

The same source compiles cleanly with `g++ -std=c++17` on Linux against Qt 6.6.3
and passes the runtime smoke test (dab alpha falloff, pressure scaling, error paths).
