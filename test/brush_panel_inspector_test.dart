// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_panel_inspector_test.dart — 5-loop-68 settings-panel inspector
// entry:
//   - When the ACTIVE preset resolves in the loaded library, the preset
//     chip gains an inline manage-search button that opens the
//     engine-authoritative PresetInspectorSheet for the preset the user
//     is actually painting with (same sheet the picker exposes via
//     long-press on a card).
//   - Before the library is loaded (no presets) the entry is hidden.
//   - When the active name matches no preset the entry is hidden — the
//     chip degrades to the plain picker entry, never a dead button.
//
// Drives the panel through a REAL bundled Krita stock preset
// (assets/brushes/krita_paintbrush.kpp) so the inspector receives a
// file-backed preset exactly as a live session would.
//
// ALL disk I/O here is SYNCHRONOUS (FakeAsync-zone-safe; see
// brush_panel_family_ux_test.dart for the full rationale). Without the
// native bridge the inspector degrades to the pure-Dart parse — the
// DART PARSE badge asserted below is the designed no-engine path, which
// doubles as a regression guard that the panel entry works on stripped
// builds too.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/brush_settings_panel.dart';
import 'package:feather_krita/widgets/preset_inspector_sheet.dart';

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
  // The inspector dialog has a fixed 640 px height; the default 800x600
  // test surface (minus dialog insets) is too short for it. Use a tall
  // surface so the sheet lays out like on a real device.
  tester.view.physicalSize = const Size(1080, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('active preset in library: inspect button opens the inspector',
      (tester) async {
    final preset = presetFromDiskSync('assets/brushes/krita_paintbrush.kpp');
    final state = EditorState(presets: [preset]);
    addTearDown(state.dispose);
    state.loadBrushPreset(preset);

    await pumpPanel(tester, state);

    // The inline entry exists on the chip.
    expect(find.byIcon(Icons.manage_search_rounded), findsOneWidget);

    // Tapping it opens the inspector for the ACTIVE preset.
    await tester.tap(find.byIcon(Icons.manage_search_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(PresetInspectorSheet), findsOneWidget);
    // The sheet headers the ACTIVE preset's name... (scoped to the sheet:
    // the generic embedded name — e.g. "defaultPreset" before the
    // bundled-display-name pass — also renders on the chip behind the
    // dialog).
    expect(
      find.descendant(
        of: find.byType(PresetInspectorSheet),
        matching: find.text(preset.name),
      ),
      findsOneWidget,
    );
    // ...and carries the DART PARSE badge — this box has no native
    // bridge, exercising the designed degraded path end to end.
    expect(
      find.descendant(
        of: find.byType(PresetInspectorSheet),
        matching: find.text('DART PARSE'),
      ),
      findsOneWidget,
    );

    // Closing returns to the panel.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.byType(PresetInspectorSheet), findsNothing);
  });

  testWidgets('no library loaded: inspector entry is hidden', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);

    await pumpPanel(tester, state);

    expect(find.byIcon(Icons.manage_search_rounded), findsNothing);
  });

  testWidgets(
      'active name matches no preset: inspector entry is hidden '
      '(no dead button)', (tester) async {
    final preset = presetFromDiskSync('assets/brushes/krita_paintbrush.kpp');
    final state = EditorState(presets: [preset]);
    addTearDown(state.dispose);
    // A name that is NOT in the library — e.g. a stale display name.
    state.setBrushPresetName('Ghost Preset');

    await pumpPanel(tester, state);

    expect(find.byIcon(Icons.manage_search_rounded), findsNothing);
  });
}
