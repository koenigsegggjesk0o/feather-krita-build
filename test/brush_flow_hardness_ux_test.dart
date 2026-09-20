// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_flow_hardness_ux_test.dart — 5-loop-40 UX wiring tests:
//   - Flow slider seeded from BrushPreset.flowValue on preset load
//     (pure-Dart parse — deterministic with or without the native engine)
//   - setBrushFlow / setBrushHardness clamp and sync to the engine
//   - Hardness default matches the native bridge default (0.85)

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/state/editor_state.dart';

/// Builds a Krita-shaped .kpp (ZIP + XML) at [dir]/[name] with optional
/// FlowValue / hardness params.
Future<File> writeKpp(
  Directory dir,
  String name, {
  double? flow,
  double? hardness,
}) async {
  final sb = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<Paintop id="paintbrush" name="paintbrush">')
    ..writeln('  <param id="brush_size" min="1" max="1000" value="42"/>')
    ..writeln('  <param id="brush_opacity" min="0" max="1" value="0.9"/>')
    ..writeln('  <param id="brush_spacing" min="0" max="1" value="0.09"/>');
  if (flow != null) {
    sb.writeln('  <param id="FlowValue" min="0" max="1" value="$flow"/>');
  }
  if (hardness != null) {
    sb.writeln('  <param id="hardness" min="0" max="1" value="$hardness"/>');
  }
  sb.writeln('  <param id="eraser" value="0"/>');
  sb.writeln('</Paintop>');
  final xml = sb.toString();
  final bytes = ZipEncoder().encode(Archive()
    ..addFile(ArchiveFile(
        name.replaceAll('.kpp', '.xml'), xml.length, utf8.encode(xml))))!;
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late EditorState state;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('feather_flow_hardness_test');
    state = EditorState();
  });

  tearDown(() {
    state.dispose();
    dir.deleteSync(recursive: true);
  });

  test('flow slider seeds from the preset FlowValue on load', () async {
    await writeKpp(dir, 'flowy.kpp', flow: 0.45);
    final presets = await BrushPreset.listFromDirectory(dir.path);
    expect(presets, isNotEmpty);

    state.loadBrushPreset(presets.first);
    expect(state.brushFlow, 0.45,
        reason: 'flow slider must seed from BrushPreset.flowValue');
  });

  test('flow slider falls back to 1.0 when the preset omits FlowValue',
      () async {
    await writeKpp(dir, 'noflow.kpp');
    final presets = await BrushPreset.listFromDirectory(dir.path);
    expect(presets, isNotEmpty);

    // Start from a non-default flow to prove the preset load re-seeds it.
    state.setBrushFlow(0.2);
    state.loadBrushPreset(presets.first);
    expect(state.brushFlow, 1.0,
        reason: 'missing FlowValue must map to the engine default 1.0');
  });

  test('setBrushFlow clamps to [0, 1] and updates state', () {
    state.setBrushFlow(1.7);
    expect(state.brushFlow, 1.0);
    state.setBrushFlow(-0.5);
    expect(state.brushFlow, 0.0);
    state.setBrushFlow(0.3);
    expect(state.brushFlow, 0.3);
  });

  test('setBrushHardness clamps to [0, 1] and updates state', () {
    expect(state.brushHardness, 0.85,
        reason: 'default must match the native bridge default hardness');
    state.setBrushHardness(2.0);
    expect(state.brushHardness, 1.0);
    state.setBrushHardness(-1.0);
    expect(state.brushHardness, 0.0);
    state.setBrushHardness(0.6);
    expect(state.brushHardness, 0.6);
  });

  test('preset load keeps hardness within [0, 1]', () async {
    await writeKpp(dir, 'hard.kpp', hardness: 0.7);
    final presets = await BrushPreset.listFromDirectory(dir.path);
    state.loadBrushPreset(presets.first);

    expect(state.brushHardness, inInclusiveRange(0.0, 1.0));
    if (state.brushEngine == null) {
      // Without a native engine nothing re-seeds hardness; the default
      // must survive untouched (pure-Dart determinism).
      expect(state.brushHardness, 0.85);
    }
  });

  test('setters notify listeners so sliders rebuild', () {
    var notified = 0;
    state.addListener(() => notified++);
    state.setBrushFlow(0.25);
    state.setBrushHardness(0.4);
    expect(notified, 2);
    // No-op on unchanged values must not notify.
    state.setBrushFlow(0.25);
    state.setBrushHardness(0.4);
    expect(notified, 2);
  });
}
