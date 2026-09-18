// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// stroke_smoother.dart — Post-capture stroke stabilizer (loop-25).
//
// Real styli and mice produce jittery strokes: tiny hand tremor, sub-pixel
// pointer quantisation, and the discrete sampling of pointer-move events
// all conspire to make raw [StrokePoint] lists look "shaky". A moving
// average is the simplest fix that is both cheap (O(n·w)) and symmetric
// (no phase lag at stroke ends, unlike a causal one-sided window).
//
// The smoother operates on an already-captured point list and returns a
// NEW list of [StrokePoint]s with the same length, where each output
// point's position is the weighted average of itself and its `radius`
// neighbours on each side. Pressure, tilt and UV follow the same window
// so the stroke stays internally consistent (no pressure/position skew).
//
// Tunable: `strength` in [0, 1] (0 = no smoothing, 1 = maximum). Internally
// mapped to a window radius of 0..6 points; the contribution of the
// centre point stays at (1 - strength) so strength=1 still keeps a
// faint trace of the original path (never collapses to a straight line
// unless the input is already near-straight).

import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/models/stroke.dart';

/// Pure stroke-smoothing utility. Stateless; safe to call from any thread.
class StrokeSmoother {
  /// Maximum window radius (points each side) at strength = 1.
  static const int maxRadius = 6;

  /// Maps a [0, 1] strength to a window radius in [0, maxRadius].
  static int radiusFor(double strength) {
    final s = strength.clamp(0.0, 1.0);
    return (s * maxRadius).round();
  }

  /// Smooths [points] by a symmetric moving average of window
  /// `2*radius + 1`. Returns a new list of the same length. The original
  /// list is not mutated. A radius of 0 (or a list with < 3 points)
  /// returns a deep copy unchanged.
  ///
  /// [strength] is the user-facing 0..1 dial; pass it directly, the
  /// method converts to a radius internally.
  static List<StrokePoint> smooth(List<StrokePoint> points,
      {required double strength}) {
    if (points.isEmpty) return <StrokePoint>[];
    final radius = radiusFor(strength);
    if (radius == 0 || points.length < 3) {
      return points.map((p) => p.copy()).toList();
    }

    final n = points.length;
    final out = List<StrokePoint>.filled(n, points.first.copy(),
        growable: false);

    for (var i = 0; i < n; i++) {
      // Symmetric window clamped at the ends.
      final lo = i - radius < 0 ? 0 : i - radius;
      final hi = i + radius >= n ? n - 1 : i + radius;
      final span = hi - lo + 1;

      var sx = 0.0, sy = 0.0, sz = 0.0;
      var sp = 0.0;
      var stx = 0.0, sty = 0.0;
      var stime = 0.0;
      var su = 0.0, sv = 0.0;
      var hasUv = true;
      for (var j = lo; j <= hi; j++) {
        final p = points[j];
        sx += p.position.x;
        sy += p.position.y;
        sz += p.position.z;
        sp += p.pressure;
        stx += p.tilt.x;
        sty += p.tilt.y;
        stime += p.time;
        if (p.uv == null) {
          hasUv = false;
        } else {
          su += p.uv!.x;
          sv += p.uv!.y;
        }
      }
      out[i] = StrokePoint(
        position: Vector3(sx / span, sy / span, sz / span),
        pressure: sp / span,
        tilt: Vector2(stx / span, sty / span),
        time: stime / span,
        uv: hasUv ? Vector2(su / span, sv / span) : null,
      );
    }
    return out;
  }
}
