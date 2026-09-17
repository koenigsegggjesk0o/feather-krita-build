// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// synthetic_dab.dart — Pure-Dart fallback dab generator.
//
// Used when the native Krita bridge is unavailable (or when a texture
// replay needs a dab whose color differs from the engine's global brush
// color, e.g. GIF stroke-replay export). Produces the same soft
// radial-gradient dab the canvas has always used as its fallback.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:feather_krita/ffi/krita_bindings.dart';

/// Builds a soft radial-gradient dab in pure Dart. The result is a square
/// RGBA8 image of side `ceil(radius) * 2` with a smooth smoothstep falloff.
BrushDab syntheticDab(double radius, int argb) {
  final r = radius.ceil().clamp(1, 256).toInt();
  final size = r * 2;
  final px = Uint8List(size * size * 4);
  final cr = (argb >> 16) & 0xff;
  final cg = (argb >> 8) & 0xff;
  final cb = argb & 0xff;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x - r + 0.5;
      final dy = y - r + 0.5;
      final d = math.sqrt(dx * dx + dy * dy) / r;
      final a = (1.0 - d.clamp(0.0, 1.0));
      final soft = a * a * (3 - 2 * a); // smoothstep
      final i = (y * size + x) * 4;
      px[i] = cr;
      px[i + 1] = cg;
      px[i + 2] = cb;
      px[i + 3] = (soft * 255).round().clamp(0, 255);
    }
  }
  return BrushDab(
    width: size,
    height: size,
    stride: size * 4,
    pixels: px,
  );
}
