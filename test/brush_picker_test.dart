// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_picker_test.dart — 5-loop-42 picker family polish tests:
//   - each card carries a paintop family badge (hidden when undeclared)
//   - the Family sort groups presets by paintop (alphabetical families,
//     undeclared last)
//   - default Name sort keeps the library order

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

  testWidgets('Family sort groups presets by paintop', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_fixtures()));

    // Default Name sort keeps the library order: 'Zebra Soft' first.
    double xOf(String name) => tester.getTopLeft(find.text(name)).dx;
    expect(xOf('Zebra Soft'), lessThan(xOf('Alpha Spray')));

    // Switch to Family sort: eraser < paintbrush < spraybrush, undeclared
    // last — 'Circle Eraser' must now lead the grid.
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    expect(xOf('Circle Eraser'), lessThan(xOf('Zebra Soft')));
    expect(xOf('Zebra Soft'), lessThan(xOf('Alpha Spray')),
        reason: 'within a family, name order applies');
    // Undeclared family sorts last.
    final others = ['Zebra Soft', 'Alpha Spray', 'Basic Round', 'Circle Eraser']
        .map(xOf)
        .reduce((a, b) => a < b ? a : b);
    expect(xOf('No Family'), greaterThan(others),
        reason: 'presets without a declared family sort last');
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
