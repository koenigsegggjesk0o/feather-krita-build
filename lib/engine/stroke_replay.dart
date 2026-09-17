// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// stroke_replay.dart — Shared stroke-replay pipeline.
//
// Replays recorded strokes onto a TexturePainter exactly the way the
// canvas paints them: per-point UV dabs with the canvas's spacing
// heuristic (step = (size / sourceTexWidth) * 0.4, i.e. default spacing
// 0.10 folded into a 0.4 factor).
//
// Consumers:
//   - GifExporter: progressive frame snapshots of the replay.
//   - FeatherProjectDocument.applyTo: restores canvas pixels when a
//     saved project is opened (the .feather format stores no bitmap).
//   - Future: turntable/stroke-replay video exports.
//
// Strokes without texture UVs (legacy documents, mirror copies) are
// skipped because their texture footprint is unknown. The dab source is
// injected so callers can choose the native engine or the pure-Dart
// synthetic dab (the engine only knows one global color — replay uses
// per-stroke colors to keep multi-color documents faithful).

import 'dart:math' as math;

import 'package:feather_krita/engine/texture_painter.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/models/stroke.dart';

/// Dab provider: returns the dab to stamp for [stroke] at [pressure],
/// rendered at [sizePx] pixels (already scaled to the target texture).
typedef ReplayDabProvider = BrushDab Function(
  Stroke stroke,
  double pressure,
  double sizePx,
);

/// One planned dab-stamp operation of a replay.
class ReplayStamp {
  const ReplayStamp(this.stroke, this.u, this.v, this.pressure);

  final Stroke stroke;

  /// Texture-space UV of the dab center.
  final double u;
  final double v;

  /// Interpolated stylus pressure in [0, 1].
  final double pressure;
}

/// Builds the flat stamp plan for [strokes] using the canvas's
/// inter-point spacing heuristic.
///
/// [brushSizePx] is the reference brush size in source-texture pixels;
/// [sourceTextureSize] is the texture size the strokes were painted
/// against. UV coordinates are resolution-independent, so the plan is
/// the same for any target texture — only the dab pixel size scales.
List<ReplayStamp> buildReplayPlan({
  required List<Stroke> strokes,
  required double brushSizePx,
  required int sourceTextureSize,
}) {
  final plan = <ReplayStamp>[];
  for (final stroke in strokes) {
    if (!stroke.isVisible || stroke.points.isEmpty) continue;
    ReplayStamp? previous;
    for (final p in stroke.points) {
      final uv = p.uv;
      if (uv == null) continue; // replay-unknown footprint
      if (previous != null) {
        // Interpolate dabs between samples using the canvas heuristic:
        // step = (size / texWidth) * (0.25 + spacing * 1.5), with the
        // default spacing 0.10 folded in (0.4 factor).
        final step = (brushSizePx / sourceTextureSize) * 0.4;
        if (step > 0) {
          final du = uv.x - previous.u;
          final dv = uv.y - previous.v;
          final dist = math.sqrt(du * du + dv * dv);
          final count = (dist / step).floor();
          for (var i = 1; i <= count; i++) {
            final t = i / (count + 1);
            plan.add(ReplayStamp(
              stroke,
              previous.u + du * t,
              previous.v + dv * t,
              previous.pressure * (1 - t) + p.pressure * t,
            ));
          }
        }
      }
      final stamp = ReplayStamp(stroke, uv.x, uv.y, p.pressure);
      plan.add(stamp);
      previous = stamp;
    }
  }
  return plan;
}

/// Replays [strokes] into [texture] and returns the number of modified
/// destination pixels.
///
/// Dab sizes default to [brushSizePx] scaled from [sourceTextureSize] to
/// the target texture; override per stroke with [sizePxForStroke] (e.g.
/// to honor each stroke's recorded thickness). The caller owns undo
/// bookkeeping: by default the replay pushes NO undo snapshots
/// ([pushUndo] forwards to [TexturePainter.paintDab]) — wrap the call in
/// [TexturePainter.beginStrokeUndo] / [endStrokeUndo] to restore
/// atomically with a single snapshot.
int replayStrokesIntoTexture({
  required List<Stroke> strokes,
  required TexturePainter texture,
  required ReplayDabProvider dabFor,
  required double brushSizePx,
  required double brushOpacity,
  int sourceTextureSize = 2048,
  double Function(Stroke stroke, double defaultSizePx)? sizePxForStroke,
  bool pushUndo = false,
}) {
  final plan = buildReplayPlan(
    strokes: strokes,
    brushSizePx: brushSizePx,
    sourceTextureSize: sourceTextureSize,
  );
  final scale = texture.width / sourceTextureSize;
  var modified = 0;
  for (final s in plan) {
    final defaultPx = brushSizePx * scale;
    final sizePx = sizePxForStroke?.call(s.stroke, defaultPx) ?? defaultPx;
    final isErase = s.stroke.brushType == BrushType.eraser;
    modified += texture.paintDab(
      dabFor(s.stroke, s.pressure, sizePx),
      s.u,
      s.v,
      opacity: brushOpacity,
      eraser: isErase,
      pushUndo: pushUndo,
    );
  }
  return modified;
}
