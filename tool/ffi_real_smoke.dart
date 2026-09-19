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
//   dart run tool/ffi_real_smoke.dart <bundleDir>
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
    stderr.writeln('usage: dart run tool/ffi_real_smoke.dart <bundleDir>');
    exit(2);
  }
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

  engine.dispose();

  if (_failures == 0) {
    stdout.writeln('FFI REAL-ENGINE SMOKE OK');
    exit(0);
  }
  stdout.writeln('FFI REAL-ENGINE SMOKE FAILED — $_failures failure(s)');
  exit(1);
}
