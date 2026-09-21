// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_panel_family_ux_test.dart — 5-loop-49 family-aware brush settings
// panel:
//   - No-hardness families (engine-declared paintopId, loop-41 data)
//     render NO hardness slider — a family-aware note explains the
//     absence instead, mirroring Krita's per-paintop option availability
//   - Hardness-capable families keep a live, enabled hardness slider
//   - Undeclared families keep the slider (default-enabled contract)
//   - The conditional layout does not disturb the other sliders' wiring
//
// The tests drive the panel through REAL bundled Krita stock presets
// (assets/brushes/krita_*.kpp — the very files kNoHardnessPaintops was
// derived from) so both seeding paths agree: with the native bridge
// present the ENGINE declares the family; without it the pure-Dart parse
// does. File-backed loads keep both paths exercised (an in-memory preset
// with no filePath skips the engine block by design).
//
// ALL disk I/O here is SYNCHRONOUS on purpose: async file reads never
// complete inside a testWidgets FakeAsync zone (classic flutter_test
// gotcha — the rest of the suite keeps its file I/O in plain tests),
// while [BrushPreset.loadFromBytes] + readAsBytesSync are instant and
// zone-safe.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/brush_settings_panel.dart';
import 'package:feather_krita/widgets/glass_slider.dart';

/// The bundled stock per-paintop default preset for a family, mapped to
/// its asset file (all inside assets/brushes/).
const Map<String, String> kFamilyStockAsset = <String, String>{
  'colorsmudge': 'krita_colorsmudge.kpp',
  'curvebrush': 'krita_curvebrush.kpp',
  'deformbrush': 'krita_deformbrush.kpp',
  'hairybrush': 'krita_hairybrush.kpp',
  'particlebrush': 'krita_particlebrush.kpp',
  'roundmarker': 'krita_roundmarker.kpp',
  'sketchbrush': 'krita_sketchbrush.kpp',
  'smudge': 'krita_smudge.kpp',
  'spraybrush': 'krita_spraybrush.kpp',
};

/// Loads a preset from disk synchronously (FakeAsync-zone-safe; see the
/// file header). [BrushPreset.loadFromBytes] is the sync twin of
/// loadFromFile and keeps the parsed file path for the engine block.
BrushPreset presetFromDiskSync(String relativePath) {
  final path = relativePath.replaceAll('/', Platform.pathSeparator);
  return BrushPreset.loadFromBytes(
    File(path).readAsBytesSync(),
    filePath: path,
  );
}

Future<void> pumpPanel(WidgetTester tester, EditorState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BrushSettingsPanel(
          state: state,
          onPickPreset: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

GlassSlider? hardnessSlider(WidgetTester tester) {
  final match = find.byWidgetPredicate(
    (w) => w is GlassSlider && w.label == 'Hardness',
  );
  return match.evaluate().isEmpty
      ? null
      : tester.widget<GlassSlider>(match);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('spraybrush (real stock preset) hides the slider, shows the note',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    state.loadBrushPreset(
        presetFromDiskSync('assets/brushes/krita_spraybrush.kpp'));

    await pumpPanel(tester, state);

    expect(state.activePaintopId, 'spraybrush',
        reason: 'the engine (or Dart parse) declares the spraybrush family');
    expect(state.activePaintopSupportsHardness, isFalse);
    expect(find.text('Hardness'), findsNothing,
        reason: 'spraybrush offers no hardness option — no slider at all');
    expect(find.textContaining('Hardness not available for Spraybrush'),
        findsOneWidget,
        reason: 'the absence is explained by a family-aware note');
    // The rest of the panel keeps its rhythm around the removed slider.
    expect(find.text('Size'), findsOneWidget);
    expect(find.text('Opacity'), findsOneWidget);
    expect(find.text('Flow'), findsOneWidget);
    expect(find.text('Spacing'), findsOneWidget);
    expect(find.text('Smoothing'), findsOneWidget);
    // The preset chip's family badge still names the engine family.
    expect(find.text('Spraybrush'), findsOneWidget);
    // The chip shows the loaded preset's display name.
    expect(find.text(state.brushPresetName), findsOneWidget);
  });

  testWidgets('paintbrush (real stock preset) keeps a live slider, no note',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    state.loadBrushPreset(
        presetFromDiskSync('assets/brushes/stock_basic_5_size.kpp'));

    await pumpPanel(tester, state);

    expect(state.activePaintopId, 'paintbrush');
    expect(state.activePaintopSupportsHardness, isTrue);
    final slider = hardnessSlider(tester);
    expect(slider, isNotNull,
        reason: 'paintbrush presets carry a hardness dimension');
    expect(slider!.enabled, isTrue,
        reason: 'a live slider, not a dimmed dead control');
    expect(find.textContaining('not available'), findsNothing);
    // Family badge on the chip mirrors the slider decision.
    expect(find.text('Paintbrush'), findsOneWidget);
  });

  testWidgets('undeclared family keeps the slider (default-enabled contract)',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    // No preset loaded: activePaintopId == '' → hardness stays enabled so
    // custom presets keep manual control (loop-41 contract, panel side).
    await pumpPanel(tester, state);

    expect(state.activePaintopId, isEmpty);
    final slider = hardnessSlider(tester);
    expect(slider, isNotNull);
    expect(slider!.enabled, isTrue);
    expect(find.textContaining('not available'), findsNothing);
  });

  testWidgets('every kNoHardnessPaintops family hides the slider',
      (tester) async {
    for (final family in BrushPreset.kNoHardnessPaintops) {
      final asset = kFamilyStockAsset[family];
      expect(asset, isNotNull,
          reason: '$family has a bundled stock default preset to test with');
      final file = File('assets${Platform.pathSeparator}brushes'
          '${Platform.pathSeparator}$asset');
      if (!file.existsSync()) continue; // stripped build — nothing to prove

      final state = EditorState();
      addTearDown(state.dispose);
      state.loadBrushPreset(presetFromDiskSync('assets/brushes/$asset'));
      await pumpPanel(tester, state);

      expect(find.text('Hardness'), findsNothing,
          reason: '$family must render the note, not the slider');
      expect(find.textContaining('Hardness not available for'),
          findsOneWidget, reason: '$family gets the explanatory note');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('layout change does not disturb the size slider wiring',
      (tester) async {
    // Synthetic file-backed spraybrush preset with a KNOWN size (42) so
    // the post-drag assertion is deterministic on both engine and CI paths.
    // Sync I/O only (FakeAsync zone — see the file header).
    final dir = Directory.systemTemp.createTempSync('brush_panel_family_ux');
    addTearDown(() => dir.deleteSync(recursive: true));
    const xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Paintop id="spraybrush" name="spray">\n'
        '  <param id="brush_size" min="1" max="1000" value="42"/>\n'
        '</Paintop>\n';
    final f = File('${dir.path}${Platform.pathSeparator}tiny_spray.kpp');
    f.writeAsBytesSync(xml.codeUnits);

    final state = EditorState();
    addTearDown(state.dispose);
    state.loadBrushPreset(
        BrushPreset.loadFromBytes(f.readAsBytesSync(), filePath: f.path));
    await pumpPanel(tester, state);

    expect(find.text('Hardness'), findsNothing);
    final before = state.brushSize;
    // Drag across the Size slider's track (just below its label row).
    final labelCenter = tester.getCenter(find.text('Size'));
    await tester.dragFrom(
      labelCenter + const Offset(0, 26),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(state.brushSize, greaterThan(before),
        reason: 'the conditional hardness block must not break siblings');
  });
}
