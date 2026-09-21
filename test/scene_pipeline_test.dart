// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// scene_pipeline_test.dart — unit tests for the loop-50 Feather-3D
// unified depth-sorted scene pipeline (pure Dart, no widget harness).

import 'dart:math' as math;
import 'dart:ui' show Color, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/scene_pipeline.dart';

const Size _viewport = Size(800, 600);

// Color channel helpers on the non-deprecated double API.
int _r(Color c) => (c.r * 255.0).round() & 0xff;
int _g(Color c) => (c.g * 255.0).round() & 0xff;
int _b(Color c) => (c.b * 255.0).round() & 0xff;

SceneCameraInput _camera() {
  const fov = 60.0 * math.pi / 180.0;
  final pos = Vector3(0, 0, 6);
  final view = makeViewMatrix(pos, Vector3.zero(), Vector3(0, 1, 0));
  final proj =
      makePerspectiveMatrix(fov, _viewport.width / _viewport.height, 0.05, 1000.0);
  return SceneCameraInput(
    position: pos,
    view: view,
    viewProjection: proj * view,
    fovYRadians: fov,
  );
}

SceneSurfaceInput _surface({List<Vector3>? positions}) {
  positions ??= [
    Vector3(-1, -1, 0),
    Vector3(1, -1, 0),
    Vector3(0, 1, 0),
  ]; // CCW from +z → faces the camera at (0, 0, 6)
  return SceneSurfaceInput(
    positions: positions,
    indices: [0, 1, 2],
    uvs: [Vector2(0, 0), Vector2(1, 0), Vector2(0.5, 1)],
    sampleColor: (uv) => const Color(0xFF808080),
  );
}

SceneStrokeInput _stroke({
  required List<Vector3> points,
  double thickness = 20,
  Color color = const Color(0xFF808080),
  bool mirror = false,
}) {
  return SceneStrokeInput(
    points: points,
    pressures: List<double>.filled(points.length, 1.0),
    thickness: thickness,
    color: color,
    isMirror: mirror,
  );
}

SceneSurfaceInput _emptySurface() => SceneSurfaceInput(
      positions: const <Vector3>[],
      indices: const <int>[],
      uvs: const <Vector2>[],
      sampleColor: (uv) => const Color(0xFF808080),
    );

