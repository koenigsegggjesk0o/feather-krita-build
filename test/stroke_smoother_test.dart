// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// stroke_smoother_test.dart — Loop-25 brush-stabilizer coverage.
//
// Verifies the pure [StrokeSmoother] utility:
//   1. strength=0 returns a deep copy unchanged (no smoothing, no aliasing).
//   2. strength>0 reduces jitter on a noisy synthetic path.
//   3. the output length matches the input length (no points dropped).
//   4. strength=1 never collapses a non-trivial path to a single point
//      (the centre weight keeps a faint trace of the original).
//   5. radiusFor maps [0,1] -> [0, maxRadius] monotonically.
//   6. UV channels smooth in lockstep with position (consistency).
//   7. empty input -> empty output (no crash).

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/models/stroke.dart';
import 'package:feather_krita/utils/stroke_smoother.dart';

void main() {
  group('Loop-25 StrokeSmoother', () {
    test('strength=0 returns a deep copy unchanged', () {
      final pts = [
        StrokePoint(position: Vector3(0, 0, 0), pressure: 0.5),
        StrokePoint(position: Vector3(1, 1, 0), pressure: 0.6),
        StrokePoint(position: Vector3(2, 0, 0), pressure: 0.7),
      ];
      final out = StrokeSmoother.smooth(pts, strength: 0);
      expect(out.length, pts.length);
      for (var i = 0; i < pts.length; i++) {
        expect(out[i].position.x, pts[i].position.x);
        expect(out[i].position.y, pts[i].position.y);
        expect(out[i].pressure, pts[i].pressure);
      }
      // Deep copy: mutating the output must not affect the input.
      out[0].position.x = 999;
      expect(pts[0].position.x, 0);
    });

    test('strength>0 reduces jitter on a noisy path', () {
      // A zig-zag: the smoothed centre point should be closer to the
      // midline (y=0) than the raw point (y=±1).
      final pts = <StrokePoint>[
        StrokePoint(position: Vector3(0, 0, 0)),
        StrokePoint(position: Vector3(1, 1, 0)),
        StrokePoint(position: Vector3(2, -1, 0)),
        StrokePoint(position: Vector3(3, 1, 0)),
        StrokePoint(position: Vector3(4, 0, 0)),
      ];
      final out = StrokeSmoother.smooth(pts, strength: 1.0);
      // The centre point (index 2, raw y=-1) becomes the average of its
      // window — its |y| must strictly decrease.
      expect(out[2].position.y.abs(), lessThan(1.0),
          reason: 'smoothing must pull the centre toward the midline');
      // The endpoints are clamped windows; they still move toward the
      // average of their available neighbours.
      expect(out[0].position.y.abs(), lessThanOrEqualTo(1.0));
    });

    test('output length matches input length', () {
      final pts = List.generate(
          20, (i) => StrokePoint(position: Vector3(i.toDouble(), i % 3, 0)));
      for (final s in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final out = StrokeSmoother.smooth(pts, strength: s);
        expect(out.length, pts.length, reason: 'strength=$s dropped points');
      }
    });

    test('strength=1 does not collapse a non-trivial path to a point', () {
      // A line from (0,0) to (10,0). Smoothing must not flatten the x
      // range to a single value — the endpoints are clamped windows
      // (so they drift inward toward the mean of their available
      // neighbours) but the interior stays on the line and the overall
      // span stays wide.
      final pts = List.generate(
          11, (i) => StrokePoint(position: Vector3(i.toDouble(), 0, 0)));
      final out = StrokeSmoother.smooth(pts, strength: 1.0);
      final xs = out.map((p) => p.position.x).toList();
      // The interior must not all collapse to a single x value.
      final distinct = xs.toSet().length;
      expect(distinct, greaterThan(1),
          reason: 'a line must not collapse to a single x');
      // The smoothed path still spans a meaningful range (endpoints
      // drift inward but not all the way to the global mean).
      final span = xs.reduce((a, b) => a > b ? a : b) -
          xs.reduce((a, b) => a < b ? a : b);
      expect(span, greaterThan(2.0),
          reason: 'smoothed span must stay wide, not collapse to ~0');
    });

    test('radiusFor maps [0,1] -> [0, maxRadius] monotonically', () {
      expect(StrokeSmoother.radiusFor(0), 0);
      expect(StrokeSmoother.radiusFor(1), StrokeSmoother.maxRadius);
      expect(StrokeSmoother.radiusFor(0.5), greaterThan(0));
      // Monotonic: bigger strength never yields a smaller radius.
      var prev = -1;
      for (var s = 0.0; s <= 1.0; s += 0.1) {
        final r = StrokeSmoother.radiusFor(s);
        expect(r, greaterThanOrEqualTo(prev));
        prev = r;
      }
    });

    test('UV channels smooth in lockstep with position', () {
      final pts = [
        StrokePoint(position: Vector3(0, 0, 0), uv: Vector2(0, 0)),
        StrokePoint(position: Vector3(1, 1, 0), uv: Vector2(0.25, 0.25)),
        StrokePoint(position: Vector3(2, 0, 0), uv: Vector2(0.5, 0.5)),
        StrokePoint(position: Vector3(3, 1, 0), uv: Vector2(0.75, 0.75)),
        StrokePoint(position: Vector3(4, 0, 0), uv: Vector2(1, 1)),
      ];
      final out = StrokeSmoother.smooth(pts, strength: 1.0);
      // The centre point's UV must equal its position's average in the
      // same proportion — both are window averages of the same span.
      expect(out[2].uv, isNotNull);
      // Average of uvs[0..4] in x = (0+0.25+0.5+0.75+1)/5 = 0.5.
      expect(out[2].uv!.x, closeTo(0.5, 1e-9));
      expect(out[2].uv!.y, closeTo(0.5, 1e-9));
    });

    test('empty input returns empty output', () {
      final out = StrokeSmoother.smooth(<StrokePoint>[], strength: 1.0);
      expect(out, isEmpty);
    });

    test('points with null UV preserve null in output', () {
      final pts = [
        StrokePoint(position: Vector3(0, 0, 0)), // uv null
        StrokePoint(position: Vector3(1, 1, 0)),
        StrokePoint(position: Vector3(2, 0, 0)),
      ];
      final out = StrokeSmoother.smooth(pts, strength: 1.0);
      // Any null in a window makes the whole window null.
      for (final p in out) {
        expect(p.uv, isNull);
      }
    });

    test('short input (<3 points) returns a deep copy unchanged', () {
      final pts = [
        StrokePoint(position: Vector3(0, 0, 0)),
        StrokePoint(position: Vector3(1, 1, 0)),
      ];
      final out = StrokeSmoother.smooth(pts, strength: 1.0);
      expect(out.length, 2);
      expect(out[0].position.x, 0);
      expect(out[1].position.x, 1);
    });
  });
}
