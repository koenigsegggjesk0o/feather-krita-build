// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// ffi_real_smoke.dart — end-to-end CI smoke test for the REAL Krita engine
// through the app's own Dart FFI bindings (lib/ffi/krita_bindings.dart).
//
// This runs on the Dart VM (no Flutter needed — the bindings only use
// dart:ffi/dart:io/dart:typed_data + package:ffi).
//
// Usage:
//   dart run tool/ffi_real_smoke.dart <bundleDir> [fixtureDir]
//
// <bundleDir> is the Flutter Linux bundle directory (containing lib/).
// The bridge (lib/libkrita_bridge.so, renamed from libkrita_bridge_real.so)
// and the real libkrita*.so libraries must live in <bundleDir>/lib/.
// On Windows there is no lib/ subdir: krita_bridge.dll, Qt5*/KF5*/vcpkg
// runtime DLLs all sit NEXT to the exe (single merged engine DLL, loop-35),
// so <bundleDir> is the Release directory itself and the lib/ check is
// skipped there. The script switches the process CWD to the bundle so the
// loader's relative candidates resolve, and the bridge's own rpath ($ORIGIN)
// finds the bundled Krita libraries on Linux.
//
// [fixtureDir] (default: <launch CWD>/test/fixtures, resolved BEFORE the
// CWD switch) holds real Krita stock presets. When present, paintop-
// settings-level preset gates run (roadmap (f)); failures there are fatal.
// Missing fixtures only downgrade the smoke to the base dab gates.

import 'dart:io';

import 'package:feather_krita/ffi/krita_bindings.dart';

int _failures = 0;

void _check(bool cond, String msg) {
  if (cond) {
    stdout.writeln('  ok: $msg');
  } else {
    stdout.writeln('  FAIL: $msg');
    _failures++;
  }
}

