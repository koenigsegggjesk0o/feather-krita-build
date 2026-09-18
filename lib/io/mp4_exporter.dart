// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// mp4_exporter.dart — Stroke-replay MP4 (H.264) export.
//
// Mirrors [GifExporter]'s progressive stroke replay onto a fresh texture,
// but encodes frames as an H.264 Baseline stream (pure Dart, see
// [H264IdrEncoder]) muxed into a real MP4 container ([Mp4Muxer]). No
// platform plugins are involved, so Windows and Android behave
// identically.
//
// MP4 has no alpha channel, so each frame is composited over
// [backgroundColor] (opaque black by default) using the texture's alpha.

import 'dart:typed_data';

import 'package:feather_krita/engine/stroke_replay.dart';
import 'package:feather_krita/engine/texture_painter.dart';
import 'package:feather_krita/io/h264_encoder.dart';
import 'package:feather_krita/io/mp4_muxer.dart';
import 'package:feather_krita/models/stroke.dart';

/// Animated stroke-replay MP4 exporter (H.264 baseline, IDR-only).
class Mp4Exporter {
  Mp4Exporter({
    this.width = 512,
    this.height = 512,
    this.frameCount = 24,
    this.fps = 20.0,
    this.quality = 50,
    this.backgroundColor = 0xFF000000,
  })  : assert(fps > 0 && fps <= 60),
        assert(quality >= 0 && quality <= 100),
        assert(backgroundColor >> 24 == 0xFF,
            'MP4 frames need an opaque background');

  /// Output video size in pixels (padded internally to MB multiples).
  final int width;
  final int height;

  /// Total number of animation frames (>= 1).
  final int frameCount;

  /// Playback frame rate.
  final double fps;

  /// Encoder quality 0..100. Maps to the H.264 quantization parameter
  /// QP = 42 - quality*30/100 (quality 50 → QP 27, 100 → QP 12).
  final int quality;

  /// Opaque ARGB background composited behind the (possibly translucent)
  /// texture.
  final int backgroundColor;

  /// Encodes [strokes] as an MP4 file.
  ///
  /// Parameters match [GifExporter.export]; [dabFor] supplies the dab,
  /// [brushSizePx]/[brushOpacity] the live brush state, and
  /// [sourceTextureSize] the texture the strokes were painted against.
  /// [onProgress] reports completion in [0, 1].
  Uint8List export({
    required List<Stroke> strokes,
    required ReplayDabProvider dabFor,
    required double brushSizePx,
    required double brushOpacity,
    int sourceTextureSize = 2048,
    void Function(double progress)? onProgress,
  }) {
    final frames = frameCount < 1 ? 1 : frameCount;
    final texture = TexturePainter(
      width: width,
      height: height,
      wrapMode: WrapMode.wrap,
      maxUndoSteps: 0,
    );
    if (backgroundColor != 0x00000000) {
      texture.fill(
        (backgroundColor >> 16) & 0xff,
        (backgroundColor >> 8) & 0xff,
        backgroundColor & 0xff,
        0xff,
      );
    }

    final plan = buildReplayPlan(
      strokes: strokes,
      brushSizePx: brushSizePx,
      sourceTextureSize: sourceTextureSize,
    );

    final encoder = H264IdrEncoder(
      width: width,
      height: height,
      fps: fps,
      qp: (42 - quality * 30 ~/ 100).clamp(12, 42),
    );

    final nals = <Uint8List>[];
    var cursor = 0;
    for (var f = 0; f < frames; f++) {
      final target = ((f + 1) * plan.length / frames).round();
      for (; cursor < target; cursor++) {
        final s = plan[cursor];
        final isErase = s.stroke.brushType == BrushType.eraser;
        final dab = dabFor(s.stroke, s.pressure, brushSizePx);
        texture.paintDab(
          dab,
          s.u,
          s.v,
          opacity: brushOpacity,
          eraser: isErase,
        );
      }
      encoder.loadRgba(_compositeFrame(texture));
      nals.add(encoder.encodeIdr());
      onProgress?.call((f + 1) / frames);
    }

    return Mp4Muxer(
      width: width,
      height: height,
      fps: fps,
      sps: encoder.buildSps(),
      pps: encoder.buildPps(),
      samples: nals,
    ).mux();
  }

  /// Copies the texture's RGBA buffer composited over the opaque
  /// background. The buffer is exactly width*height*4 — the encoder does
  /// its own MB padding.
  Uint8List _compositeFrame(TexturePainter texture) {
    final px = texture.pixels;
    final out = Uint8List(width * height * 4);
    final bgR = (backgroundColor >> 16) & 0xff;
    final bgG = (backgroundColor >> 8) & 0xff;
    final bgB = backgroundColor & 0xff;
    for (var y = 0; y < height; y++) {
      final row = y * texture.stride;
      final outRow = y * width * 4;
      for (var x = 0; x < width; x++) {
        final i = row + x * 4;
        final a = px[i + 3];
        int mix(int fg, int bg) => (fg * a + bg * (255 - a)) ~/ 255;
        final o = outRow + x * 4;
        out[o] = mix(px[i], bgR);
        out[o + 1] = mix(px[i + 1], bgG);
        out[o + 2] = mix(px[i + 2], bgB);
        out[o + 3] = 0xFF;
      }
    }
    return out;
  }
}
