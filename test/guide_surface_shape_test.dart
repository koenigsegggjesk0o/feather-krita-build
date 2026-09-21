// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// guide_surface_shape_test.dart — loop-59 guide-surface shape-parameter
// persistence: every type factory captures its canonical construction
// parameters, forTypeWithParams rebuilds a surface from stored params
// (sanitized against hand-edited files), and the engine-level JSON
// roundtrip carries the params through.

import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/engine/guide_surface.dart';

void main() {
  group('shape parameter capture (loop-59)', () {
    test('every factory captures its canonical parameters', () {
      expect(
        GuideSurface.sphere(radius: 1.4, segments: 24, rings: 14)
            .shapeParams,
        {'radius': 1.4, 'segments': 24, 'rings': 14},
      );
      expect(
        GuideSurface.cylinder(radius: 1.2, height: 2.4).shapeParams,
        {'radius': 1.2, 'height': 2.4, 'segments': 32},
      );
      expect(
        GuideSurface.cone(radius: 1.2, height: 2.4).shapeParams,
        {'radius': 1.2, 'height': 2.4, 'segments': 32},
      );
      expect(
        GuideSurface.ring(majorRadius: 1.2, minorRadius: 0.25).shapeParams,
        {
          'majorRadius': 1.2,
          'minorRadius': 0.25,
          'majorSegments': 32,
          'minorSegments': 12,
        },
      );
      expect(
        GuideSurface.plane(size: 3.0).shapeParams,
        {'size': 3.0, 'subdivisions': 1},
      );
    });

    test('negative dimensions are captured post-clamp', () {
      expect(GuideSurface.sphere(radius: -2.0).shapeParams['radius'], 2.0);
      expect(
        GuideSurface.ring(majorRadius: -1.5, minorRadius: -0.5).shapeParams,
        {
          'majorRadius': 1.5,
          'minorRadius': 0.5,
          'majorSegments': 32,
          'minorSegments': 12,
        },
      );
    });

    test('the editor-default sphere captures the settings-screen dims', () {
      // EditorState's default surface is sphere(1.4, 24, 14) — NOT the
      // factory's raw defaults — so the captured params are what make
      // the roundtrip exact regardless of which defaults were used.
      expect(
        GuideSurface.sphere(radius: 1.4, segments: 24, rings: 14).shapeParams,
        isNot({
          'radius': 1.0,
          'segments': 32,
          'rings': 16,
        }),
      );
    });
  });

  group('forTypeWithParams (loop-59)', () {
    test('rebuilds each type deterministically from captured params', () {
      final originals = <GuideSurface>[
        GuideSurface.sphere(radius: 1.4, segments: 24, rings: 14),
        GuideSurface.cylinder(radius: 1.2, height: 2.4, segments: 16),
        GuideSurface.cone(radius: 0.8, height: 3.0, segments: 20),
        GuideSurface.ring(
          majorRadius: 1.2,
          minorRadius: 0.3,
          majorSegments: 24,
          minorSegments: 10,
        ),
        GuideSurface.plane(size: 3.0, subdivisions: 4),
      ];
      for (final original in originals) {
        final rebuilt = GuideSurface.forTypeWithParams(
          original.type,
          Map<String, dynamic>.of(original.shapeParams),
        );
        expect(rebuilt.type, original.type,
            reason: '${original.type} rebuild type');
        expect(rebuilt.mesh.vertexCount, original.mesh.vertexCount,
            reason: '${original.type} vertex count');
        expect(rebuilt.mesh.triangleCount, original.mesh.triangleCount,
            reason: '${original.type} triangle count');
        // Bit-identical first vertex: the rebuild is deterministic from
        // the same numbers.
        expect(rebuilt.mesh.positions.first.x,
            original.mesh.positions.first.x,
            reason: '${original.type} first vertex x');
        expect(rebuilt.mesh.positions.first.y,
            original.mesh.positions.first.y,
            reason: '${original.type} first vertex y');
        expect(rebuilt.mesh.positions.first.z,
            original.mesh.positions.first.z,
            reason: '${original.type} first vertex z');
        expect(rebuilt.shapeParams, original.shapeParams,
            reason: '${original.type} captured params');
      }
    });

    test('missing keys fall back to the editor-standard defaults', () {
      final s = GuideSurface.forTypeWithParams(
          GuideSurfaceType.sphere, const <String, dynamic>{});
      expect(s.shapeParams, {'radius': 1.4, 'segments': 24, 'rings': 14});
      final r = GuideSurface.forTypeWithParams(GuideSurfaceType.ring, null);
      expect(r.shapeParams['majorRadius'], 1.0);
      expect(r.shapeParams['minorSegments'], 12);
    });

    test('unknown keys are ignored, wrong-typed values fall back', () {
      final s = GuideSurface.forTypeWithParams(
        GuideSurfaceType.sphere,
        <String, dynamic>{
          'radius': 2.0,
          'wobble': 5.0,
          'segments': 'many',
          'rings': true,
        },
      );
      expect(s.shapeParams, {'radius': 2.0, 'segments': 24, 'rings': 14});
    });

    test('degenerate and pathological values are sanitized', () {
      final s = GuideSurface.forTypeWithParams(
        GuideSurfaceType.sphere,
        <String, dynamic>{
          'radius': -3.0, // mirrors the factories' .abs() clamp → 3.0
          'segments': 0, // nonsense → fallback 24
          'rings': -4, // nonsense → fallback 14
        },
      );
      expect(s.shapeParams, {'radius': 3.0, 'segments': 24, 'rings': 14});
      expect(s.mesh.vertexCount, greaterThan(0));

      final capped = GuideSurface.forTypeWithParams(
        GuideSurfaceType.sphere,
        <String, dynamic>{'segments': 100000, 'rings': 100000},
      );
      expect(capped.shapeParams['segments'], GuideSurface.kMaxShapeSegments);
      expect(capped.shapeParams['rings'], GuideSurface.kMaxShapeSegments);
      // The hard cap keeps a hand-edited file from asking the mesh
      // builder for a pathological vertex count.
      expect(capped.mesh.vertexCount,
          lessThanOrEqualTo(GuideSurface.kMaxShapeSegments * GuideSurface.kMaxShapeSegments + 2));
    });

    test('small tesselation counts floor at the per-key minimum', () {
      final s = GuideSurface.forTypeWithParams(
        GuideSurfaceType.sphere,
        <String, dynamic>{'segments': 1, 'rings': 1},
      );
      // segments floors at 3, rings at 2 — the mesh builder divides by
      // both and a 0/1 count would degenerate the sphere.
      expect(s.shapeParams['segments'], 3);
      expect(s.shapeParams['rings'], 2);
      expect(s.mesh.vertexCount, greaterThan(0));
    });

    test('customCurve rebuilds the plane forType returns', () {
      final c = GuideSurface.forTypeWithParams(
        GuideSurfaceType.customCurve,
        <String, dynamic>{'tubeRadius': 0.5},
      );
      expect(c.type, GuideSurfaceType.plane);
      expect(c.shapeParams, {'size': 2.0, 'subdivisions': 1});
    });

    test('non-finite numbers fall back instead of crashing the builder', () {
      final s = GuideSurface.forTypeWithParams(
        GuideSurfaceType.cylinder,
        <String, dynamic>{
          'radius': double.infinity,
          'height': double.nan,
        },
      );
      expect(s.shapeParams, {'radius': 1.0, 'height': 2.0, 'segments': 32});
    });
  });

  group('GuideSurface.toJson / fromJson params (loop-59)', () {
    test('params roundtrip through the engine-level JSON', () {
      final original =
          GuideSurface.cylinder(radius: 1.2, height: 2.4, segments: 16);
      final restored = GuideSurface.fromJson(original.toJson());
      expect(restored.type, GuideSurfaceType.cylinder);
      expect(restored.shapeParams, original.shapeParams);
      expect(restored.mesh.vertexCount, original.mesh.vertexCount);
      expect(restored.transform.storage, original.transform.storage);
    });

    test('fromJson without params keeps the legacy default build', () {
      final legacy = GuideSurface.fromJson(<String, dynamic>{
        'type': 'sphere',
        'transform': List<double>.filled(16, 0.0)
          ..[0] = 1.0
          ..[5] = 1.0
          ..[10] = 1.0
          ..[15] = 1.0,
        'color': [0.4, 0.6, 1.0],
        'visible': true,
        'locked': false,
        'controlPoints': <Object>[],
      });
      expect(legacy.type, GuideSurfaceType.sphere);
      // Pre-loop-59 fromJson built GuideSurface.sphere() — the raw
      // factory defaults — and that exact behavior is preserved.
      expect(legacy.shapeParams, {'radius': 1.0, 'segments': 32, 'rings': 16});
    });

    test('fromJson with a non-map params value ignores it', () {
      final restored = GuideSurface.fromJson(<String, dynamic>{
        'type': 'plane',
        'transform': List<double>.filled(16, 0.0)
          ..[0] = 1.0
          ..[5] = 1.0
          ..[10] = 1.0
          ..[15] = 1.0,
        'color': [0.4, 0.6, 1.0],
        'visible': true,
        'locked': false,
        'controlPoints': <Object>[],
        'params': 'not-a-map',
      });
      expect(restored.shapeParams, {'size': 2.0, 'subdivisions': 1});
    });
  });
}