int _centerPixelIndex(int width, int height, int stride) {
  final s = stride > 0 ? stride : width * 4;
  return (height ~/ 2) * s + (width ~/ 2) * 4;
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/ffi_real_smoke.dart <bundleDir> [fixtureDir]');
    exit(2);
  }
  // Resolve the preset fixture dir BEFORE the CWD switch below (the CI
  // launches this script from the repo root).
  final fixtureDirPath = args.length > 1
      ? args[1]
      : '${Directory.current.absolute.path}/test/fixtures';
  final fixtureDir = Directory(fixtureDirPath);

  final bundle = Directory(args[0]).absolute.path;
  final libDir = Directory('$bundle/lib');
  // Windows layout: DLLs next to the exe, no lib/ subdir (merged engine DLL).
  if (!libDir.existsSync() && !Platform.isWindows) {
    stderr.writeln('bundle lib dir not found: $libDir');
    exit(2);
  }
  stdout.writeln('bundle: $bundle');
  final contentDir = libDir.existsSync() ? libDir : Directory(bundle);
  stdout.writeln('native dir contents: ${contentDir.listSync().length} files');

  // The FFI loader resolves relative candidates against the process CWD.
  Directory.current = bundle;

  final engine = KritaBrushEngine();

  // --- Full-pressure dab: exact color passthrough, opaque center.
  engine.size = 64;
  engine.color = const BrushColor(0x20, 0x40, 0xA0);
  final dab = engine.generateDab(
      const BrushInput(x: 0, y: 0, pressure: 1.0));
  _check(dab.width >= 60 && dab.width <= 68, 'dab sized from set_size(64) '
      '(got ${dab.width})');
  _check(dab.stride == dab.width * 4, 'stride == width*4');
  if (dab.pixels.isNotEmpty) {
    final i = _centerPixelIndex(dab.width, dab.height, dab.stride);
    final r = dab.pixels[i], g = dab.pixels[i + 1];
    final b = dab.pixels[i + 2], a = dab.pixels[i + 3];
    stdout.writeln('  center RGBA: $r $g $b $a');
    _check(r == 0x20 && g == 0x40 && b == 0xA0, 'center color exact');
    _check(a >= 250, 'center opaque at full pressure');
    final cornerA = dab.pixels[3];
    _check(cornerA == 0, 'bounding-box corner transparent');
  }

  // --- Half pressure: real engine scales alpha AND size.
  final half = engine.generateDab(
      const BrushInput(x: 0, y: 0, pressure: 0.5));
  if (half.pixels.isNotEmpty) {
    final i = _centerPixelIndex(half.width, half.height, half.stride);
    final a = half.pixels[i + 3];
    stdout.writeln('  half-pressure center alpha=$a width=${half.width} '
        '(full was ${dab.width})');
    _check(a < 255, 'half pressure scales alpha down');
    _check(half.width < dab.width, 'half pressure shrinks dab');
  } else {
    _check(false, 'half-pressure dab generated');
  }

  // ------------------------------------------------------------------
  // Paintop-settings-level preset gates (roadmap (f)).
  //
  // Real Krita stock presets (PNG preset containers with settings-level
  // params) live in test/fixtures (or argv[1]). When the fixture dir is
  // absent the gates are skipped with a note; when present, failures are
  // FATAL. The C++ smoke (smoke_test_real.cpp) runs the same gates at the
  // engine layer; this section proves the values cross the app's own Dart
  // FFI bindings.
  // ------------------------------------------------------------------
  const basicFixtureName = 'stock_basic_5_size.kpp';
  const eraserFixtureName = 'stock_eraser_circle.kpp';
  final basicFixture = File('${fixtureDir.path}/$basicFixtureName');
  final eraserFixture = File('${fixtureDir.path}/$eraserFixtureName');
  if (!basicFixture.existsSync() || !eraserFixture.existsSync()) {
    stdout.writeln('  PRESET GATES SKIPPED (fixtures not found in '
        '${fixtureDir.path})');
  } else {
    // --- stock_basic_5_size: paintbrush, soft auto tip -------------------
    final p1 = KritaBrushEngine();
    _check(p1.loadPreset(basicFixture.absolute.path),
        'loadPreset($basicFixtureName) succeeds');
    if (p1.lastError().isNotEmpty) stdout.writeln('  err: ${p1.lastError()}');
    stdout.writeln('  basic-5: size=${p1.currentSize} '
        'opacity=${p1.currentOpacity} spacing=${p1.currentSpacing} '
        'hardness=${p1.currentHardness} name=${p1.currentPresetName} '
        'paintop=${p1.currentPaintopId}');
    _check(p1.currentSize == 40.0, 'basic-5 size == 40 (MaskGenerator diameter)');
    _check(p1.currentOpacity == 1.0, 'basic-5 opacity == 1.0 (Krita/opacity = 100)');
    _check((p1.currentSpacing - 0.1).abs() < 1e-9,
        'basic-5 spacing == 0.1 (Brush spacing attr)');
    _check(p1.currentHardness == 0.0, 'basic-5 hardness == 0 (hfade = 1)');
    _check(!p1.isEraserPreset, 'basic-5 NOT flagged eraser');
    _check(p1.currentPaintopId == 'paintbrush',
        'basic-5 paintop id == paintbrush (declared root family)');
    final pdab = p1.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
    _check(pdab.width >= 36 && pdab.width <= 44,
        'basic-5 dab extent from preset tip (got ${pdab.width})');
    p1.dispose();

    // --- stock_eraser_circle: eraser via settings-level CompositeOp ------
    final p2 = KritaBrushEngine();
    _check(p2.loadPreset(eraserFixture.absolute.path),
        'loadPreset($eraserFixtureName) succeeds');
    if (p2.lastError().isNotEmpty) stdout.writeln('  err: ${p2.lastError()}');
    stdout.writeln('  eraser: size=${p2.currentSize} '
        'opacity=${p2.currentOpacity} spacing=${p2.currentSpacing} '
        'hardness=${p2.currentHardness} paintop=${p2.currentPaintopId}');
    _check(p2.currentSize == 50.0, 'eraser size == 50 (MaskGenerator diameter)');
    _check(p2.currentOpacity == 1.0, 'eraser opacity == 1.0 (Krita/opacity = 100)');
    _check((p2.currentHardness - 0.13).abs() < 1e-9,
        'eraser hardness == 0.13 (hfade = 0.87)');
    _check(p2.isEraserPreset,
        'eraser preset flagged via settings (CompositeOp=erase)');
    _check(p2.currentPaintopId == 'paintbrush',
        'eraser-circle paintop id == paintbrush (CompositeOp marks the eraser, not the family)');
    final edab = p2.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
    if (edab.pixels.isNotEmpty) {
      final i = _centerPixelIndex(edab.width, edab.height, edab.stride);
      _check(edab.pixels[i] == 0 && edab.pixels[i + 1] == 0 &&
              edab.pixels[i + 2] == 0,
          'eraser preset dab is black mask WITHOUT eraser flag');
    } else {
      _check(false, 'eraser preset dab generated');
    }
    p2.dispose();

    // --- engine-side preset scan (preset-families campaign, 5-loop-47) ---
    // The REAL engine's own container parser scans the fixture dir; the
    // two stock fixtures must surface with their declared paintop family
    // and a scanned path that round-trips through loadPreset. Same gates
    // as the C++ smoke's scan section, proven through the app's own Dart
    // FFI bindings.
    final ps = KritaBrushEngine();
    final scanCount = ps.scanPresetFamilies(fixtureDir.absolute.path);
    stdout.writeln('  preset scan ${fixtureDir.absolute.path} -> $scanCount');
    _check(scanCount >= 2, 'engine scan finds at least the two stock fixtures');
    final entries = ps.scannedPresets();
    _check(entries.length == scanCount,
        'scannedPresets() count matches scan ($scanCount)');
    final basicEntry = entries
        .where((e) => e.path.replaceAll('\\', '/').endsWith(basicFixtureName))
        .toList();
    final eraserEntry = entries
        .where((e) => e.path.replaceAll('\\', '/').endsWith(eraserFixtureName))
        .toList();
    _check(basicEntry.isNotEmpty, 'scan sees $basicFixtureName');
    _check(eraserEntry.isNotEmpty, 'scan sees $eraserFixtureName');
    if (basicEntry.isNotEmpty && eraserEntry.isNotEmpty) {
      _check(basicEntry.first.family == 'paintbrush',
          'scanned basic-5 family == paintbrush');
      _check(eraserEntry.first.family == 'paintbrush',
          'scanned eraser-circle family == paintbrush');
      _check(basicEntry.first.name.isNotEmpty,
          'scanned display name populated');
      final rt = KritaBrushEngine();
      _check(rt.loadPreset(basicEntry.first.path),
          'scanned path round-trips through loadPreset');
      if (rt.lastError().isNotEmpty) stdout.writeln('  err: ${rt.lastError()}');
      _check(rt.currentPaintopId == 'paintbrush',
          'round-trip paintop id matches scanned family');
      rt.dispose();
    }
    ps.dispose();
  }

  // ------------------------------------------------------------------
  // Flow + hardness ABI gates (flow/hardness campaign) via Dart FFI.
  //
  // Mirrors the C++ smoke (smoke_test_real.cpp) flow/hardness section,
  // proving the values cross the app's own Dart FFI bindings.
  // ------------------------------------------------------------------
  // Neutralize the engine for the flow/hardness comparison.
  engine.size = 64;
  engine.color = const BrushColor(0, 0, 0);
  engine.hardness = 0.85;
  engine.flow = 1.0;

  // --- Flow: full vs half ---
  final fd1 =
      engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
  int alphaFull = 0;
  if (fd1.pixels.isNotEmpty) {
    final i = _centerPixelIndex(fd1.width, fd1.height, fd1.stride);
    alphaFull = fd1.pixels[i + 3];
  }

  engine.flow = 0.5;
  _check((engine.currentFlow - 0.5).abs() < 1e-9,
      'currentFlow round-trips set flow(0.5)');
  final fd2 =
      engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
  if (fd2.pixels.isNotEmpty) {
    final i = _centerPixelIndex(fd2.width, fd2.height, fd2.stride);
    final alphaHalf = fd2.pixels[i + 3];
    stdout.writeln('  flow alpha: full=$alphaFull half=$alphaHalf');
    _check(alphaHalf < alphaFull, 'flow=0.5 reduces dab alpha vs flow=1.0');
    _check(
        alphaHalf <= (alphaFull * 0.60).round() &&
            alphaHalf >= (alphaFull * 0.40).round(),
        'flow=0.5 roughly halves dab alpha (within 40-60%)');
  } else {
    _check(false, 'flow=0.5 dab generated');
  }

  // --- Hardness: set_hardness rebuilds the mask generator ---
  // Contract under test (mirrors the C++ smoke): currentHardness
  // round-trips the setter, and switching hardness 1.0 <-> 0.0 rebuilds
  // the real Krita mask generator so the dab changes MATERIALLY (alpha
  // bytes differ over the dab) while the center stays opaque in both
  // regimes. Directional falloff-shape asserts are not portable across
  // Krita's internal mask-generator semantics (spikes=2 lens geometry,
  // fade-zone interpretation) — the fade->falloff path is covered by the
  // default-hardness soft-dab gates in the C++ smoke.
  engine.flow = 1.0; // neutralize flow for hardness compare

  engine.hardness = 1.0;
  _check((engine.currentHardness - 1.0).abs() < 1e-9,
      'currentHardness round-trips set hardness(1.0)');
  final hd =
      engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
  int hardCenter = 0;
  final hardAlpha = <int>[];
  if (hd.pixels.isNotEmpty) {
    final s = hd.stride > 0 ? hd.stride : hd.width * 4;
    hardCenter = hd.pixels[(hd.height ~/ 2) * s + (hd.width ~/ 2) * 4 + 3];
    for (var y = 0; y < hd.height; y++) {
      for (var x = 0; x < hd.width; x++) {
        hardAlpha.add(hd.pixels[y * s + x * 4 + 3]);
      }
    }
    stdout.writeln('  hard: center=$hardCenter w=${hd.width}');
  }

  engine.hardness = 0.0;
  _check(engine.currentHardness.abs() < 1e-9,
      'currentHardness round-trips set hardness(0.0)');
  final sd =
      engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
  if (sd.pixels.isNotEmpty) {
    final s = sd.stride > 0 ? sd.stride : sd.width * 4;
    final softCenter = sd.pixels[(sd.height ~/ 2) * s + (sd.width ~/ 2) * 4 + 3];
    stdout.writeln('  soft: center=$softCenter w=${sd.width}');
    _check(softCenter >= 250, 'soft center still strong (gaussian peak)');
    _check(hardCenter >= 250, 'hard center opaque (disk core)');
    if (hardAlpha.isNotEmpty &&
        hd.width == sd.width &&
        hd.height == sd.height) {
      var diff = 0;
      for (var y = 0; y < sd.height; y++) {
        for (var x = 0; x < sd.width; x++) {
          final sa = sd.pixels[y * s + x * 4 + 3];
          if (sa != hardAlpha[y * sd.width + x]) diff++;
        }
      }
      final frac = diff / (sd.width * sd.height);
      stdout.writeln(
          '  hardness material diff: $diff/${sd.width * sd.height} px '
          '(${(frac * 100).toStringAsFixed(1)}%)');
      _check(frac >= 0.01,
          'set_hardness materially rebuilds the mask (hard != soft)');
    } else {
      _check(false, 'hard/soft dabs comparable (same geometry)');
    }
  } else {
    _check(false, 'soft-edge dab generated');
  }

  engine.dispose();

  if (_failures == 0) {
    stdout.writeln('FFI REAL-ENGINE SMOKE OK');
    exit(0);
  }
  stdout.writeln('FFI REAL-ENGINE SMOKE FAILED — $_failures failure(s)');
  exit(1);
}
