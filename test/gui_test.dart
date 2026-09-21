// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// gui_test.dart — Widget tests for the real editor wiring.
//
// These tests pump the ACTUAL MainScreen (CanvasWidget + panels + docks)
// with an injected EditorState and drive it through the Flutter gesture
// system, verifying the end-to-end GUI path:
//   pointer drag → CanvasWidget raycast → dab into TexturePainter →
//   stroke history → undo/redo through the app bar → export sheet.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feather_krita/screens/main_screen.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/canvas_widget.dart';
import 'package:feather_krita/widgets/joystick_widget.dart';
import 'package:feather_krita/widgets/stroke_list_panel.dart';
import 'package:feather_krita/engine/texture_image.dart';

Widget _host(EditorState state) => MaterialApp(home: MainScreen(state: state));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // The async texture-image raster (loop-51) is exercised nowhere here;
  // keep the painter on the synchronous flat-fallback path.
  TextureImageCache.enabled = false;

  testWidgets('editor mounts the real 3D canvas, panels and docks',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CanvasWidget), findsOneWidget);
    expect(find.byType(StrokeListPanel), findsNothing);
    expect(find.text('Draw'), findsOneWidget);
    expect(find.text('Erase'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    expect(find.byIcon(Icons.redo_rounded), findsOneWidget);
    expect(state.activeTool, Tool.draw);
  });

  testWidgets('tool dock switches the active tool', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Erase'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(state.activeTool, Tool.erase);

    await tester.tap(find.text('Liquify'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(state.activeTool, Tool.liquify);
  });

  testWidgets('a drag on the canvas paints a stroke into history and texture',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.texture.isEmpty, isTrue,
        reason: 'fresh document texture must start empty');
    expect(state.strokes.strokeCount, 0);

    // Drag horizontally across the middle of the viewport — the default
    // camera (distance 6, pitch -0.4) looks straight at the origin sphere
    // (radius 1.4), so the sweep raycasts onto the surface.
    final origin = tester.getCenter(find.byType(CanvasWidget));
    final gesture = await tester.startGesture(origin);
    for (var i = 1; i <= 8; i++) {
      await gesture.moveBy(const Offset(12, 2));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));

    expect(state.strokes.strokeCount, 1,
        reason: 'the gesture must be recorded as a stroke');
    expect(state.texture.isEmpty, isFalse,
        reason: 'dabs must have been stamped into the texture');
    expect(state.canUndo, isTrue);
  });

  testWidgets('app bar undo/redo round-trips a painted stroke',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));

    final origin = tester.getCenter(find.byType(CanvasWidget));
    final gesture = await tester.startGesture(origin);
    for (var i = 1; i <= 5; i++) {
      await gesture.moveBy(const Offset(14, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.strokes.strokeCount, 1);

    await tester.tap(find.byIcon(Icons.undo_rounded));
    await tester.pump(const Duration(milliseconds: 450));
    expect(state.strokes.strokeCount, 0);
    expect(state.canUndo, isFalse);
    expect(state.canRedo, isTrue);

    await tester.tap(find.byIcon(Icons.redo_rounded));
    await tester.pump(const Duration(milliseconds: 450));
    expect(state.strokes.strokeCount, 1);
    expect(state.canRedo, isFalse);
  });

  testWidgets('select tool shows the stroke list panel and joystick',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(JoystickWidget), findsNothing);

    await tester.tap(find.text('Select'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(state.activeTool, Tool.select);
    expect(find.byType(StrokeListPanel), findsOneWidget);
    expect(find.byType(JoystickWidget), findsOneWidget);

    await tester.tap(find.text('Select'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(StrokeListPanel), findsNothing);
  });

  testWidgets('export sheet opens and the export button writes a project file',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Export'));
    await tester.pump(const Duration(milliseconds: 450));
    // Format grid lists the real formats.
    expect(find.text('PNG Image'), findsOneWidget);
    expect(find.text('JPEG Image'), findsOneWidget);
    expect(find.text('Feather Project'), findsOneWidget);

    // The sheet pre-selects FeatherProject; run the export through the
    // sheet's FilledButton and expect the "Saved:" confirmation.
    final button = find.ancestor(
      of: find.text('Export'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 450));

    expect(find.textContaining('Saved:'), findsOneWidget,
        reason: 'a successful export must report its output path');
  });

  testWidgets('light tool activates and canvas drags orbit the key light',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.showGrid, isTrue,
        reason: 'the grid no longer depends on the Light tool (loop-52)');
    final defaultAz = state.lightRig.sunAzimuth;
    final defaultEl = state.lightRig.sunElevationDeg;

    await tester.tap(find.text('Light'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(state.activeTool, Tool.light);
    expect(state.showGrid, isTrue);

    // The intensity dial appears with the light tool (loop-54) and was
    // absent before it.
    final sliderFinder = find.byKey(const ValueKey('light_intensity_slider'));
    expect(sliderFinder, findsOneWidget);
    expect(state.lightRig.intensity, 1.0);

    // Drag right + up on the canvas: azimuth increases, elevation rises.
    // The gizmo + HUD light readout render inside the same frame.
    final center = tester.getCenter(find.byType(CanvasWidget));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(80, -50));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.moveBy(const Offset(80, -50));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.moveBy(const Offset(40, -20));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.lightRig.sunAzimuth, greaterThan(defaultAz));
    expect(state.lightRig.sunElevationDeg, greaterThan(defaultEl));
    expect(find.textContaining('sun '), findsOneWidget,
        reason: 'the HUD must show the live sun azimuth/elevation readout');

    // The dial drives the diffuse intensity: a right drag pins it to the
    // 100% clamp, a left drag sweeps it to the pure-ambient floor, and
    // the HUD's power readout follows. Orbiting the sun via the slider
    // must be impossible — the slider owns the gesture arena.
    await tester.drag(sliderFinder, const Offset(300, 0));
    await tester.pump();
    expect(state.lightRig.intensity, 1.0);

    final azBeforeSweep = state.lightRig.sunAzimuth;
    final elBeforeSweep = state.lightRig.sunElevationDeg;
    await tester.drag(sliderFinder, const Offset(-600, 0));
    await tester.pump();
    expect(state.lightRig.intensity, 0.0);
    expect(state.lightRig.sunAzimuth, azBeforeSweep,
        reason: 'a slider drag must never orbit the sun');
    expect(state.lightRig.sunElevationDeg, elBeforeSweep,
        reason: 'a slider drag must never orbit the sun');
    expect(find.textContaining('power 0%'), findsOneWidget,
        reason: 'the HUD power readout must follow the slider');
  });

  testWidgets('light preset row applies one-tap sun setups (loop-57)',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Light'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(state.activeTool, Tool.light);

    // All three curated presets render as chips above the dial.
    final noon = find.byKey(const ValueKey('light_preset_noon'));
    final golden = find.byKey(const ValueKey('light_preset_golden_hour'));
    final rim = find.byKey(const ValueKey('light_preset_rim'));
    expect(noon, findsOneWidget);
    expect(golden, findsOneWidget);
    expect(rim, findsOneWidget);

    // Park the rig somewhere non-default first: a preset tap must land
    // EXACTLY on the preset values — any orbit interference would drift
    // them — and must never move the camera.
    state.lightRig.orbitBy(-120, 60);
    state.lightRig.setIntensity(0.2);
    await tester.pump();
    final cameraBefore = state.camera.position.clone();

    // Golden hour: az 45°, el 8°, power 55% — HUD follows the same frame.
    await tester.tap(golden);
    await tester.pump();
    expect(state.lightRig.sunAzimuthDeg, closeTo(45.0, 1e-9),
        reason: 'the tap must set the golden-hour azimuth, not orbit it');
    expect(state.lightRig.sunElevationDeg, closeTo(8.0, 1e-9),
        reason: 'the tap must set the golden-hour elevation');
    expect(state.lightRig.intensity, 0.55);
    expect(find.textContaining('power 55%'), findsOneWidget,
        reason: 'the HUD power readout must follow the preset');

    // Noon: full-strength high front-top key.
    await tester.tap(noon);
    await tester.pump();
    expect(state.lightRig.sunAzimuthDeg, closeTo(90.0, 1e-9));
    expect(state.lightRig.sunElevationDeg, closeTo(80.0, 1e-9));
    expect(state.lightRig.intensity, 1.0);
    expect(find.textContaining('power 100%'), findsOneWidget);

    // Rim: backlit from the default camera.
    await tester.tap(rim);
    await tester.pump();
    expect(state.lightRig.sunAzimuthDeg, closeTo(270.0, 1e-9));
    expect(state.lightRig.sunElevationDeg, closeTo(20.0, 1e-9));
    expect(state.lightRig.intensity, 0.85);

    // Gesture isolation: the three taps never nudged the camera.
    expect(state.camera.position, cameraBefore,
        reason: 'a preset tap must never orbit the camera');
  });

  testWidgets('open dialog restores a saved project document', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.strokes.strokeCount, 0);

    // Write a real project file with one stroke into a temp location.
    // Synchronous IO on purpose: real async IO never completes under the
    // widget test's fake event loop (see loop-11 export-stall lesson).
    final dir = Directory.systemTemp
        .createTempSync('feather_open_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}saved.feather');
    file.writeAsStringSync('{"version":2,'
        '"fileName":"SavedDoc.feather",'
        '"texture":{"width":2048,"height":2048},'
        '"guideSurface":"Sphere",'
        '"brush":{"preset":"Pencil","size":21.00,"opacity":0.500,'
        '"color":4294901760,"mirrorX":false,"mirrorY":false,"mirrorZ":false},'
        '"strokes":{"strokes":[{"id":2,"brushType":"pencil",'
        '"color":4294901760,"thickness":12.0,"points":['
        '{"x":0.1,"y":0.0,"z":1.4,"p":0.8,"tx":0.0,"ty":0.0,"t":0.0,'
        '"u":0.5,"v":0.5}],'
        '"isVisible":true,"name":"loaded stroke"}],'
        '"selectedIds":[],"nextId":3}}');

    // Open the dialog through the app bar folder button.
    await tester.tap(find.byIcon(Icons.folder_open_rounded).first);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Open project'), findsOneWidget);

    await tester.enterText(
        find.byType(TextField), file.path);
    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 450));

    expect(state.strokes.strokeCount, 1);
    expect(state.strokes.strokes.first.name, 'loaded stroke');
    expect(state.strokes.strokes.first.id, 2);
    expect(state.brushPresetName, 'Pencil');
    expect(state.fileName, 'SavedDoc.feather');
    expect(state.strokes.strokes.first.points.first.uv, isNotNull,
        reason: 'v2 documents must restore per-point UVs');
    expect(state.texture.isEmpty, isFalse,
        reason: 'opening a project must re-render the canvas pixels from '
            'the strokes (loop-14 texture restore)');
  });

  testWidgets('canvas ticker mutes when idle and wakes on interaction',
      (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    final canvas = tester.state<CanvasWidgetState>(
        find.byType(CanvasWidget));

    // Camera starts settled: after a couple of idle frames the ticker must
    // stop scheduling work (battery muting).
    expect(canvas.isTicking, isFalse,
        reason: 'idle editor must mute its frame ticker');

    // Any canvas interaction wakes it.
    final origin = tester.getCenter(find.byType(CanvasWidget));
    final gesture = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 16));
    expect(canvas.isTicking, isTrue,
        reason: 'a stroke in flight must keep frames running');

    await gesture.up();
    // After the gesture ends the camera is settled and the stroke is done:
    // the next idle tick mutes the ticker again.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(canvas.isTicking, isFalse,
        reason: 'ticker must re-mute after the interaction settles');
  });
}
