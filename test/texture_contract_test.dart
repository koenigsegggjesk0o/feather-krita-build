// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// texture_contract_test.dart — unit tests for the loop-51 per-fragment
// surface texturing: the shared shading contract (single source of truth
// for the whole-buffer bake and the painter's fallback sampler), the
// perspective-correct UV interpolation, the adaptive surface subdivision,
// and the texture mutation serial.

import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/scene_pipeline.dart';
import 'package:feather_krita/engine/synthetic_dab.dart';
import 'package:feather_krita/engine/texture_painter.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';

const Size _viewport = Size(800, 600);

SceneCameraInput _camera() {
  const fov = 60.0 * math.pi / 180.0;
  final pos = Vector3(0, 0, 6);
  final view = makeViewMatrix(pos, Vector3.zero(), Vector3(0, 1, 0));
  final proj = makePerspectiveMatrix(
      fov, _viewport.width / _viewport.height, 0.05, 1000.0);
  return SceneCameraInput(
    position: pos,
    view: view,
    viewProjection: proj * view,
    fovYRadians: fov,
  );
}

SceneSurfaceInput _surface({
  List<Vector3>? positions,
  List<Vector2>? uvs,
}) {
  positions ??= [
    Vector3(-1, -1, 0),
    Vector3(1, -1, 0),
    Vector3(0, 1, 0),
  ]; // CCW from +z → faces the camera at (0, 0, 6)
  uvs ??= [Vector2(0, 0), Vector2(1, 0), Vector2(0.5, 1)];
  return SceneSurfaceInput(
    positions: positions,
    indices: [0, 1, 2],
    uvs: uvs,
    sampleColor: (uv) => const Color(0xFF808080),
  );
}

