// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// preset_families_ux_test.dart — 5-loop-47 preset-families campaign:
//   - loadPresetLibrary lists .kpp presets with Dart-parsed paintopId
//     (deterministic with or without the native engine)
//   - the engine-authoritative family upgrade is DEFENSIVE: when the
//     native engine is absent (unit-test sandbox, fallback bridge) the
//     Dart-parse values stand and the library load never crashes
//   - garbage containers are skipped, never fatal
//
// The engine-side scan truth itself (ZIP KoStore / legacy PNG zTXt / bare
// XML through the real container parser) is gated in CI by the C++ smoke
// (smoke_test_real.cpp scan section) and the Dart smoke
// (tool/ffi_real_smoke.dart scan gates) against the two real stock
// fixtures — those need the built engine and cannot run in this sandbox.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/state/editor_state.dart';

/// Builds a Krita-shaped .kpp (ZIP + XML) declaring the given paintop
/// family, mirroring the synthetic shapes the engine smoke uses.
Future<File> writeKpp(
  Directory dir,
  String name, {
  String family = 'paintbrush',
}) async {
  final sb = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<Paintop id="$family" name="$family">')
    ..writeln('  <param id="brush_size" min="1" max="1000" value="42"/>')
    ..writeln('  <param id="brush_opacity" min="0" max="1" value="0.9"/>')
    ..writeln('</Paintop>');
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
    dir = await Directory.systemTemp.createTemp('feather_preset_families_test');
    state = EditorState();
    addTearDown(state.dispose);
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
  });

  test('preset library lists Dart-parsed families; missing engine is safe',
      () async {
    await writeKpp(dir, 'a_paintbrush.kpp', family: 'paintbrush');
    await writeKpp(dir, 'b_eraser.kpp', family: 'eraser');

    // The unit-test sandbox has no native engine, so the engine-family
    // upgrade branch is skipped — the Dart parse stays the authority and
    // the load must complete without touching the engine. Bundled seeds
    // land in the folder too (rootBundle resolves the real assets here);
    // assert on the synthetic files specifically.
    await state.loadPresetLibrary(directory: dir.path);

    final byId = {for (final p in state.presets) p.id: p};
    expect(byId['a_paintbrush'], isNotNull,
        reason: 'preset id is the file name without the .kpp suffix');
    expect(byId['a_paintbrush']!.paintopId, 'paintbrush',
        reason: 'the declared <Paintop id> is the family authority while '
            'the native engine is absent');
    expect(byId['b_eraser']!.paintopId, 'eraser',
        reason: 'per-family presets keep their own declared family');
  });

  test('loadPresetLibrary seeds the bundled presets into the folder',
      () async {
    await state.loadPresetLibrary(directory: dir.path);

    // Bundled assets are seeded and listed (the exact count follows the
    // asset bundle; the seeding behaviour itself is the contract).
    expect(state.presets, isNotEmpty);
    final seeded = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.kpp'))
        .length;
    expect(seeded, isNonZero,
        reason: 'bundled .kpp files must be materialized on disk so the '
            'engine scan and the preset picker see real files');
  });

  test('a garbage .kpp is skipped, not fatal', () async {
    await File('${dir.path}${Platform.pathSeparator}broken.kpp')
        .writeAsBytes(List<int>.generate(64, (i) => i & 0xFF));
    await writeKpp(dir, 'good.kpp');

    await state.loadPresetLibrary(directory: dir.path);

    final ids = state.presets.map((p) => p.id).toSet();
    expect(ids, contains('good'),
        reason: 'the good preset survives');
    expect(ids, isNot(contains('broken')),
        reason: 'the garbage container is skipped, not fatal');
  });

  test('nested family subfolders are scanned recursively', () async {
    final sub = Directory(
        '${dir.path}${Platform.pathSeparator}paintbrush_family');
    await sub.create(recursive: true);
    await writeKpp(sub, 'nested.kpp', family: 'paintbrush');
    await writeKpp(dir, 'top.kpp', family: 'eraser');

    await state.loadPresetLibrary(directory: dir.path);

    final ids = state.presets.map((p) => p.id).toSet();
    expect(ids, containsAll(<String>['nested', 'top']),
        reason: 'Krita bundles presets in per-family subfolders — the '
            'library scan must recurse');
  });
}
