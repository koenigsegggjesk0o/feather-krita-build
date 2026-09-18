// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later //
// mp4_size_bench.dart — Loop-18 benchmark: v0.12 (flat+PCM) vs v0.13
// (CAVLC residuals) MP4 export size and encode time on realistic painting
// content.
//
// Generates a multi-stroke painting scene (soft synthetic dabs = gradient
// edges, one eraser, varied pressure) and exports it through Mp4Exporter
// at three quality levels with enableResiduals on/off. Writes both files
// to scripts/out/ so the shell can ffmpeg-decode them, then prints a size
// table. Run: dart run scripts/mp4_size_bench.dart [size] [frames]

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/synthetic_dab.dart';
import 'package:feather_krita/io/mp4_exporter.dart';
import 'package:feather_krita/models/stroke.dart';

Stroke _stroke(int id, double x0, double y0, double x1, double y1,
    {int color = 0xFFCC1A1A, BrushType type = BrushType.basic, double thick = 60}) {
  final rng = math.Random(id * 7919);
  final points = <StrokePoint>[];
  const steps = 30;
  var cx = x0;
  var cy = y0;
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    // Slight per-point wobble so strokes are not perfect lines.
    final wx = (rng.nextDouble() - 0.5) * 0.02;
    final wy = (rng.nextDouble() - 0.5) * 0.02;
    cx = x0 + (x1 - x0) * t + wx;
    cy = y0 + (y1 - y0) * t + wy;
    points.add(StrokePoint(
      position: Vector3(0, 0, 0),
      pressure: (0.35 + 0.6 * math.sin(t * math.pi).abs() +
              0.05 * rng.nextDouble())
          .clamp(0.05, 1.0),
      uv: Vector2(cx, cy),
    ));
  }
  return Stroke(
    id: id,
    color: color,
    thickness: thick,
    brushType: type,
    points: points,
  );
}

List<Stroke> _paintingScene() {
  const palette = [
    0xFFCC1A1A, 0xFF1A4DE6, 0xFFF2D91A, 0xFF1AA64A,
    0xFF9C27B0, 0xFFFF8C00, 0xFFE6E6E6, 0xFF20B2AA,
  ];
  final strokes = <Stroke>[];
  for (var i = 0; i < 14; i++) {
    strokes.add(_stroke(
      i + 1,
      0.10 + 0.02 * (i % 5),
      0.12 + 0.055 * (i % 4),
      0.88 - 0.015 * i,
      0.86 - 0.045 * (i % 6),
      color: palette[i % palette.length],
      thick: 40.0 + 6.0 * i,
    ));
  }
  // A couple of eraser passes through the middle.
  strokes.add(_stroke(90, 0.15, 0.5, 0.85, 0.52,
      type: BrushType.eraser, thick: 90));
  strokes.add(_stroke(91, 0.5, 0.2, 0.48, 0.8,
      type: BrushType.eraser, thick: 70));
  return strokes;
}

void main(List<String> args) {
  final size = args.isNotEmpty ? int.parse(args[0]) : 512;
  final frames = args.length > 1 ? int.parse(args[1]) : 24;
  final strokes = _paintingScene();
  final dabCount = strokes.fold<int>(0, (m, s) => m + s.points.length);
  print('scene: ${strokes.length} strokes, $dabCount dabs, '
      '${size}x$size, $frames frames');

  final rows = <String>[];
  for (final quality in [30, 50, 70]) {
    Uint8List withR; Uint8List withoutR;
    var sw = Stopwatch()..start();
    withR = _export(strokes, size, frames, quality, true);
    sw.stop();
    final tResid = sw.elapsedMilliseconds;
    sw = Stopwatch()..start();
    withoutR = _export(strokes, size, frames, quality, false);
    sw.stop();
    final tPcm = sw.elapsedMilliseconds;

    final gain = (1 - withR.length / withoutR.length) * 100;
    rows.add('quality $quality: residual ${_kb(withR)} (${tResid}ms) | '
        'flat+PCM ${_kb(withoutR)} (${tPcm}ms) | '
        'residual saves ${gain.toStringAsFixed(1)}%');
    _write('bench_q${quality}_residuals.mp4', withR);
    _write('bench_q${quality}_flatpcm.mp4', withoutR);
  }
  print(rows.join('\n'));
  print('files written to scripts/out/ (decode with ffmpeg to validate)');
}

Uint8List _export(List<Stroke> strokes, int size, int frames, int quality,
        bool residuals) {
  return Mp4Exporter(
    width: size,
    height: size,
    frameCount: frames,
    fps: 20,
    quality: quality,
    enableResiduals: residuals,
  ).export(
    strokes: strokes,
    dabFor: (stroke, pressure, sizePx) =>
        syntheticDab(sizePx * pressure, stroke.color),
    brushSizePx: 60,
    brushOpacity: 0.9,
    sourceTextureSize: 2048,
  );
}

String _kb(Uint8List b) =>
    b.length >= 1024
        ? '${(b.length / 1024).toStringAsFixed(1)} KiB'
        : '${b.length} B';

void _write(String name, Uint8List bytes) {
  final dir = Directory('scripts/out');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('scripts/out/$name').writeAsBytesSync(bytes);
}
