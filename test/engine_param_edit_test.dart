// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_param_edit_test.dart — 5-loop-69 live paintop-settings param
// editing (roadmap (f)):
//   - EditorState.setEngineParam degrades to FALSE without a native
//     engine (stripped build) — callers surface "not supported", never
//     a dead edit.
//   - EditorState.activeEngineParams is EMPTY without a native engine.
//   - The settings panel's "Engine params" section hides entirely when
//     the live param map is unavailable (no dead affordance).
//
// This box (and the plain flutter-test environment) has NO native
// bridge, so these cover the designed degraded paths. The REAL-engine
// semantics of the underlying krita_brush_set_param export (map-of-
// record update, live opacity/flow/hardness application, unknown-key
// recording, argument rejection) are gated by smoke_test_real.cpp in
// the krita-build CI legs against freshly compiled engine fixtures.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/brush_settings_panel.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('setEngineParam returns false without a native engine', () {
    final state = EditorState();
    addTearDown(state.dispose);
    expect(state.setEngineParam('FlowValue', '0.5'), isFalse);
    // The rejected edit must not perturb the curated sliders.
    expect(state.brushFlow, isNot(0.5));
  });

  test('activeEngineParams is empty without a native engine', () {
    final state = EditorState();
    addTearDown(state.dispose);
    expect(state.activeEngineParams, isEmpty);
  });

  testWidgets(
      'settings panel hides the Engine params section without an engine',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);

    await pumpPanel(tester, state);

    expect(find.text('Engine params'), findsNothing);
    expect(find.byIcon(Icons.tune_rounded), findsNothing);
  });
}
