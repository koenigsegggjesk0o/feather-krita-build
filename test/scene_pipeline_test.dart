// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// scene_pipeline_test.dart — unit tests for the loop-50 Feather-3D
// unified depth-sorted scene pipeline (pure Dart, no widget harness).

import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Size;

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

  group('degenerate tangent inheritance (loop-55)', () {
    // Straight strokes along +x at z=0, camera on the z axis. Each
    // segment's expected color is computed by calling shadeSegment with
    // the SAME inputs buildStrokeItems must produce (inherited tangent +
    // the segment's own mid) — same function, same arguments, so the
    // emitted color must match bit-for-bit.
    test('a coincident pair mid-run shades continuously, not ambient', () {
      final cam = _camera();
      final base = const Color(0xFF808080);
      final items = buildStrokeItems(
          stroke: _stroke(points: [
            Vector3(0, 0, 0),
            Vector3(1, 0, 0),
            Vector3(1, 0, 0), // coincident pair → zero-length tangent
            Vector3(2, 0, 0),
          ]),
          camera: cam,
          viewport: _viewport,
          seqStart: 0);
      final segs = items.whereType<SceneSegment>().toList();
      expect(segs.length, 3);
      // The degenerate middle segment INHERITED the previous (1,0,0)
      // tangent and shades at its own mid — no dark fleck.
      final expected = shadeSegment(
          base, Vector3(1, 0, 0), Vector3(1, 0, 0), cam.position);
      expect(_r(segs[1].color), _r(expected));
      expect(_g(segs[1].color), _g(expected));
      expect(_b(segs[1].color), _b(expected));
      // The old bug's symptom: the fleck sat at the ambient floor while
      // the stroke was lit. Inherited shading clears it.
      expect(_r(segs[1].color), _r(segs[0].color),
          reason: 'same tangent, mids 0.5 apart on a 6-unit orbit: '
              'the Lambert ramp differs by well under a rounding step');
      // The two straight segments shade from their own real tangents.
      expect(_r(segs[0].color),
          _r(shadeSegment(base, Vector3(1, 0, 0), Vector3(0.5, 0, 0),
              cam.position)));
      expect(_r(segs[2].color),
          _r(shadeSegment(base, Vector3(1, 0, 0), Vector3(1.5, 0, 0),
              cam.position)));
    });

    test('a degenerate prefix inherits the first good tangent ahead', () {
      // Touch-down burst: the first two samples coincide, so segment 0
      // has no previous good tangent and must look AHEAD.
      final cam = _camera();
      final base = const Color(0xFF808080);
      final items = buildStrokeItems(
          stroke: _stroke(points: [
            Vector3(0, 0, 0),
            Vector3(0, 0, 0),
            Vector3(1, 0, 0),
            Vector3(2, 0, 0),
          ]),
          camera: cam,
          viewport: _viewport,
          seqStart: 0);
      final segs = items.whereType<SceneSegment>().toList();
      expect(segs.length, 3);
      final expected = shadeSegment(
          base, Vector3(1, 0, 0), Vector3(0, 0, 0), cam.position);
      expect(_r(segs[0].color), _r(expected));
      expect(_g(segs[0].color), _g(expected));
      expect(_b(segs[0].color), _b(expected));
      expect(_r(segs[0].color), greaterThan((0x80 * kSceneAmbient).round()),
          reason: 'inherited shading must clear the ambient floor');
    });

    test('a run with no good tangent keeps the legacy ambient behaviour',
        () {
      final items = buildStrokeItems(
          stroke: _stroke(points: [
            Vector3(0, 0, 0),
            Vector3(0, 0, 0),
            Vector3(0, 0, 0),
          ]),
          camera: _camera(),
          viewport: _viewport,
          seqStart: 0);
      final segs = items.whereType<SceneSegment>().toList();
      expect(segs.length, 2);
      for (final seg in segs) {
        expect(_r(seg.color).isNaN, isFalse);
        // Ambient floor exactly: base 0x80 scaled by kSceneAmbient.
        expect(_r(seg.color), (0x80 * kSceneAmbient).round());
        expect(_g(seg.color), (0x80 * kSceneAmbient).round());
        expect(_b(seg.color), (0x80 * kSceneAmbient).round());
      }
    });

    test('interleaved degenerate segments keep following the run direction',
        () {
      // slow-fast-slow pointer pattern: BOTH degenerate segments share
      // mid (1,0,0) and inherit tangent (1,0,0), so their colors match
      // each other exactly and follow the direction the stroke moved.
      final cam = _camera();
      final base = const Color(0xFF808080);
      final items = buildStrokeItems(
          stroke: _stroke(points: [
            Vector3(0, 0, 0),
            Vector3(1, 0, 0),
            Vector3(1, 0, 0),
            Vector3(1, 0, 0),
            Vector3(2, 0, 0),
          ]),
          camera: cam,
          viewport: _viewport,
          seqStart: 0);
      final segs = items.whereType<SceneSegment>().toList();
      expect(segs.length, 4);
      final expected = shadeSegment(
          base, Vector3(1, 0, 0), Vector3(1, 0, 0), cam.position);
      expect(_r(segs[1].color), _r(expected));
      expect(_r(segs[2].color), _r(expected));
      expect(_g(segs[1].color), _g(expected));
      expect(_b(segs[2].color), _b(expected));
      expect(_r(segs[1].color), greaterThan((0x80 * kSceneAmbient).round()));
    });
  });

  group('silhouette contour feathering (loop-56)', () {
    // Small front-facing triangle: world area 0.125 → ≈937 px² on the
    // test viewport (focal ≈ 519.6 px at distance 6), safely below
    // kTexSubdivideAreaPx so the emission path is the unsubdivided one.
    final smallTri = [
      Vector3(-0.25, -0.25, 0),
      Vector3(0.25, -0.25, 0),
      Vector3(0, 0.25, 0),
    ]; // CCW from +z → faces the camera at (0, 0, 6)

    Offset proj(Vector3 w, SceneCameraInput cam) =>
        projectScenePoint(w, cam.viewProjection, _viewport)!.screen;

    test('a back-facing neighbour turns all shared edges into contours', () {
      final cam = _camera();
      // T1 is T0 with reversed winding: front + back copies sharing ALL
      // three edges — every T0 edge has a back-facing neighbour across
      // it, so all three are contour edges. T1 itself is culled and
      // emits nothing.
      final surface = SceneSurfaceInput(
        positions: smallTri,
        indices: [0, 1, 2, 0, 2, 1],
        uvs: [
          Vector2(0, 0),
          Vector2(1, 0),
          Vector2(0.5, 1),
        ],
        sampleColor: (uv) => const Color(0xFF808080),
      );
      final items = buildSurfaceItems(
          surface: surface, camera: cam, viewport: _viewport, seqStart: 0);

      expect(items.whereType<SceneTri>().length, 1); // T1 is culled
      final feathers = items.whereType<SceneFeather>().toList();
      expect(feathers.length, 3); // one per parent edge, none from T1

      // Exact geometry per edge: base ON the projected edge, outer at
      // +kContourFeatherWidthPx along the outward normal, ramp alpha =
      // kContourFeatherAlpha × texel alpha, depth = edge midpoint.
      for (var e = 0; e < 3; e++) {
        final wa = smallTri[e];
        final wb = smallTri[(e + 1) % 3];
        final wc = smallTri[(e + 2) % 3];
        final sa = proj(wa, cam);
        final sb = proj(wb, cam);
        final outward = outwardEdgeNormal(sa, sb, proj(wc, cam));
        final f = feathers.singleWhere(
            (f) => (f.a == sa && f.b == sb) || (f.a == sb && f.b == sa));
        expect(f.aOuter, sa + outward * kContourFeatherWidthPx);
        expect(f.bOuter, sb + outward * kContourFeatherWidthPx);
        expect((f.color.a * 255.0).round() & 0xff,
            (kContourFeatherAlpha * 255.0).round()); // 153
        expect(_r(f.color), 0x80);
        expect(_g(f.color), 0x80);
        expect(_b(f.color), 0x80);
        final midWorld = (wa + wb).scaled(0.5);
        expect(f.depth, cam.view.transform3(midWorld.clone()).z);
        expect(f.depth, -6.0); // z=0 plane sits exactly 6 from the camera
      }
      // Deterministic emission: edges in parent order (0,1) → (1,2) →
      // (2,0), after both triangles.
      final s0 = proj(smallTri[0], cam);
      final s1 = proj(smallTri[1], cam);
      final s2 = proj(smallTri[2], cam);
      int seqOf(Offset a, Offset b) => feathers
          .singleWhere((f) => (f.a == a && f.b == b) || (f.a == b && f.b == a))
          .seq;
      expect(seqOf(s0, s1), lessThan(seqOf(s1, s2)));
      expect(seqOf(s1, s2), lessThan(seqOf(s2, s0)));
    });

    test('an interior edge (front neighbour on both sides) never feathers',
        () {
      final cam = _camera();
      // Two coplanar front-facing triangles sharing edge (0,1): T1 winds
      // (1,0,3) so its normal also points at the camera. The shared edge
      // is interior — feathers may only appear on the four BOUNDARY
      // edges.
      final surface = SceneSurfaceInput(
        positions: [
          ...smallTri,
          Vector3(0, -0.75, 0), // v3 below the shared edge
        ],
        indices: [0, 1, 2, 1, 0, 3],
        uvs: List.generate(4, (i) => Vector2(i.toDouble(), 0)),
        sampleColor: (uv) => const Color(0xFF808080),
      );
      final items = buildSurfaceItems(
          surface: surface, camera: cam, viewport: _viewport, seqStart: 0);

      final feathers = items.whereType<SceneFeather>().toList();
      expect(feathers.length, 4); // (1,2) (2,0) (0,3) (3,1) — NOT (0,1)
      final sharedA = proj(smallTri[0], cam);
      final sharedB = proj(smallTri[1], cam);
      for (final f in feathers) {
        final onShared = (f.a == sharedA && f.b == sharedB) ||
            (f.a == sharedB && f.b == sharedA);
        expect(onShared, isFalse,
            reason: 'the interior shared edge must never feather');
      }
    });

    test('boundary edges (no neighbour) feather like contours', () {
      final cam = _camera();
      final items = buildSurfaceItems(
        surface: SceneSurfaceInput(
          positions: smallTri,
          indices: [0, 1, 2],
          uvs: [Vector2(0, 0), Vector2(1, 0), Vector2(0.5, 1)],
          sampleColor: (uv) => const Color(0xFF808080),
        ),
        camera: cam,
        viewport: _viewport,
        seqStart: 0,
      );
      expect(items.whereType<SceneTri>().length, 1);
      expect(items.whereType<SceneFeather>().length, 3);
      // Degenerate triangle (coincident vertices) is culled wholesale —
      // no triangles, no feathers.
      final degenerate = buildSurfaceItems(
        surface: SceneSurfaceInput(
          positions: [smallTri[0], smallTri[0], smallTri[2]],
          indices: [0, 1, 2],
          uvs: [Vector2(0, 0), Vector2(0, 0), Vector2(0.5, 1)],
          sampleColor: (uv) => const Color(0xFF808080),
        ),
        camera: cam,
        viewport: _viewport,
        seqStart: 0,
      );
      expect(degenerate, isEmpty);
    });

    test('close-up subdivision feathers per lattice boundary segment', () {
      final cam = _camera();
      // 2×2 world triangle → ≈15000 px² on screen → subdivided with
      // kTexSubdivideFactor = 2: each boundary parent edge contributes
      // k = 2 lattice segments → 6 feather quads total.
      const k = kTexSubdivideFactor;
      final big = [
        Vector3(-1, -1, 0),
        Vector3(1, -1, 0),
        Vector3(0, 1, 0),
      ];
      final items = buildSurfaceItems(
        surface: SceneSurfaceInput(
          positions: big,
          indices: [0, 1, 2],
          uvs: [Vector2(0, 0), Vector2(1, 0), Vector2(0.5, 1)],
          sampleColor: (uv) => const Color(0xFF808080),
        ),
        camera: cam,
        viewport: _viewport,
        seqStart: 0,
      );
      expect(items.whereType<SceneTri>().length, k * (k + 1) ~/ 2 +
          (k - 1) * k ~/ 2); // lattice: upper + lower sub-triangles
      final feathers = items.whereType<SceneFeather>().toList();
      expect(feathers.length, 3 * k);

      // Parent-edge outward normals (traversal-direction independent, so
      // they also cover the e=2 lattice table whose segments run
      // v0→v2 while the parent edge is v2→v0).
      final parentOutward = [
        outwardEdgeNormal(proj(big[0], cam), proj(big[1], cam),
            proj(big[2], cam)),
        outwardEdgeNormal(proj(big[1], cam), proj(big[2], cam),
            proj(big[0], cam)),
        outwardEdgeNormal(proj(big[2], cam), proj(big[0], cam),
            proj(big[1], cam)),
      ];

      // Lattice boundary world points per parent edge, same table the
      // pipeline builds (edge 0: Q(a,0); edge 1: Q(k−b,b); edge 2:
      // Q(0,b)).
      Vector3 q(int a, int b) =>
          big[0] * (1.0 - (a + b) / k) +
          big[1] * (a / k) +
          big[2] * (b / k);
      final edgePoints = [
        [for (var a = 0; a <= k; a++) q(a, 0)],
        [for (var b = 0; b <= k; b++) q(k - b, b)],
        [for (var b = 0; b <= k; b++) q(0, b)],
      ];

      for (var e = 0; e < 3; e++) {
        final pts = edgePoints[e];
        for (var s = 0; s < k; s++) {
          final expectA = proj(pts[s], cam);
          final expectB = proj(pts[s + 1], cam);
          final f = feathers.singleWhere(
              (f) => (f.a == expectA && f.b == expectB) ||
                  (f.a == expectB && f.b == expectA));
          // Same unit outward normal as the parent edge — collinear
          // segments must not drift per-segment.
          expect(f.aOuter, expectA + parentOutward[e] * kContourFeatherWidthPx);
          expect(f.bOuter, expectB + parentOutward[e] * kContourFeatherWidthPx);
        }
      }
    });

    test('feather alpha scales with the local texel alpha', () {
      final cam = _camera();
      final items = buildSurfaceItems(
        surface: SceneSurfaceInput(
          positions: smallTri,
          indices: [0, 1, 2],
          uvs: [Vector2(0, 0), Vector2(1, 0), Vector2(0.5, 1)],
          sampleColor: (uv) => const Color.fromARGB(128, 64, 96, 160),
        ),
        camera: cam,
        viewport: _viewport,
        seqStart: 0,
      );
      final f = items.whereType<SceneFeather>().first; // all 3 share the color
      final expectAlpha =
          (((128 / 255) * kContourFeatherAlpha) * 255.0).round() & 0xff;
      expect((f.color.a * 255.0).round() & 0xff, expectAlpha);
      expect(_r(f.color), 64);
      expect(_g(f.color), 96);
      expect(_b(f.color), 160);
    });

    test('outwardEdgeNormal points away from the interior, both directions',
        () {
      // Edge along +x with the triangle above it: outward is −y.
      final n = outwardEdgeNormal(Offset(0, 0), Offset(10, 0), Offset(0, 5));
      expect(n.dx, 0.0);
      expect(n.dy, -1.0);
      // Traversing the same edge backwards yields the SAME unit vector.
      final nRev = outwardEdgeNormal(Offset(10, 0), Offset(0, 0), Offset(0, 5));
      expect(nRev.dx, n.dx);
      expect(nRev.dy, n.dy);
      // Edge along +y with the triangle at +x: outward is −x.
      final n2 = outwardEdgeNormal(Offset(0, 0), Offset(0, 10), Offset(5, 5));
      expect(n2.dx, -1.0);
      expect(n2.dy, 0.0);
      // Degenerate edge carries no direction.
      expect(outwardEdgeNormal(Offset(1, 1), Offset(1, 1), Offset(0, 0)),
          Offset.zero);
    });
  });
}
