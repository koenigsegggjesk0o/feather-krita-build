// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// mp4_smoke.dart — Standalone MP4 pipeline smoke test (dart run).
//
// Generates a tiny stroke animation through Mp4Exporter, writes
// scripts/out/mp4_smoke.mp4, and prints encoder stats. External checks
// (ffprobe/ffmpeg decode) happen in the shell wrapper.

import 'dart:io';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/synthetic_dab.dart';
import 'package:feather_krita/io/mp4_exporter.dart';
import 'package:feather_krita/models/stroke.dart';

Stroke makeStroke(int id, double x0, double y0, double x1, double y1,
    {int color = 0xFFCC1A1A, BrushType type = BrushType.basic}) {
  final points = <StrokePoint>[];
  const steps = 24;
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    points.add(StrokePoint(
      position: Vector3(0, 0, 0),
      pressure: 0.35 + 0.6 * math.sin(t * math.pi).abs(),
      uv: Vector2(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t),
    ));
  }
  return Stroke(
    id: id,
    color: color,
    thickness: 60,
    brushType: type,
    points: points,
  );
}

void main(List<String> args) {
  final size = args.isNotEmpty ? int.parse(args[0]) : 512;
  final strokes = <Stroke>[
    makeStroke(1, 0.15, 0.2, 0.85, 0.35),
    makeStroke(2, 0.8, 0.5, 0.2, 0.7, color: 0xFF1A4DE6),
    makeStroke(3, 0.3, 0.75, 0.7, 0.85, color: 0xFFF2D91A),
    makeStroke(4, 0.55, 0.15, 0.5, 0.6,
        color: 0xFFE6E6E6, type: BrushType.eraser),
  ];

  final sw = Stopwatch()..start();
  final bytes = Mp4Exporter(
    width: size,
    height: size,
    frameCount: 12,
    fps: 20,
  ).export(
    strokes: strokes,
    dabFor: (stroke, pressure, sizePx) =>
        syntheticDab(sizePx * pressure, stroke.color),
    brushSizePx: 60,
    brushOpacity: 0.9,
    sourceTextureSize: 2048,
  );
  sw.stop();

  final dir = Directory('scripts/out');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final f = File('scripts/out/mp4_smoke_${size}.mp4');
  f.writeAsBytesSync(bytes);
  print('wrote ${f.path}: ${bytes.length} bytes in ${sw.elapsedMilliseconds}ms'
      ' (${size}x$size, 12 frames)');
}
