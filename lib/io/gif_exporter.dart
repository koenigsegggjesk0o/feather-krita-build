// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// gif_exporter.dart — Stroke-replay GIF export.
//
// Replays the document's strokes onto a fresh texture exactly the way the
// canvas paints them (per-point UV dabs with the canvas's spacing
// heuristic), snapshotting a frame after each time slice and encoding the
// frames as an animated GIF. Strokes without texture UVs (legacy
// documents, mirror copies) are skipped because their texture footprint
// is unknown.
//
// The dab source is injected: callers plug in the native engine when the
// stroke color matches the live brush, and the pure-Dart synthetic dab
// otherwise (the native engine only knows the globally configured color).

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:feather_krita/engine/stroke_replay.dart';
import 'package:feather_krita/engine/texture_painter.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/models/stroke.dart';

/// Dab provider: returns the dab to stamp for [stroke] at [pressure],
/// rendered at [sizePx] pixels (already scaled to the GIF texture).
typedef ReplayDabProvider = BrushDab Function(
  Stroke stroke,
  double pressure,
  double sizePx,
);

/// Animated stroke-replay GIF exporter.
class GifExporter {
  GifExporter({
    this.width = 512,
    this.height = 512,
    this.frameCount = 24,
    this.frameDelayCs = 5,
    this.backgroundColor = 0x00000000,
  });

  /// Output GIF width/height in pixels. The replay texture is created at
  /// this size and brush sizes are scaled accordingly.
  final int width;
  final int height;

  /// Total number of animation frames (>= 1).
  final int frameCount;

  /// Per-frame delay in centiseconds (GIF time unit; 5 = 20 fps).
  final int frameDelayCs;

  /// ARGB background painted into frame 0. Use 0x00000000 for transparent.
  final int backgroundColor;

  /// Encodes [strokes] as an animated GIF.
  ///
  /// [dabFor] supplies the dab for a stroke at a given pressure.
  /// [brushSizePx] is the live brush size in texture pixels (the exporter
  /// scales it to the GIF texture). [brushOpacity] is the live opacity.
  /// [sourceTextureSize] is the size the strokes were painted against
  /// (default 2048) so spacing and dab size translate 1:1.
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
        (backgroundColor >> 24) & 0xff,
      );
    }

    // Build the paint plan: a flat list of stamp operations (uv, pressure,
    // stroke) with the same inter-point spacing the canvas uses.
    final plan = buildReplayPlan(
      strokes: strokes,
      brushSizePx: brushSizePx,
      sourceTextureSize: sourceTextureSize,
    );

    final encoder = img.GifEncoder(
      delay: frameDelayCs,
      repeat: 0, // loop forever
      // Quantize against EVERY pixel: the default samplingFactor of 10
      // drops sparse colors entirely (e.g. a small stroke in frame 1 of a
      // mostly-transparent animation quantizes to pure black).
      samplingFactor: 1,
      // Error-diffusion dithering adds speckle noise to the flat dab
      // fills; nearest-color mapping keeps replay crisp.
      dither: img.DitherKernel.None,
    );

    // The live brush size is expressed against the source texture
    // (default 2048); dabs for the GIF texture must shrink accordingly.
    final gifBrushPx = brushSizePx * width / sourceTextureSize;

    if (plan.isEmpty) {
      // Still emit a single-frame GIF so the file is a valid animation.
      encoder.addFrame(_snapshot(texture), duration: frameDelayCs);
      onProgress?.call(1.0);
      final bytes = encoder.finish();
      return Uint8List.fromList(bytes ?? const <int>[]);
    }

    var cursor = 0;
    for (var f = 0; f < frames; f++) {
      final target = ((f + 1) * plan.length / frames).round();
      for (; cursor < target; cursor++) {
        final s = plan[cursor];
        final isErase = s.stroke.brushType == BrushType.eraser;
        final dab = dabFor(s.stroke, s.pressure, gifBrushPx);
        texture.paintDab(
          dab,
          s.u,
          s.v,
          opacity: brushOpacity,
          eraser: isErase,
        );
      }
      onProgress?.call((f + 1) / frames);
      encoder.addFrame(_snapshot(texture), duration: frameDelayCs);
    }

    final bytes = encoder.finish();
    return Uint8List.fromList(bytes ?? const <int>[]);
  }

  /// Copies the texture's RGBA buffer into an image-package Image.
  img.Image _snapshot(TexturePainter texture) {
    final px = texture.pixels;
    final image = img.Image(texture.width, texture.height);
    for (var y = 0; y < texture.height; y++) {
      for (var x = 0; x < texture.width; x++) {
        final i = y * texture.stride + x * 4;
        // image 3.x packs pixels as #AABBGGRR — R in the LOW byte.
        image.setPixel(
          x,
          y,
          (px[i + 3] << 24) | (px[i + 2] << 16) | (px[i + 1] << 8) | px[i],
        );
      }
    }
    return image;
  }
}
