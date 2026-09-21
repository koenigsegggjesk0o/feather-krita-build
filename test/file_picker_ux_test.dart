// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// file_picker_ux_test.dart — Loop-21 file-picker UX polish coverage.
//
// Verifies the four user-visible additions:
//   1. "Save As…" writes to a user-named path (end-to-end through
//      MainScreen → ExportScreen → SaveAsDialog → _runExport).
//   2. The Open dialog's quick-pick rows now show file size + relative
//      modified time.
//   3. Recently opened projects persist across dialog reopens via the
//      recent_projects.json store.
//   4. A successful export surfaces a "Copy path" action whose tap
//      confirms via a snackbar (the clipboard itself is platform-
//      channel-mocked elsewhere; here we assert the UX wiring).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feather_krita/screens/main_screen.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/open_project_dialog.dart';
import 'package:feather_krita/widgets/save_as_dialog.dart';
import 'package:feather_krita/models/export_format.dart';
import 'package:feather_krita/io/recent_projects.dart';

Widget _host(EditorState state) => MaterialApp(home: MainScreen(state: state));

Widget _dialogHost(OpenProjectDialog dialog) =>
    MaterialApp(home: Scaffold(body: Center(child: Builder(builder: (_) => dialog))));

Widget _widgetHost(Widget dialog) =>
    MaterialApp(home: Scaffold(body: Center(child: Builder(builder: (_) => dialog))));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  group('Loop-21 file-picker UX', () {
    // ---- Test 1: Save As writes to a custom path ----------------------

    testWidgets(
        'Save As… writes the export to the user-named path',
        (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));

      // Open the export sheet.
      await tester.tap(find.text('Export'));
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('Save As…'), findsOneWidget,
          reason: 'the Save As button must be visible next to Export');

      // Open the Save-As dialog.
      await tester.tap(find.text('Save As…'));
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('Save As'), findsOneWidget,
          reason: 'the Save-As dialog title must render');

      // Type a full path (with a separator) so SaveAsDialog._resolvePath
      // uses it verbatim instead of joining initialDir + basename.
      final dir = Directory.systemTemp.createTempSync('feather_saveas_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fullPath =
          '${dir.path}${Platform.pathSeparator}my-custom-name.feather';

      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await tester.enterText(field, fullPath);

      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 450));
      // Let the async export future complete under the fake event loop.
      await tester.pump(const Duration(milliseconds: 450));

      expect(File(fullPath).existsSync(), isTrue,
          reason: 'Save As must write the project to the chosen path');
      final written = File(fullPath).readAsStringSync();
      expect(written, contains('"version"'),
          reason: 'the written file must be a real Feather project doc');

      // The success card must report the user-chosen path (not the
      // auto-stamped default).
      expect(find.textContaining('Saved:'), findsOneWidget);
      expect(find.textContaining('my-custom-name.feather'), findsOneWidget);
    });

    // ---- Test 2: Open dialog shows size + relative time ---------------

    testWidgets(
        'Open dialog candidate rows show file size and relative time',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('feather_openmeta_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Write a project file with a known size.
      final file =
          File('${dir.path}${Platform.pathSeparator}sketch.feather');
      file.writeAsStringSync('{"version":2,"fileName":"sketch.feather",'
          '"texture":{"width":512,"height":512},'
          '"guideSurface":"Sphere",'
          '"brush":{"preset":"Pencil","size":21.00,"opacity":0.500,'
          '"color":4294901760,"mirrorX":false,"mirrorY":false,"mirrorZ":false},'
          '"strokes":{"strokes":[],"selectedIds":[],"nextId":1}}');

      // Isolate the recents store so no stale entries leak in.
      final recentsOverride =
          File('${dir.path}${Platform.pathSeparator}recent_projects.json');
      testRecentsFileOverride = recentsOverride;
      addTearDown(() => testRecentsFileOverride = null);

      await tester.pumpWidget(_dialogHost(
        OpenProjectDialog(initialDir: dir.path),
      ));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Open project'), findsOneWidget);
      expect(find.text('Recent exports'), findsOneWidget);
      expect(find.text('sketch.feather'), findsOneWidget,
          reason: 'the candidate basename must render');

      // The size+time line: must contain a size unit AND the word "ago"
      // (or "just now"). The exact text is formatter-dependent, so we
      // assert the two observable tokens separately. The tile renders
      // them as a single "$size · $time" Text, so we use contains.
      expect(
          find.byWidgetPredicate((w) {
            if (w is! Text) return false;
            final s = w.data ?? '';
            return s.contains('ago') || s.contains('just now');
          }),
          findsWidgets,
          reason: 'a relative-time token must appear on each candidate row');
      expect(
          find.byWidgetPredicate((w) {
            if (w is! Text) return false;
            final s = w.data ?? '';
            return RegExp(r'\b(B|KB|MB)\b').hasMatch(s);
          }),
          findsWidgets,
          reason: 'a file-size unit must appear on each candidate row');
    });

    // ---- Test 3: Recent projects persist across dialog opens ----------

    testWidgets(
        'Recent projects persist across dialog opens',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('feather_recents_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      // Isolate the recents store to a file inside the temp dir.
      final recentsOverride =
          File('${dir.path}${Platform.pathSeparator}recent_projects.json');
      testRecentsFileOverride = recentsOverride;
      addTearDown(() => testRecentsFileOverride = null);

      // Create a project file OUTSIDE the dialog's initialDir so it can
      // only surface via the persisted recents list (not the candidates
      // scan).
      final outsideDir =
          Directory.systemTemp.createTempSync('feather_recents_outside');
      addTearDown(() => outsideDir.deleteSync(recursive: true));
      final outsideFile = File(
          '${outsideDir.path}${Platform.pathSeparator}from-email.feather');
      outsideFile.writeAsStringSync('{"version":2,"fileName":"from-email.feather",'
          '"texture":{"width":512,"height":512},'
          '"guideSurface":"Sphere",'
          '"brush":{"preset":"Pencil","size":21.00,"opacity":0.500,'
          '"color":4294901760,"mirrorX":false,"mirrorY":false,"mirrorZ":false},'
          '"strokes":{"strokes":[],"selectedIds":[],"nextId":1}}');

      // Initial dialog open: no recents yet, only the (empty) exports dir.
      await tester.pumpWidget(_dialogHost(
        OpenProjectDialog(initialDir: dir.path),
      ));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Recent projects'), findsNothing,
          reason: 'no recents recorded yet → the section must be hidden');

      // Record the outside file as a recent.
      recordRecentProject(outsideFile.path);

      // Re-open the dialog (fresh widget tree via a new key so Flutter
      // creates a new State and initState re-reads the recents store —
      // this mirrors real usage where the dialog is dismissed and
      // re-shown). The recents section must now appear and list the file.
      await tester.pumpWidget(_dialogHost(
        OpenProjectDialog(key: const Key('reopen'), initialDir: dir.path),
      ));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Recent projects'), findsOneWidget,
          reason: 'after recordRecentProject the section must render');
      expect(find.text('from-email.feather'), findsOneWidget,
          reason: 'the persisted recent must be offered as a quick-pick');
    });

    // ---- Test 4: Post-export Copy path surfaces a snackbar ------------

    testWidgets(
        'a successful export surfaces a Copy-path action with a snackbar',
        (tester) async {
      final state = EditorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pump(const Duration(milliseconds: 100));

      // Run the default export (FeatherProject pre-selected).
      await tester.tap(find.text('Export'));
      await tester.pump(const Duration(milliseconds: 450));
      final button = find.ancestor(
        of: find.text('Export'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      );
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.textContaining('Saved:'), findsOneWidget,
          reason: 'export must have succeeded');

      expect(find.text('Copy path'), findsOneWidget,
          reason: 'the Copy-path action must appear on the success card');
      expect(find.text('Show in folder'), findsOneWidget);

      // The success row sits inside the dialog's SingleChildScrollView;
      // on the widget-test viewport (800x600) it can be clipped below
      // the fold. Scroll it into view before tapping so the gesture
      // actually reaches the TextButton.
      await tester.ensureVisible(find.text('Copy path'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Copy path'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 450));
      // The toast routes through MainScreen._toast → host Scaffold's
      // messenger. The snackbar must be mounted in the tree.
      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'tapping Copy path must surface a SnackBar');
      expect(find.text('Path copied to clipboard'), findsOneWidget,
          reason: 'tapping Copy path must confirm via a snackbar');
    });
  });

  group('Loop-58 guide-surface parity', () {
    testWidgets(
        'Open dialog shows the parity strip after a row tap (aliased name)',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('feather_parity_open');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file =
          File('${dir.path}${Platform.pathSeparator}aliased.feather');
      file.writeAsStringSync('{"version":2,"fileName":"aliased.feather",'
          '"guideSurface":"torus",'
          '"strokes":{"strokes":[]}}');

      final recentsOverride =
          File('${dir.path}${Platform.pathSeparator}recent_projects.json');
      testRecentsFileOverride = recentsOverride;
      addTearDown(() => testRecentsFileOverride = null);

      await tester.pumpWidget(_dialogHost(
        OpenProjectDialog(initialDir: dir.path),
      ));
      await tester.pump(const Duration(milliseconds: 250));

      // No path in the field yet → no verdict on screen.
      expect(find.textContaining('Guide surface:'), findsNothing,
          reason: 'the strip must stay hidden until a file is picked');

      // Tapping the candidate row fills the path field; the strip must
      // appear in the SAME frame with the aliased verdict.
      await tester.tap(find.text('aliased.feather'));
      await tester.pump();

      expect(find.text('Guide surface: Ring / Torus'), findsOneWidget,
          reason: 'the strip must show the resolved type, not the raw name');
      expect(find.text('"torus" opens as Ring / Torus'), findsOneWidget,
          reason: 'the aliased detail must render verbatim');
    });

    testWidgets(
        'Open dialog strip distinguishes exact from unknown-name fallback',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('feather_parity_two');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}${Platform.pathSeparator}exact.feather')
          .writeAsStringSync('{"version":2,"guideSurface":"Sphere"}');
      File('${dir.path}${Platform.pathSeparator}odd.feather')
          .writeAsStringSync('{"version":2,"guideSurface":"Wobbly"}');

      final recentsOverride =
          File('${dir.path}${Platform.pathSeparator}recent_projects.json');
      testRecentsFileOverride = recentsOverride;
      addTearDown(() => testRecentsFileOverride = null);

      await tester.pumpWidget(_dialogHost(
        OpenProjectDialog(initialDir: dir.path),
      ));
      await tester.pump(const Duration(milliseconds: 250));

      // Canonical name → exact roundtrip verdict.
      await tester.tap(find.text('exact.feather'));
      await tester.pump();
      expect(find.text('Guide surface: Sphere'), findsOneWidget);
      expect(find.text('Sphere — opens exactly as saved'), findsOneWidget);

      // Unknown name → the SAME resolved type (Sphere) but the detail
      // must now warn that the stored name is not known.
      await tester.tap(find.text('odd.feather'));
      await tester.pump();
      expect(find.text('Guide surface: Sphere'), findsOneWidget);
      expect(find.text('"Wobbly" is not a known surface — opens as Sphere'),
          findsOneWidget);
      expect(find.text('Sphere — opens exactly as saved'), findsNothing,
          reason: 'the stale exact verdict must be replaced');
    });

    testWidgets(
        'Save-As dialog for .feather discloses the stored guide surface',
        (tester) async {
      await tester.pumpWidget(_widgetHost(const SaveAsDialog(
        format: ExportFormat.featherProject,
        baseName: 'doc',
        guideSurfaceName: 'Cylinder',
      )));
      await tester.pump();

      expect(find.text('Guide surface: Cylinder'), findsOneWidget);
      expect(find.text('stored by type — reopens with the default shape'),
          findsOneWidget);

      // Non-project formats carry no guide-surface row.
      await tester.pumpWidget(_widgetHost(const SaveAsDialog(
        format: ExportFormat.png,
        baseName: 'doc',
      )));
      await tester.pump();
      expect(find.textContaining('Guide surface:'), findsNothing,
          reason: 'only .feather saves disclose the guide surface');
    });
  });
}
