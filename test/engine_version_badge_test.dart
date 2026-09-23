// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_version_badge_test.dart — 5-loop-79 active-engine badge:
//   - EditorState.activeEngineVersion round-trips the bridge's
//     krita_brush_version through the real FFI binding. The plain
//     flutter-test VM loads the PORTABLE bridge (the dependency-free
//     host library), so the expected string is its honest
//     self-identification "FeatherBridge-Portable/1.0 (...)". This
//     exercises the full path: symbol lookup, native call, UTF-8
//     marshal — the same path the REAL bridge serves in the app.
//   - The settings panel renders the badge with the PORTABLE
//     provenance chip and the verbatim bridge string (and never the
//     REAL chip) in that environment.
//
// The REAL-engine string ("FeatherBridge-Krita/2.0 (real engine
// ...)") comes from the same export in krita_bridge_real.cpp and is
// smoke-gated in the krita-build CI legs against freshly compiled
// engine fixtures; the badge's REAL-chip classification is exercised
// there through the shipped bundles.

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

  test('activeEngineVersion round-trips the portable bridge string', () {
    final state = EditorState();
    addTearDown(state.dispose);
    final v = state.activeEngineVersion;
    expect(v, isNotNull);
    expect(v, startsWith('FeatherBridge-Portable/'));
    expect(v, contains('soft-round engine'));
  });

  testWidgets(
      'settings panel renders the badge with the PORTABLE chip in the VM',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await pumpPanel(tester, state);
    // The verbatim bridge string is on screen...
    expect(find.textContaining('FeatherBridge-Portable'), findsOneWidget);
    // ...classified as PORTABLE (the VM has no real engine), with no
    // REAL chip anywhere.
    expect(find.text('PORTABLE'), findsOneWidget);
    expect(find.text('REAL'), findsNothing);
  });
}
