// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_picker_test.dart — 5-loop-42/48 picker family polish tests:
//   - each card carries a paintop family badge (hidden when undeclared)
//   - the Family sort renders SECTIONS (5-loop-48): one header
//     "<family> · <count>" per engine-declared paintop family,
//     alphabetical, undeclared last; cards grouped under their header
//   - default Name sort keeps the library order (flat grid)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/screens/brush_picker_screen.dart';

Widget _host(List<BrushPreset> presets, {String? activeId}) => MaterialApp(
      home: Scaffold(
        body: BrushPickerScreen(
          presets: presets,
          activePresetId: activeId,
          onPick: (_) {},
          onImport: () {},
          onClose: () {},
        ),
      ),
    );

List<BrushPreset> _fixtures() => [
      BrushPreset(id: '1', name: 'Zebra Soft', paintopId: 'paintbrush'),
      BrushPreset(id: '2', name: 'Alpha Spray', paintopId: 'spraybrush'),
      BrushPreset(id: '3', name: 'Basic Round', paintopId: 'paintbrush'),
      BrushPreset(id: '4', name: 'No Family', paintopId: ''),
      BrushPreset(id: '5', name: 'Circle Eraser', paintopId: 'eraser'),
    ];

void main() {
  testWidgets('preset cards carry a paintop family badge', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_fixtures()));

    // Declared families each render their own badge text.
    expect(find.text('paintbrush'), findsNWidgets(2));
    expect(find.text('spraybrush'), findsOneWidget);
    expect(find.text('eraser'), findsOneWidget);
  });

  testWidgets('default Name sort keeps the flat library order',
      (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_fixtures()));

    // Default Name sort keeps the library order: 'Zebra Soft' first.
    double xOf(String name) => tester.getTopLeft(find.text(name)).dx;
    expect(xOf('Zebra Soft'), lessThan(xOf('Alpha Spray')));
    // Flat grid — no section headers in Name mode.
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('Family sort renders per-family sections with counts',
      (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_fixtures()));

    // Switch to Family sort: the flat grid becomes one section per
    // engine-declared family (alphabetical, undeclared last), each with
    // a "<family> · <count>" header (5-loop-48).
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // Section headers render with per-family counts. The dialog viewport
    // shows the first two sections; deeper sections are asserted after
    // scrolling (slivers build lazily).
    expect(find.text('eraser · 1'), findsOneWidget);
    expect(find.text('paintbrush · 2'), findsOneWidget);

    double yOf(String name) => tester.getTopLeft(find.text(name)).dy;
    // Sections stack vertically: eraser section first, then paintbrush —
    // cards sit under their family's header.
    expect(yOf('Circle Eraser'), lessThan(yOf('Basic Round')));
    // 'Basic Round' and 'Zebra Soft' share the paintbrush section, so
    // they render side-by-side in the same row; the section header's
    // count ("paintbrush · 2") proves both grouped together.
    expect(yOf('Zebra Soft'), yOf('Basic Round'));
    // Within a family, name order applies (side-by-side cards).
    double xOf(String name) => tester.getTopLeft(find.text(name)).dx;
    expect(xOf('Basic Round'), lessThan(xOf('Zebra Soft')));

    // The spraybrush section follows — scroll it into view.
    await tester.dragUntilVisible(
      find.text('spraybrush · 1'),
      find.byType(CustomScrollView),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    expect(find.text('spraybrush · 1'), findsOneWidget);
    expect(find.text('Alpha Spray'), findsOneWidget);

    // The undeclared-family section renders last (drag the sectioned
    // CustomScrollView itself; the dialog hosts other Scrollables — the
    // search field and the category chip row).
    await tester.dragUntilVisible(
      find.text('No family · 1'),
      find.byType(CustomScrollView),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    expect(find.text('No family · 1'), findsOneWidget);
    expect(find.text('No Family'), findsOneWidget);
  });

  testWidgets('pick still fires for the tapped preset', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    BrushPreset? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BrushPickerScreen(
          presets: _fixtures(),
          activePresetId: null,
          onPick: (p) => picked = p,
          onImport: () {},
          onClose: () {},
        ),
      ),
    ));

    await tester.tap(find.text('Alpha Spray'));
    await tester.pumpAndSettle();
    expect(picked?.id, '2');
  });
}
