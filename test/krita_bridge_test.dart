// End-to-end regression tests for the krita_bridge native brush engine.
//
// These tests load the REAL native library (assets/native/linux/
// libkrita_bridge.so on Linux — the Qt-free portable build) through the same
// Dart FFI path the app uses, and validate:
//   1. dab generation (size, soft edge, color),
//   2. pressure scaling,
//   3. eraser mode (black + alpha mask, the erase-strength contract),
//   4. .kpp preset loading (ZIP + XML, synthetic Krita-shaped archive),
//   5. EditorState wiring (bridge loads through the app's own state layer).
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a Krita-shaped .kpp (ZIP + XML) in a temp dir, mirroring
/// native/krita_bridge/make_test_kpp.py: a decoy subdir XML that must be
/// ignored, the real preset XML named after the preset, and a brush tip XML.
Future<File> writeSyntheticKpp(String name, {bool deflated = true}) async {
  const xmlParams = '''<?xml version="1.0" encoding="UTF-8"?>
<Paintop id="paintbrush" name="paintbrush">
  <param id="brush_size" min="1" max="1000" value="77"/>
  <param id="brush_opacity" min="0" max="1" value="0.42"/>
  <param id="brush_spacing" min="0" max="1" value="0.07"/>
  <param id="hardness" min="0" max="1" value="0.64"/>
  <param id="eraser" value="0"/>
</Paintop>
''';
  const xmlDab = '''<?xml version="1.0" encoding="UTF-8"?>
<Brush type="mask">
  <param id="diameter" value="33"/>
</Brush>
''';
  final archive = Archive()
    ..addFile(ArchiveFile(
        'sub/decoy.xml', xmlParams.length, utf8.encode(xmlParams)))
    ..addFile(ArchiveFile(
        'Synthetic Test.xml', xmlParams.length, utf8.encode(xmlParams)))
    ..addFile(ArchiveFile('brush.tip.xml', xmlDab.length, utf8.encode(xmlDab)));
  final bytes = deflated
      ? ZipEncoder().encode(archive)
      : ZipEncoder().encode(archive, level: -1);
  final dir = await Directory.systemTemp.createTemp('feather_kpp');
  final file = File('${dir.path}/$name')..writeAsBytesSync(bytes!);
  return file;
}

int centerAlpha(BrushDab dab) {
  final cx = dab.width ~/ 2;
  final cy = dab.height ~/ 2;
  return dab.pixels[cy * dab.stride + cx * 4 + 3];
}

int centerChannel(BrushDab dab, int ch) {
  final cx = dab.width ~/ 2;
  final cy = dab.height ~/ 2;
  return dab.pixels[cy * dab.stride + cx * 4 + ch];
}

void main() {
  test('engine generates a full-pressure soft dab', () {
    final engine = KritaBrushEngine();
    engine
      ..size = 64
      ..color = const BrushColor(255, 0, 0)
      ..opacity = 1.0;
    final dab = engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
    expect(dab.isEmpty, isFalse);
    expect(dab.width, 64);
    expect(dab.height, 64);
    expect(centerChannel(dab, 0), 255, reason: 'red channel at center');
    expect(centerAlpha(dab), greaterThan(200), reason: 'opaque center');
    expect(dab.pixels[3], lessThan(60), reason: 'soft corner (alpha)');
    engine.dispose();
  });

  test('pressure scales the dab radius', () {
    final engine = KritaBrushEngine();
    engine..size = 64..opacity = 1.0;
    final full = engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
    final light = engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 0.25));
    expect(full.width, 64);
    expect(light.width, lessThan(64));
    expect(light.width, greaterThanOrEqualTo(10));
    engine.dispose();
  });

  test('eraser dab is a black alpha mask (erase-strength contract)', () {
    // Regression: the Qt build once painted eraser dabs with
    // CompositionMode_DestinationOut onto a transparent image, producing a
    // fully transparent (no-op) erase mask on Windows.
    final engine = KritaBrushEngine();
    engine
      ..size = 64
      ..color = const BrushColor(255, 0, 0)
      ..opacity = 1.0;
    final dab = engine.generateDab(BrushInput(
      x: 0,
      y: 0,
      pressure: 1.0,
      flags: BrushInputFlags(eraser: true),
    ));
    expect(dab.isEmpty, isFalse);
    expect(centerChannel(dab, 0), 0, reason: 'eraser mask is black');
    expect(centerChannel(dab, 1), 0);
    expect(centerChannel(dab, 2), 0);
    expect(centerAlpha(dab), greaterThan(200),
        reason: 'mask alpha carries the erase strength');
    // Half pressure halves the mask alpha.
    final soft = engine.generateDab(BrushInput(
      x: 0,
      y: 0,
      pressure: 0.5,
      flags: BrushInputFlags(eraser: true),
    ));
    expect(centerAlpha(soft), inInclusiveRange(60, 200),
        reason: 'alpha scales with pressure');
    engine.dispose();
  });

  test('loads .kpp presets (deflated ZIP + XML)', () async {
    final engine = KritaBrushEngine();
    final kpp = await writeSyntheticKpp('synthetic-deflated.kpp');
    try {
      expect(engine.loadPreset(kpp.path), isTrue,
          reason: 'loader failed: ${engine.lastError()}');
      expect(engine.currentSize, 77.0);
      expect(engine.currentOpacity, closeTo(0.42, 1e-9));
      expect(engine.currentSpacing, closeTo(0.07, 1e-9));
      expect(engine.currentHardness, closeTo(0.64, 1e-9));
      // The dab must reflect the preset size (77): the engine renders even
      // diameters, ceil(77/2)*2 = 78.
      final dab = engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
      expect(dab.width, inInclusiveRange(77, 78));
    } finally {
      await kpp.parent.delete(recursive: true);
      engine.dispose();
    }
  });

  test('loads .kpp presets (stored ZIP, no compression)', () async {
    final engine = KritaBrushEngine();
    final kpp = await writeSyntheticKpp('synthetic-stored.kpp', deflated: false);
    try {
      expect(engine.loadPreset(kpp.path), isTrue,
          reason: 'loader failed: ${engine.lastError()}');
      expect(engine.currentSize, 77.0);
    } finally {
      await kpp.parent.delete(recursive: true);
      engine.dispose();
    }
  });

  test('loadPreset reports errors for missing files', () {
    final engine = KritaBrushEngine();
    expect(engine.loadPreset('/nonexistent/file.kpp'), isFalse);
    expect(engine.lastError(), isNotEmpty);
    engine.dispose();
  });

  test('EditorState wires the native bridge through the app state layer', () {
    final state = EditorState();
    expect(state.brushEngine, isNotNull,
        reason: 'native bridge should load (portable .so has no Qt deps)');
    final dab = state.brushEngine!
        .generateDab(const BrushInput(x: 0, y: 0, pressure: 0.9));
    expect(dab.isEmpty, isFalse);
    // Brush params flow from UI state into the engine.
    expect(state.brushEngine!.currentSize, closeTo(state.brushSize, 1e-9));
    state.dispose();
  });
}
