# Feather-Krita

A 3D painting app: draw on parametric guide surfaces (spheres, cylinders,
tori, custom tubes) with a real Krita-compatible brush engine, sculpt with
liquify tools, preview in an orbit-camera 3D viewport, 
and export to PNG /
JPEG / GIF / MP4 (animated stroke replay) / OBJ / glTF / `.feather` project files
(save + open, full undoable document restore).

Built with Flutter (Dart) plus a native C++ brush engine (`krita_bridge`)
accessed through `dart:ffi`.

## Architecture

| Layer | Path | What it does |
|---|---|---|
| Native bridge | `native/krita_bridge/` | C ABI brush engine: soft-round radial-gradient dabs, pressure/hardness, eraser masks, `.kpp` preset loading (built-in ZIP reader + zlib + XML). Two builds: **Qt6** (desktop, links QPainter) and **portable** (Qt-free, ships on Android/Linux). |
| FFI bindings | `lib/ffi/krita_bindings.dart` | Struct-safe Dart bindings matching `krita_bridge.h` byte-for-byte; dynamic-library loader per platform. |
| 3D engine | `lib/engine/` | `TexturePainter` (2048² RGBA8 texture, 14 blend modes, undo/redo), `GuideSurface` (parametric meshes + raycast), `StrokeManager` (mirror, liquify, 50-level history), `CameraController` (damped orbit). |
| UI | `lib/screens/`, `lib/widgets/` | Glassmorphism editor: 8 tools, brush settings, color picker, joystick, stroke list. |
| Tests | `test/` | 83 tests: unified undo journal (strokes+texture in lockstep), native dab contract, preset loading, texture compositing (+ per-stroke undo coalescing), mirror, raycast, PNG export round-trip, project save/load round-trip (+ texture re-render), GIF replay frames, glTF structure, preset-library seeding, camera damping, MP4/H.264 export (encoder modes, muxer structure, ffmpeg decode gate), 9 GUI wiring tests (incl. ticker-muting), 4 file-picker UX tests (Save As to a custom path, open-dialog size+relative-time, persisted recent-projects, post-export copy-path), 6 keyboard-shortcut tests (Ctrl+Z/Y undo/redo, B/E/V/L tool hotkeys, [ / ] brush size, Delete selection, Ctrl+N new doc, Ctrl+S quick-save), plus 9 brush-stabilizer tests (moving-average smoothing, jitter reduction, UV lockstep, edge clamping). |

## Platform status

| Platform | Native lib | Status |
|---|---|---|
| Windows | `krita_bridge.dll` (Qt build, MSVC x64) | ✅ CI-built, bundled next to `feather_krita.exe` |
| Android | `libkrita_bridge.so` (portable) × arm64-v8a / armeabi-v7a / x86_64 | ✅ CI-built, in `jniLibs/` |
| Linux | `libkrita_bridge.so` (portable) | ✅ bundled via `linux/CMakeLists.txt` (`flutter build linux` needs GTK3 dev headers) |

## Building

```bash
flutter pub get
flutter test          # 83-test regression suite (loads the real native bridge)
flutter analyze       # must report zero issues
flutter build windows # or: flutter build apk / flutter build linux
```

Windows/Linux builds copy the native bridge automatically (see
`windows/runner/CMakeLists.txt` and `linux/CMakeLists.txt`).

## Releases

Installable artifacts (Windows zip, Android APK) are published on the
[GitHub releases page](https://github.com/koenigsegggjesk0o/krita/releases):
`v0.6-bridge-working`, `v0.7-eraser-fix`.
