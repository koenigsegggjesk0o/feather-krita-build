// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// paintop_identity_test.dart — 5-loop-41 paintop identity campaign tests:
//   - BrushPreset.supportsHardness mirrors Krita's per-paintop option
//     availability (auto-brush families only; unknown families enabled)
//   - EditorState.activePaintopId seeds from the preset's declared family
//     (pure-Dart path — deterministic with or without the native engine)
//   - real stock fixtures parse to the families Krita declares

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/state/editor_state.dart';

Future<File> writeKpp(Directory dir, String name, String rootOpen,
    {String rootClose = '</Paintop>'}) async {
  final xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '$rootOpen\n'
      '  <param id="brush_size" min="1" max="1000" value="42"/>\n'
      '$rootClose\n';
  final bytes = ZipEncoder().encode(Archive()
    ..addFile(ArchiveFile(
        name.replaceAll('.kpp', '.xml'), xml.length, utf8.encode(xml))))!;
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('supportsHardness: auto-brush families true, others false', () {
    bool supports(String paintop) {
      final p = BrushPreset(
        id: 't',
        name: 't',
        paintopId: paintop,
      );
      return p.supportsHardness;
    }

    // Auto-brush families (hardness dimension) — the evidence set: across
    // every bundled stock preset, hardness/Softness option entries appear
    // only on these families' files.
    expect(supports('paintbrush'), isTrue);
    expect(supports('eraser'), isTrue);
    expect(supports('airbrush'), isTrue);
    // Families Krita gives no hardness option (no hardness / Softness
    // option entries in any bundled stock file of these families).
    for (final family in BrushPreset.kNoHardnessPaintops) {
      expect(supports(family), isFalse,
          reason: '$family must not offer hardness');
    }
    // Unknown / undeclared families default to enabled (custom presets
    // keep manual control).
    expect(supports('exoticfutureop'), isTrue);
    expect(supports(''), isTrue);
  });

  test('EditorState seeds activePaintopId from the preset root', () async {
    final dir = await Directory.systemTemp.createTemp('paintop_identity_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    await writeKpp(dir, 'spray.kpp', '<Paintop id="spraybrush" name="spray">');
    await writeKpp(
        dir, 'paint.kpp', '<Preset name="paint" paintopid="paintbrush">',
        rootClose: '</Preset>');

    final presets = await BrushPreset.listFromDirectory(dir.path);
    expect(presets.length, 2);

    final state = EditorState();
    addTearDown(state.dispose);

    final spray = presets.firstWhere((p) => p.name == 'spray');
    state.loadBrushPreset(spray);
    expect(state.activePaintopId, 'spraybrush');
    expect(state.activePaintopSupportsHardness, isFalse,
        reason: 'spraybrush has no hardness dimension');

    final paint = presets.firstWhere((p) => p.name == 'paint');
    state.loadBrushPreset(paint);
    expect(state.activePaintopId, 'paintbrush');
    expect(state.activePaintopSupportsHardness, isTrue);

    // The panel-facing getters expose the family for the badge.
    expect(state.activePaintopSupportsHardness,
        !BrushPreset.kNoHardnessPaintops.contains(state.activePaintopId));
  });

  test('real stock fixtures parse to the families Krita declares', () async {
    final fixtures = Directory('test/fixtures');
    if (!fixtures.existsSync()) return;
    for (final name in const [
      'stock_basic_5_size.kpp',
      'stock_eraser_circle.kpp',
    ]) {
      final f = File('${fixtures.path}${Platform.pathSeparator}$name');
      if (!f.existsSync()) continue;
      final preset = await BrushPreset.loadFromFile(f.path);
      expect(preset, isNotNull, reason: '$name parses');
      expect(preset.paintopId, 'paintbrush',
          reason: '$name declares paintopid=paintbrush');
      expect(preset.supportsHardness, isTrue);
    }
  });
}
