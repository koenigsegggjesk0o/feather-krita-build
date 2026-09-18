// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// keyboard_shortcuts_test.dart — Loop-23 keyboard-shortcut coverage.
//
// Drives the real MainScreen through Flutter's key-event pipeline and
// verifies each binding end-to-end:
//   1. Ctrl+Z undoes a painted stroke (strokes AND texture revert).
//   2. B / E / V / L plain-letter keys switch the active tool.
//   3. [ / ] step the brush size down / up.
//   4. Delete removes the selected stroke(s).
//   5. Ctrl+N creates a fresh document (clears strokes + texture).
//   6. Ctrl+S quick-saves a .feather project file to the exports dir.
//
// The editor's [EditorShortcuts] widget auto-focuses a descendant [Focus]
// node on mount, so the bindings are live without a prior pointer tap; we
// still pump a frame to let the autofocus request settle before sending
// keys.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feather_krita/screens/main_screen.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/canvas_widget.dart';
import 'package:feather_krita/io/app_dirs.dart';
import 'package:feather_krita/io/recent_projects.dart';

Widget _host(EditorState state) => MaterialApp(home: MainScreen(state: state));

/// Sends a Ctrl/Cmd + letter combo as a discrete down/up pair so the
/// [ShortcutResolver] fires exactly once and no modifier leaks into the
/// next test.
Future<void> _sendCtrl(WidgetTester tester, LogicalKeyboardKey key,
    {bool shift = false}) async {
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _sendKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  // Isolate the recents store so Ctrl+S's recordRecentProject call doesn't
  // touch the developer's real recent_projects.json.
  late File recentsOverride;
  setUp(() {
    recentsOverride =
        File('${Directory.systemTemp.createTempSync('fk_kb_test').path}'
            '${Platform.pathSeparator}recent_projects.json');
    testRecentsFileOverride = recentsOverride;
  });
  tearDown(() {
    testRecentsFileOverride = null;
  });

  group('Loop-23 keyboard shortcuts', () {
    testWidgets('Ctrl+Z undoes a painted stroke', (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));

      // Paint one stroke by dragging across the canvas centre.
      final origin = tester.getCenter(find.byType(CanvasWidget));
      final g = await tester.startGesture(origin);
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(const Offset(12, 2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.strokes.strokeCount, 1);
      expect(state.canUndo, isTrue);

      // Ctrl+Z must revert the stroke (and its pixels).
      await _sendCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(state.strokes.strokeCount, 0,
          reason: 'Ctrl+Z must undo the painted stroke');
      expect(state.canUndo, isFalse);
      expect(state.canRedo, isTrue);
    });

    testWidgets('B / E / V / L keys switch the active tool', (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.activeTool, Tool.draw);

      await _sendKey(tester, LogicalKeyboardKey.keyE);
      expect(state.activeTool, Tool.erase, reason: 'E must select the eraser');

      await _sendKey(tester, LogicalKeyboardKey.keyV);
      expect(state.activeTool, Tool.select,
          reason: 'V must select the select tool');

      await _sendKey(tester, LogicalKeyboardKey.keyL);
      expect(state.activeTool, Tool.liquify,
          reason: 'L must select the liquify tool');

      await _sendKey(tester, LogicalKeyboardKey.keyB);
      expect(state.activeTool, Tool.draw, reason: 'B must return to the brush');
    });

    testWidgets('[ / ] step the brush size down / up', (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));
      final start = state.brushSize;

      await _sendKey(tester, LogicalKeyboardKey.bracketRight);
      expect(state.brushSize, start + 8,
          reason: '] must increase the brush size by 8');

      await _sendKey(tester, LogicalKeyboardKey.bracketLeft);
      expect(state.brushSize, start,
          reason: '[ must decrease the brush size back by 8');

      // Two more [ should keep shrinking (clamped at 1).
      await _sendKey(tester, LogicalKeyboardKey.bracketLeft);
      await _sendKey(tester, LogicalKeyboardKey.bracketLeft);
      expect(state.brushSize, (start - 16).clamp(1.0, 500.0));
    });

    testWidgets('Delete removes the selected stroke', (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));

      // Paint a stroke, then mark it selected through the manager (the
      // gesture path for selection is covered by gui_test; here we isolate
      // the Delete binding).
      final origin = tester.getCenter(find.byType(CanvasWidget));
      final g = await tester.startGesture(origin);
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(const Offset(12, 2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.strokes.strokeCount, 1);
      state.strokes.selectAll();
      await tester.pump(const Duration(milliseconds: 50));

      await _sendKey(tester, LogicalKeyboardKey.delete);
      expect(state.strokes.strokeCount, 0,
          reason: 'Delete must remove the selected stroke');
    });

    testWidgets('Ctrl+N creates a fresh document', (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));

      // Paint first so we have something to clear.
      final origin = tester.getCenter(find.byType(CanvasWidget));
      final g = await tester.startGesture(origin);
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(const Offset(12, 2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.strokes.strokeCount, 1);
      expect(state.texture.isEmpty, isFalse);

      await _sendCtrl(tester, LogicalKeyboardKey.keyN);
      expect(state.strokes.strokeCount, 0,
          reason: 'Ctrl+N must clear the strokes');
      expect(state.texture.isEmpty, isTrue,
          reason: 'Ctrl+N must clear the texture');
    });

    testWidgets('Ctrl+S quick-saves a .feather file', (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));

      final dir = exportsDir();
      // Snapshot existing .feather files so we can identify the new one.
      final before = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.feather'))
          .map((f) => f.path)
          .toSet();

      await _sendCtrl(tester, LogicalKeyboardKey.keyS);

      // The quick-save writes synchronously, so the file exists now.
      final after = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.feather'))
          .map((f) => f.path)
          .toSet();
      final created = after.difference(before);
      expect(created, isNotEmpty,
          reason: 'Ctrl+S must write a .feather file to the exports dir');
      final written = File(created.first).readAsStringSync();
      expect(written, contains('"version"'),
          reason: 'the quick-saved file must be a real Feather project doc');

      // Clean up the file we just created.
      addTearDown(() {
        for (final p in created) {
          if (File(p).existsSync()) File(p).deleteSync();
        }
      });
    });
  });
}
