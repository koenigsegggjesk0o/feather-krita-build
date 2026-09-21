// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// texture_image.dart — async raster cache of the guide texture with the
// surface shading contract baked in (loop-51).
//
// The 3D painter maps the guide texture PER FRAGMENT via drawVertices +
// ImageShader. That needs a dart:ui.Image, which can only be built
// asynchronously from raw pixels (decodeImageFromPixels). This cache:
//   1. bakes the painter's tint × texture × fill-alpha contract into the
//      pixel buffer (bakeSurfaceContractImage — pure, unit-tested),
//   2. decodes it into a ui.Image exactly once per texture version /
//      surface tint change,
//   3. hands the ready image to the painter; until the decode lands the
//      painter falls back to per-triangle flat sampling (legacy look).
//
// Two generations are kept alive so a shader created from the previous
// image is never disposed mid-frame. Live strokes bump the texture
// version per dab; re-rasters are throttled to [kTexImageMinIntervalMs]
// so the committed surface converges within ~150 ms of the last dab
// without one 2048² bake per pointer-move event.

import 'dart:ui' as ui;

import 'package:feather_krita/engine/texture_painter.dart';

/// Minimum interval between texture re-raster attempts while the texture
/// version keeps moving (live drawing). Committed state always converges:
/// the next paint after the throttle window re-rasters the final version.
const int kTexImageMinIntervalMs = 150;

class TextureImageCache {
  TextureImageCache._();

  /// Test hook: widget tests pump the canvas against tiny viewports and
  /// do not exercise the async decode; setting this false keeps the
  /// painter on the synchronous flat-fallback path.
  static bool enabled = true;

  static int _readyKey = -1;
  static int _inFlightKey = -1;
  static DateTime _lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  static ui.Image? _current;
  static ui.Image? _retired;

  /// The latest decoded contract image, or null until the first decode
  /// for the current texture version / tint lands.
  static ui.Image? get current => _current;

  static int _tintKey(double r, double g, double b) =>
      ((r * 255).round() << 16) | ((g * 255).round() << 8) | (b * 255).round();

  /// Requests a re-raster if the texture version or tint changed since
  /// the ready image. Cheap no-op when up to date, while this key is
  /// already decoding, or inside the throttle window.
  static void refresh(
    TexturePainter texture, {
    required double tintR,
    required double tintG,
    required double tintB,
  }) {
    if (!enabled) return;
    final key = Object.hash(
        texture.version, _tintKey(tintR, tintG, tintB), identityHashCode(texture));
    if (key == _readyKey || key == _inFlightKey) return;
    final now = DateTime.now();
    if (now.difference(_lastAttempt).inMilliseconds < kTexImageMinIntervalMs) {
      return;
    }
    _lastAttempt = now;
    _inFlightKey = key;
    final baked = bakeSurfaceContractImage(
      pixels: texture.pixels,
      width: texture.width,
      height: texture.height,
      tintR: tintR,
      tintG: tintG,
      tintB: tintB,
    );
    ui.decodeImageFromPixels(
      baked,
      texture.width,
      texture.height,
      ui.PixelFormat.rgba8888,
      (image) {
        _retired?.dispose();
        _retired = _current;
        _current = image;
        _readyKey = key;
      },
    );
  }
}
