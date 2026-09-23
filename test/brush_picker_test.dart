// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_picker_test.dart — 3D floating brush space tests:
//   - each floating card carries a paintop family badge (hidden when
//     undeclared)
//   - the default Name sort keeps the library order along the ring
//     (left → right for a small centred set)
//   - the Family sort re-orders the ring into contiguous family
//     clusters and renders one legend chip per family
//     ("<family> · <count>", alphabetical, undeclared last)
//   - tapping a floating card still fires [onPick]

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
  testWidgets('floating cards carry a paintop family badge', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_fixtures()));

    // The ring starts centred, so all five fixtures are on the visible
    // arc. Declared families each render their own badge text.
    expect(find.text('paintbrush'), findsNWidgets(2));
    expect(find.text('spraybrush'), findsOneWidget);
    expect(find.text('eraser'), findsOneWidget);
    // No family legend in Name mode.
    expect(find.text('paintbrush · 2'), findsNothing);
  });

  testWidgets('default Name sort keeps the library order along the ring',
      (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_fixtures()));

    // Library order maps to ring order: 'Zebra Soft' (index 0) sits left
    // of 'Alpha Spray' (index 1) on the centred arc.
    double xOf(String name) => tester.getTopLeft(find.text(name)).dx;
    expect(xOf('Zebra Soft'), lessThan(xOf('Alpha Spray')));
    expect(xOf('Alpha Spray'), lessThan(xOf('Basic Round')));
  });

  testWidgets('Family sort clusters the ring and renders the legend',
      (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_fixtures()));

    // Switch to Family sort: the ring re-orders into contiguous family
    // clusters and the legend renders one chip per family.
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.text('eraser · 1'), findsOneWidget);
    expect(find.text('paintbrush · 2'), findsOneWidget);
    expect(find.text('spraybrush · 1'), findsOneWidget);
    expect(find.text('No family · 1'), findsOneWidget);

    // Ring order: eraser cluster, paintbrush cluster (by name), then
    // spraybrush, then the undeclared family last — left to right.
    double xOf(String name) => tester.getTopLeft(find.text(name)).dx;
    expect(xOf('Circle Eraser'), lessThan(xOf('Basic Round')));
    expect(xOf('Basic Round'), lessThan(xOf('Zebra Soft')));
    expect(xOf('Zebra Soft'), lessThan(xOf('Alpha Spray')));
    expect(xOf('Alpha Spray'), lessThan(xOf('No Family')));
  });

  testWidgets('pick still fires for the tapped floating card',
      (tester) async {
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