void main() {
  group('surface shading contract', () {
    test('bare texel: tint RGB at the 0.35 glass alpha', () {
      final c = applySurfaceContract(10, 200, 30, 0, 1.0, 0.0, 0.0);
      expect(c[0], 255);
      expect(c[1], 0);
      expect(c[2], 0);
      expect(c[3], (0.35 * 255).round());
    });

    test('fully painted texel: source RGB at the 0.95 alpha', () {
      final c = applySurfaceContract(10, 200, 30, 255, 1.0, 0.0, 0.0);
      expect(c[0], 10);
      expect(c[1], 200);
      expect(c[2], 30);
      expect(c[3], (0.95 * 255).round());
    });

    test('half-covered texel matches the legacy blend exactly', () {
      // Legacy formula (pre-loop-51 inline sampler):
      //   rgb = tint·255·(1−sA) + src·sA ; a = (0.35 + 0.6·sA)·255
      final c = applySurfaceContract(0, 255, 0, 128, 1.0, 0.0, 0.0);
      final sA = 128 / 255.0;
      expect(c[0], (255.0 * (1 - sA) + 0 * sA).round());
      expect(c[1], (0.0 * (1 - sA) + 255 * sA).round());
      expect(c[2], 0);
      expect(c[3], ((0.35 + 0.6 * sA) * 255).round());
    });
  });

  group('bakeSurfaceContractImage', () {
    test('bakes endpoints and never mutates the source buffer', () {
      final px = Uint8List.fromList([
        0, 0, 0, 0, //
        255, 255, 255, 255,
      ]); // 2×1 texture
      final baked = bakeSurfaceContractImage(
        pixels: px,
        width: 2,
        height: 1,
        tintR: 0.2,
        tintG: 0.4,
        tintB: 0.6,
      );
      expect(px[3], 0); // source untouched
      expect(baked.length, 8);
      // Bare texel → tint RGB, glass alpha.
      expect(baked[0], (0.2 * 255).round());
      expect(baked[1], (0.4 * 255).round());
      expect(baked[2], (0.6 * 255).round());
      expect(baked[3], (0.35 * 255).round());
      // Opaque texel → source RGB, painted alpha.
      expect(baked[4], 255);
      expect(baked[5], 255);
      expect(baked[6], 255);
      expect(baked[7], (0.95 * 255).round());
    });
  });

  group('perspective-correct UV interpolation', () {
    test('uniform clipW reduces to plain barycentric', () {
      final uv = perspectiveCorrectUv(
        [0.5, 0.5, 0.0],
        [6, 6, 6],
        [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)],
      );
      expect(uv.x, closeTo(0.5, 1e-12));
      expect(uv.y, closeTo(0.0, 1e-12));
    });

    test('nearer vertex pulls the interpolation (non-uniform clipW)', () {
      // v1 sits at clipW 3 (twice as close as v0/v2 at 6): the affine
      // midpoint would be (0.5, 0.5) but the u/w math gives (1/3, 2/3).
      final uv = perspectiveCorrectUv(
        [0.0, 0.5, 0.5],
        [6, 3, 6],
        [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)],
      );
      final w0 = 0.0 / 6, w1 = 0.5 / 3, w2 = 0.5 / 6;
      final s = w0 + w1 + w2;
      expect(uv.x, closeTo(w1 * 1 / s, 1e-12));
      expect(uv.y, closeTo(w2 * 1 / s, 1e-12));
    });
  });

  group('per-fragment surface emission', () {
    test('screen-large triangles subdivide into 2×2 with UV corners', () {
      final items = buildSurfaceItems(
          surface: _surface(), camera: _camera(), viewport: _viewport,
          seqStart: 7);
      final tris = items.whereType<SceneTri>().toList();
      expect(tris.length, kTexSubdivideFactor * kTexSubdivideFactor);
      final seqs = tris.map((t) => t.seq).toList()..sort();
      expect(seqs, [7, 8, 9, 10]);
      for (final t in tris) {
        expect(t.uv0, isNotNull);
        expect(t.uv1, isNotNull);
        expect(t.uv2, isNotNull);
        // Sub-tri UVs stay inside the base UV hull (the 0..1 box here).
        for (final uv in [t.uv0!, t.uv1!, t.uv2!]) {
          expect(uv.dx, inInclusiveRange(0, 1));
          expect(uv.dy, inInclusiveRange(0, 1));
        }
      }
      // The grid corners coinciding with the base vertices reproduce
      // their UVs exactly (perspective-correct interpolation is exact at
      // the vertices).
      final corners = <Offset>[
        for (final t in tris) ...[t.uv0!, t.uv1!, t.uv2!]
      ];
      bool hasCorner(double u, double v) => corners
          .any((c) => (c.dx - u).abs() < 1e-9 && (c.dy - v).abs() < 1e-9);
      expect(hasCorner(0, 0), isTrue); // base v0
      expect(hasCorner(1, 0), isTrue); // base v1
      expect(hasCorner(0.5, 1), isTrue); // base v2
    });

    test('small screen triangles stay single with per-vertex UVs', () {
      final tiny = _surface(positions: [
        Vector3(-0.02, -0.02, 0),
        Vector3(0.02, -0.02, 0),
        Vector3(0, 0.02, 0),
      ]);
      final items = buildSurfaceItems(
          surface: tiny, camera: _camera(), viewport: _viewport, seqStart: 0);
      final tri = items.whereType<SceneTri>().single;
      expect(tri.uv0!.dx, closeTo(0, 1e-12));
      expect(tri.uv0!.dy, closeTo(0, 1e-12));
      expect(tri.uv1!.dx, closeTo(1, 1e-12));
      expect(tri.uv1!.dy, closeTo(0, 1e-12));
      expect(tri.uv2!.dx, closeTo(0.5, 1e-12));
      expect(tri.uv2!.dy, closeTo(1, 1e-12));
    });

    test('subdivision preserves winding (all sub-tris front-facing)', () {
      // Run the pipeline with the SAME camera twice: once with the huge
      // triangle, once with a 100× smaller copy that does not subdivide.
      // If subdivision flipped any sub-tri, the huge variant would cull
      // sub-tris the small variant keeps (both use the same winding).
      final cam = _camera();
      final big = buildSurfaceItems(
          surface: _surface(), camera: cam, viewport: _viewport, seqStart: 0);
      final small = buildSurfaceItems(
          surface: _surface(positions: [
            Vector3(-0.01, -0.01, 0),
            Vector3(0.01, -0.01, 0),
            Vector3(0, 0.01, 0),
          ]),
          camera: cam,
          viewport: _viewport,
          seqStart: 0);
      expect(big.whereType<SceneTri>().length, 4);
      expect(small.whereType<SceneTri>().length, 1);
    });

    test('back-face culling still applies before subdivision', () {
      final back = _surface(positions: [
        Vector3(-1, -1, 0),
        Vector3(0, 1, 0), // reversed winding → normal −z
        Vector3(1, -1, 0),
      ]);
      final items = buildSurfaceItems(
          surface: back, camera: _camera(), viewport: _viewport, seqStart: 0);
      expect(items, isEmpty);
    });

    test('behind-camera vertex still drops the triangle', () {
      final clipped = _surface(positions: [
        Vector3(-1, -1, 0),
        Vector3(1, -1, 0),
        Vector3(0, 1, 7), // behind the camera at z=6
      ]);
      final items = buildSurfaceItems(
          surface: clipped,
          camera: _camera(),
          viewport: _viewport,
          seqStart: 0);
      expect(items, isEmpty);
    });
  });

  group('texture mutation serial', () {
    test('paint/clear/fill/undo/redo/restore bump; reads do not', () {
      final t = TexturePainter(width: 8, height: 8);
      final v0 = t.version;
      expect(t.snapshot().length, 8 * 8 * 4);
      expect(t.isEmpty, isTrue);
      expect(t.version, v0, reason: 'reads must not bump the serial');

      t.paintDab(syntheticDab(3.0, 0xFFFF0000), 0.5, 0.5);
      expect(t.version, v0 + 1, reason: 'a modifying dab bumps');

      final v1 = t.version;
      t.undo();
      expect(t.version, greaterThan(v1));
      final v2 = t.version;
      t.redo();
      expect(t.version, greaterThan(v2));

      final v3 = t.version;
      t.fill(0, 255, 0);
      expect(t.version, greaterThan(v3));

      final snap = t.snapshot();
      final v4 = t.version;
      t.restore(snap);
      expect(t.version, greaterThan(v4));

      final v5 = t.version;
      t.clear();
      expect(t.version, greaterThan(v5));
    });

    test('an empty dab does not bump', () {
      final t = TexturePainter(width: 8, height: 8);
      final v = t.version;
      final dab = BrushDab(
          width: 0, height: 0, stride: 0, pixels: Uint8List(0)); // empty
      final modified = t.paintDab(dab, 0.5, 0.5);
      expect(modified, 0);
      expect(t.version, v);
    });
  });
}
