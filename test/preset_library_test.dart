// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// preset_library_test.dart — EditorState.loadPresetLibrary tests:
// bundled-asset seeding, user-folder scanning, broken-folder resilience.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/state/editor_state.dart';

/// Builds a Krita-shaped .kpp (ZIP + XML) at [dir]/[name].
Future<File> writeSyntheticKpp(Directory dir, String name,
    {int size = 42, double opacity = 0.66}) async {
  final xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<Paintop id="paintbrush" name="paintbrush">\n'
      '  <param id="brush_size" min="1" max="1000" value="$size"/>\n'
      '  <param id="brush_opacity" min="0" max="1" value="$opacity"/>\n'
      '  <param id="brush_spacing" min="0" max="1" value="0.09"/>\n'
      '  <param id="hardness" min="0" max="1" value="0.7"/>\n'
      '  <param id="eraser" value="0"/>\n'
      '</Paintop>\n';
  final bytes = ZipEncoder().encode(Archive()
    ..addFile(ArchiveFile(
        name.replaceAll('.kpp', '.xml'), xml.length, utf8.encode(xml))))!;
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadPresetLibrary seeds bundled presets and scans the user folder',
      () async {
    final state = EditorState();
    addTearDown(state.dispose);
    final dir = await Directory.systemTemp.createTemp('feather_presets_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    // A user preset placed BEFORE the load must survive the seeding.
    await writeSyntheticKpp(dir, 'user_brush.kpp');

    await state.loadPresetLibrary(directory: dir.path);

    // Bundled assets were seeded into the folder.
    for (final name in EditorState.kBundledPresetAssets) {
      expect(
        File('${dir.path}${Platform.pathSeparator}$name').existsSync(),
        isTrue,
        reason: '$name must be seeded from flutter assets',
      );
    }

    // The library contains the user preset + every bundled preset.
    final names = state.presets.map((p) => p.name).toList();
    expect(names, contains('user_brush'));
    for (final name in EditorState.kBundledPresetAssets) {
      expect(names, contains(name.replaceAll('.kpp', '')),
          reason: 'bundled preset $name must appear in the library');
    }
    expect(state.presets.length, EditorState.kBundledPresetAssets.length + 1);

    // Preset parameters actually parse through the .kpp loader.
    final user = state.presets.firstWhere((p) => p.name == 'user_brush');
    expect(user.scalarSetting('brush_size'), 42.0);
    expect(user.scalarSetting('brush_opacity'), closeTo(0.66, 1e-6));
  });

  test('loadPresetLibrary is idempotent (no duplicate seeding)', () async {
    final state = EditorState();
    addTearDown(state.dispose);
    final dir = await Directory.systemTemp.createTemp('feather_presets_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    await state.loadPresetLibrary(directory: dir.path);
    final first = state.presets.length;
    expect(first, EditorState.kBundledPresetAssets.length);

    await state.loadPresetLibrary(directory: dir.path);
    expect(state.presets.length, first,
        reason: 're-loading must not duplicate seeded presets');
  });

  test('loadPresetLibrary survives a missing folder', () async {
    final state = EditorState();
    addTearDown(state.dispose);
    final missing =
        '${Directory.systemTemp.path}/feather_missing_${DateTime.now().microsecondsSinceEpoch}';
    await state.loadPresetLibrary(directory: missing);
    // The loader creates the folder and finds nothing (rootBundle works in
    // the test host, so the three bundled presets still land there).
    expect(state.presets.length, EditorState.kBundledPresetAssets.length);
    Directory(missing).deleteSync(recursive: true);
  });

  test('real stock Krita presets (PNG preset containers) parse end-to-end',
      () async {
    // These are UNMODIFIED stock presets from the Krita project — the
    // legacy PNG container format (preset XML in a zTXt chunk). See
    // test/fixtures/README.md for provenance and the expected values.
    final basic = BrushPreset.loadFromBytes(
      File('test/fixtures/stock_basic_5_size.kpp').readAsBytesSync(),
      filePath: 'test/fixtures/stock_basic_5_size.kpp',
    );
    expect(basic.paintopId, 'paintbrush');
    expect(basic.name, 'b)_Basic-5_Size');
    // The PNG itself doubles as the preset thumbnail.
    expect(basic.thumbnail, isNotNull);
    expect(basic.thumbnail!.length, greaterThan(20000));
    // Paintop-settings-level params land in the settings map verbatim.
    // (basic-5 carries its master opacity via the OpacityValue sensor base;
    // only the eraser stock preset writes a Krita/opacity master entry.)
    expect(basic.settings.containsKey('OpacityValue'), isTrue);
    expect(basic.settings['OpacityValue']!.value, '1');
    expect(basic.settings.containsKey('CompositeOp'), isTrue);
    expect(basic.settings['CompositeOp']!.value, 'normal');
    expect(basic.settings.containsKey('brush_definition'), isTrue);
    expect(basic.settings['brush_definition']!.value, contains('<MaskGenerator'));

    final eraser = BrushPreset.loadFromBytes(
      File('test/fixtures/stock_eraser_circle.kpp').readAsBytesSync(),
      filePath: 'test/fixtures/stock_eraser_circle.kpp',
    );
    expect(eraser.paintopId, 'paintbrush');
    expect(eraser.thumbnail, isNotNull);
    // The stock eraser marks eraser mode via CompositeOp=erase.
    expect(eraser.settings['CompositeOp']!.value, 'erase');
    expect(eraser.settings['Krita/opacity']!.value, '100');
    expect(eraser.settings['Krita/erase']!.value, 'false');
    // Sensor curves survive as string settings (not scalars).
    expect(eraser.settings.containsKey('SizeSensor'), isTrue);
    expect(eraser.settings['SizeSensor']!.type, BrushSettingType.string);
  });
}