void main() {
  group('unified depth ordering', () {
    test('strokes and surface share one back-to-front order', () {
      final cam = _camera();
      // Triangle at z=0 (camera-space depth −6); stroke BEHIND it at
      // z=−1 (depth ≈ −7) must be drawn BEFORE the triangle, a stroke in
      // FRONT at z=+1 (depth ≈ −5) AFTER it. The pre-pipeline renderer
      // always painted strokes on top — this is the occlusion fix.
      final surface = _surface();
      final behind =
          _stroke(points: [Vector3(-0.5, 0, -1), Vector3(0.5, 0, -1)]);
      final inFront =
          _stroke(points: [Vector3(-0.5, 0.5, 1), Vector3(0.5, 0.5, 1)]);

      final items = buildUnifiedDrawList(
        surface: surface,
        strokes: [behind, inFront],
        camera: cam,
        viewport: _viewport,
      );

      // The 2-unit surface triangle is screen-huge, so the pipeline
      // subdivides it (loop-51) — all sub-tris sit on the same z=0 plane
      // at depth −6 and share the unified ordering.
      final tris = items.whereType<SceneTri>().toList();
      expect(tris, isNotEmpty);
      final tri = tris.first;
      final segs = items.whereType<SceneSegment>().toList();
      expect(segs.length, 2);
      final behindSeg = segs.firstWhere((s) => s.depth < tri.depth);
      final frontSeg = segs.firstWhere((s) => s.depth > tri.depth);
      expect(items.indexOf(behindSeg), lessThan(items.indexOf(tri)));
      expect(items.indexOf(tri), lessThan(items.indexOf(frontSeg)));
    });

    test('equal depths resolve deterministically via insertion order', () {
      final cam = _camera();
      final a = _stroke(points: [Vector3(0, 0, 0), Vector3(1, 0, 0)]);
      final b = _stroke(points: [Vector3(0, 0, 0), Vector3(1, 0, 0)]);
      final items = buildUnifiedDrawList(
        surface: _emptySurface(),
        strokes: [a, b],
        camera: cam,
        viewport: _viewport,
      );
      // Identical segments: stable output, never a comparator crash.
      expect(items.length, 2);
      expect(items[0].seq, lessThan(items[1].seq));
    });
  });

  group('perspective-correct stroke width', () {
    test('width scales with 1/clipW, anchored at the reference depth', () {
      final cam = _camera();
      // Camera at z=6: a sample at z=0 has clipW=6 (scale 1 — the legacy
      // default), a sample at z=3 has clipW=3 (scale 2).
      final far = _stroke(points: [Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0)]);
      final near = _stroke(points: [Vector3(-0.5, 0, 3), Vector3(0.5, 0, 3)]);
      final items = buildUnifiedDrawList(
        surface: _emptySurface(),
        strokes: [far, near],
        camera: cam,
        viewport: _viewport,
      );
      final segs = items.whereType<SceneSegment>().toList();
      expect(segs.length, 2);
      // Drawn back-to-front: far first.
      final farWidth = segs[0].widthPx;
      final nearWidth = segs[1].widthPx;
      expect(nearWidth, closeTo(farWidth * 2, 0.01));
      // Legacy contract at the reference pose: thickness × 0.5 × 1.0.
      expect(farWidth, closeTo(20 * 0.5, 0.01));
    });

    test('width scale clamps near the camera', () {
      final cam = _camera();
      // clipW = 6 − 5.7 = 0.3 → raw scale 20 → clamped to 5.
      final veryNear =
          _stroke(points: [Vector3(0, 0, 5.7), Vector3(0.2, 0, 5.7)]);
      final items = buildStrokeItems(
          stroke: veryNear, camera: cam, viewport: _viewport, seqStart: 0);
      final seg = items.whereType<SceneSegment>().single;
      expect(seg.widthPx, closeTo(20 * 0.5 * 5.0, 0.01));
    });
  });

  group('Lambert shading', () {
    test('segments brighten toward the key light, floored at ambient', () {
      final cam = _camera();
      final lit =
          _stroke(points: [Vector3(-1, 0, 0), Vector3(1, 0, 0)]);
      final dark =
          _stroke(points: [Vector3(0, -1, 0), Vector3(0, 1, 0)]);
      final litItems = buildStrokeItems(
          stroke: lit, camera: cam, viewport: _viewport, seqStart: 0);
      final darkItems = buildStrokeItems(
          stroke: dark, camera: cam, viewport: _viewport, seqStart: 0);
      final litSeg = litItems.whereType<SceneSegment>().single;
      final darkSeg = darkItems.whereType<SceneSegment>().single;

      // Base gray 128. Ambient floor: 128 × 0.62 ≈ 79.
      expect(_r(darkSeg.color), (128 * kSceneAmbient).round());
      // The +x ribbon's view-facing normal (0,−1,0) aligns with the key
      // light (−0.35,−1,−0.55) → clearly brighter than ambient, ≤ base.
      expect(_r(litSeg.color), greaterThan(_r(darkSeg.color)));
      expect(_r(litSeg.color), lessThanOrEqualTo(128));
      // Grayscale base stays neutral under scalar brightness.
      expect(_r(litSeg.color), _g(litSeg.color));
      expect(_r(litSeg.color), _b(litSeg.color));
    });

    test('lone samples (dots) render at the ambient floor', () {
      final cam = _camera();
      final s = _stroke(points: [Vector3(0, 0, 2)]);
      final items = buildStrokeItems(
          stroke: s, camera: cam, viewport: _viewport, seqStart: 0);
      final dot = items.whereType<SceneDot>().single;
      expect(_r(dot.color), (128 * kSceneAmbient).round());
      // Radius = width/2: point at z=2 → clipW=4 → scale 1.5, pressure 1
      // → width 15 → radius 7.5.
      expect(dot.radius, closeTo(20 * 0.5 * 1.5 * 1.0 / 2, 0.01));
    });
  });

  group('surface culling', () {
    test('back-facing triangles are culled', () {
      final cam = _camera();
      final back = _surface(positions: [
        Vector3(-1, -1, 0),
        Vector3(0, 1, 0), // reversed winding → normal −z
        Vector3(1, -1, 0),
      ]);
      final items = buildSurfaceItems(
          surface: back, camera: cam, viewport: _viewport, seqStart: 0);
      expect(items, isEmpty);
    });

    test('front-facing triangles survive with the sampled color', () {
      final cam = _camera();
      final items = buildSurfaceItems(
          surface: _surface(), camera: cam, viewport: _viewport, seqStart: 0);
      // Screen-huge triangle (≈1040 px wide) → 2×2 triangular-lattice
      // subdivision (loop-51).
      final tris = items.whereType<SceneTri>().toList();
      expect(tris.length, 4);
      for (final tri in tris) {
        expect(tri.color, const Color(0xFF808080));
        // Depth: camera-space z of the z=0 centroid = −6.
        expect(tri.depth, closeTo(-6, 1e-9));
      }
    });
  });

  group('stroke sampling edge cases', () {
    test('behind-camera samples split the ribbon; lone samples become dots',
        () {
      final cam = _camera(); // camera at z=6 → z=7 sample is behind it
      final s = _stroke(points: [
        Vector3(0, 0, 0),
        Vector3(1, 0, 0),
        Vector3(0, 0, 7),
        Vector3(0, 0, 2),
      ]);
      final items = buildStrokeItems(
          stroke: s, camera: cam, viewport: _viewport, seqStart: 0);
      expect(items.whereType<SceneSegment>().length, 1); // p0→p1
      expect(items.whereType<SceneDot>().length, 1); // p3
    });

    test('empty strokes produce no items', () {
      final items = buildStrokeItems(
          stroke: _stroke(points: const []),
          camera: _camera(),
          viewport: _viewport,
          seqStart: 0);
      expect(items, isEmpty);
    });

    test('zero-length segments do not crash (ambient fallback)', () {
      final items = buildStrokeItems(
          stroke: _stroke(points: [Vector3(0, 0, 0), Vector3(0, 0, 0)]),
          camera: _camera(),
          viewport: _viewport,
          seqStart: 0);
      expect(items.length, 1);
      expect(items.single, isA<SceneSegment>());
      // No NaN leaked into the color.
      final seg = items.single as SceneSegment;
      expect(_r(seg.color).isNaN, isFalse);
    });

    test('mirror strokes dim to 55% alpha', () {
      final items = buildStrokeItems(
          stroke: _stroke(
            points: [Vector3(0, 0, 0), Vector3(1, 0, 0)],
            color: const Color(0xCCFF0000),
            mirror: true,
          ),
          camera: _camera(),
          viewport: _viewport,
          seqStart: 0);
      final seg = items.whereType<SceneSegment>().single;
      expect(seg.color.a, closeTo(0.8 * 0.55, 0.01));
      // Red channel is Lambert-lit (this tangent faces the key light):
      // clearly above the ambient floor, never over-saturated.
      expect(_r(seg.color), greaterThan((255 * kSceneAmbient).round()));
      expect(_r(seg.color), lessThan(255));
    });
  });
}
