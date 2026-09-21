// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// guide_surface_parity_test.dart — Loop-58 coverage for the guide-surface
// parity check that backs the open/save dialog strips.
//
// The contract mirrors the load path exactly (FeatherProjectDocument.parse
// + applyTo):
//   - canonical display names are the only exact spellings;
//   - known aliases/case variants restore the right type (aliased);
//   - unknown names and absent fields both end up as a default Sphere
//     (fallback / missing) — the two silent behaviors the dialogs now
//     surface instead of hiding.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/io/guide_surface_parity.dart';

void main() {
  group('strict vs tolerant name parsing (loop-58)', () {
    test('strict parser returns null for unknown names, tolerant falls back',
        () {
      expect(guideSurfaceTypeFromNameStrict('blob'), isNull);
      expect(guideSurfaceTypeFromNameStrict('Wobbly Sphere'), isNull);
      expect(guideSurfaceTypeFromNameStrict(''), isNull);
      expect(guideSurfaceTypeFromNameStrict(null), isNull);
      // The tolerant wrapper keeps its pre-loop-58 behavior bit-for-bit.
      expect(guideSurfaceTypeFromName('blob'), GuideSurfaceType.sphere);
      expect(guideSurfaceTypeFromName(''), GuideSurfaceType.sphere);
      expect(guideSurfaceTypeFromName(null), GuideSurfaceType.sphere);
    });

    test('strict parser accepts every spelling the tolerant one did', () {
      expect(guideSurfaceTypeFromNameStrict('Sphere'),
          GuideSurfaceType.sphere);
      expect(guideSurfaceTypeFromNameStrict('sphere'),
          GuideSurfaceType.sphere);
      expect(guideSurfaceTypeFromNameStrict(' Cylinder '),
          GuideSurfaceType.cylinder);
      expect(guideSurfaceTypeFromNameStrict('cone'), GuideSurfaceType.cone);
      expect(guideSurfaceTypeFromNameStrict('Ring / Torus'),
          GuideSurfaceType.ring);
      expect(guideSurfaceTypeFromNameStrict('ring'), GuideSurfaceType.ring);
      expect(guideSurfaceTypeFromNameStrict('torus'), GuideSurfaceType.ring);
      expect(guideSurfaceTypeFromNameStrict('plane'), GuideSurfaceType.plane);
      expect(guideSurfaceTypeFromNameStrict('Custom Curve'),
          GuideSurfaceType.customCurve);
      expect(guideSurfaceTypeFromNameStrict('customcurve'),
          GuideSurfaceType.customCurve);
      expect(guideSurfaceTypeFromNameStrict('custom_curve'),
          GuideSurfaceType.customCurve);
    });
  });

  group('checkGuideSurfaceParity levels', () {
    test('every canonical display name is an exact roundtrip', () {
      for (final type in GuideSurfaceType.values) {
        final report = checkGuideSurfaceParity(guideSurfaceTypeName(type));
        expect(report.level, GuideSurfaceParityLevel.exact,
            reason: '${guideSurfaceTypeName(type)} must roundtrip exactly');
        expect(report.resolvedType, type);
        expect(report.isLossless, isTrue);
        expect(report.surfaceLabel, guideSurfaceTypeName(type));
      }
    });

    test('aliases restore the right type but stay non-exact', () {
      final torus = checkGuideSurfaceParity('torus');
      expect(torus.level, GuideSurfaceParityLevel.aliased);
      expect(torus.resolvedType, GuideSurfaceType.ring);
      expect(torus.isLossless, isFalse);

      final screaming = checkGuideSurfaceParity('SPHERE');
      expect(screaming.level, GuideSurfaceParityLevel.aliased);
      expect(screaming.resolvedType, GuideSurfaceType.sphere);

      final snake = checkGuideSurfaceParity(' custom_curve ');
      expect(snake.level, GuideSurfaceParityLevel.aliased);
      expect(snake.resolvedType, GuideSurfaceType.customCurve);
    });

    test('unknown names fall back to Sphere exactly like the load path',
        () {
      final report = checkGuideSurfaceParity('Wobbly');
      expect(report.level, GuideSurfaceParityLevel.fallback);
      expect(report.resolvedType, GuideSurfaceType.sphere);
      expect(report.isLossless, isFalse);
    });

    test('a missing field defaults to Sphere (tolerant parse contract)',
        () {
      final report = checkGuideSurfaceParity(null);
      expect(report.level, GuideSurfaceParityLevel.missing);
      expect(report.storedName, isNull);
      expect(report.resolvedType, GuideSurfaceType.sphere);
    });

    test('detail lines are test-locked copy', () {
      expect(checkGuideSurfaceParity('Sphere').detail,
          'Sphere — opens exactly as saved');
      expect(checkGuideSurfaceParity('torus').detail,
          '"torus" opens as Ring / Torus');
      expect(checkGuideSurfaceParity('Wobbly').detail,
          '"Wobbly" is not a known surface — opens as Sphere');
      expect(checkGuideSurfaceParity(null).detail,
          'No guide surface stored — opens as Sphere');
    });

    test('shape-preserved copy is test-locked (loop-59)', () {
      // Exact + shape block.
      final exact = checkGuideSurfaceParity('Sphere', hasShapeParams: true);
      expect(exact.shapeRestored, isTrue);
      expect(exact.detail,
          'Sphere — opens exactly as saved (shape preserved)');
      // Aliased + shape block.
      final aliased =
          checkGuideSurfaceParity('torus', hasShapeParams: true);
      expect(aliased.shapeRestored, isTrue);
      expect(aliased.detail,
          '"torus" opens as Ring / Torus (shape preserved)');
      // Fallback/missing NEVER claim a restored shape: the load path
      // skips stored params for an unresolvable name.
      final fallback =
          checkGuideSurfaceParity('Wobbly', hasShapeParams: true);
      expect(fallback.shapeRestored, isFalse);
      expect(fallback.detail,
          '"Wobbly" is not a known surface — opens as Sphere');
      final missing = checkGuideSurfaceParity(null, hasShapeParams: true);
      expect(missing.shapeRestored, isFalse);
      expect(missing.detail, 'No guide surface stored — opens as Sphere');
    });
  });

  group('scanGuideSurfaceParity (file scan)', () {
    final dir = Directory.systemTemp.createTempSync('feather_parity_test');
    tearDownAll(() => dir.deleteSync(recursive: true));

    test('reads the stored name from a real project document', () {
      final f = File('${dir.path}${Platform.pathSeparator}cone.feather');
      f.writeAsStringSync('{"version":2,"fileName":"cone.feather",'
          '"guideSurface":"Cone","strokes":{"strokes":[]}}');
      final report = scanGuideSurfaceParity(f.path);
      expect(report, isNotNull);
      expect(report!.level, GuideSurfaceParityLevel.exact);
      expect(report.resolvedType, GuideSurfaceType.cone);
    });

    test('flags an unknown stored name from the file', () {
      final f = File('${dir.path}${Platform.pathSeparator}odd.feather');
      f.writeAsStringSync('{"version":2,"guideSurface":"Wobbly"}');
      final report = scanGuideSurfaceParity(f.path);
      expect(report!.level, GuideSurfaceParityLevel.fallback);
    });

    test('a document without the field reports missing', () {
      final f = File('${dir.path}${Platform.pathSeparator}bare.feather');
      f.writeAsStringSync('{"version":2,"fileName":"bare.feather"}');
      final report = scanGuideSurfaceParity(f.path);
      expect(report!.level, GuideSurfaceParityLevel.missing);
    });

    test('missing files, corrupt JSON and non-objects yield null', () {
      expect(scanGuideSurfaceParity(
          '${dir.path}${Platform.pathSeparator}nope.feather'), isNull);
      final corrupt = File(
          '${dir.path}${Platform.pathSeparator}corrupt.feather');
      corrupt.writeAsStringSync('{"version":2,');
      expect(scanGuideSurfaceParity(corrupt.path), isNull);
      final array = File('${dir.path}${Platform.pathSeparator}array.json');
      array.writeAsStringSync('[1,2,3]');
      expect(scanGuideSurfaceParity(array.path), isNull);
    });

    test('a document with the guideShape block reports shape preserved (loop-59)',
        () {
      final f = File('${dir.path}${Platform.pathSeparator}shaped.feather');
      f.writeAsStringSync('{"version":2,"fileName":"shaped.feather",'
          '"guideSurface":"Cylinder",'
          '"guideShape":{"params":{"radius":1.2,"height":2.4,"segments":32}},'
          '"strokes":{"strokes":[]}}');
      final report = scanGuideSurfaceParity(f.path);
      expect(report, isNotNull);
      expect(report!.level, GuideSurfaceParityLevel.exact);
      expect(report.shapeRestored, isTrue);
      expect(report.detail,
          'Cylinder — opens exactly as saved (shape preserved)');
    });

    test('an aliased name with a guideShape block keeps its caveat (loop-59)',
        () {
      final f = File('${dir.path}${Platform.pathSeparator}torus.feather');
      f.writeAsStringSync('{"version":2,"guideSurface":"torus",'
          '"guideShape":{"params":{"majorRadius":1.2}}}');
      final report = scanGuideSurfaceParity(f.path);
      expect(report!.level, GuideSurfaceParityLevel.aliased);
      expect(report.shapeRestored, isTrue);
      expect(report.detail, '"torus" opens as Ring / Torus (shape preserved)');
    });

    test('an empty or corrupt guideShape block does not claim shape (loop-59)',
        () {
      final empty = File('${dir.path}${Platform.pathSeparator}empty.feather');
      empty.writeAsStringSync('{"version":2,"guideSurface":"Sphere",'
          '"guideShape":{"params":{}}}');
      expect(scanGuideSurfaceParity(empty.path)!.shapeRestored, isFalse);

      final corrupt =
          File('${dir.path}${Platform.pathSeparator}badshape.feather');
      corrupt.writeAsStringSync('{"version":2,"guideSurface":"Sphere",'
          '"guideShape":"corrupt"}');
      final report = scanGuideSurfaceParity(corrupt.path);
      expect(report!.level, GuideSurfaceParityLevel.exact);
      expect(report.shapeRestored, isFalse);
      expect(report.detail, 'Sphere — opens exactly as saved');
    });
  });
}
