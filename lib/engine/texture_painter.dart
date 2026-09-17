// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// texture_painter.dart — Apply 2D brush dabs to an offscreen texture.
//
// Owns a 2048x2048 RGBA8 backing buffer and exposes [paintDab] which
// composite-stamps a [BrushDab] at a UV coordinate. Supports several
// blend modes, edge wrapping, and an eraser mode that subtracts alpha.
//
// The buffer is laid out as a row-major Uint8List of size
// width * height * 4 bytes (R, G, B, A — not premultiplied internally;
// premultiplication is applied only during composite math).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:feather_krita/ffi/krita_bindings.dart';

/// Composite blend modes supported by [TexturePainter].
enum BlendMode {
  /// Replace destination with source (respecting alpha).
  normal,

  /// Multiply source with destination (darkens).
  multiply,

  /// Screen blend (lightens).
  screen,

  /// Overlay — multiply if base dark, screen if base light.
  overlay,

  /// Soft-light — gentler overlay.
  softLight,

  /// Hard-light — like overlay but driven by source.
  hardLight,

  /// Color dodge.
  colorDodge,

  /// Color burn.
  colorBurn,

  /// Linear dodge (add).
  add,

  /// Linear burn (subtract).
  subtract,

  /// Per-channel minimum.
  darken,

  /// Per-channel maximum.
  lighten,

  /// Destination alpha reduced by source alpha.
  erase,

  /// Composite source into destination without blending colors — used
  /// by hard-edged stamps.
  replace,
}

/// Converts a [BlendMode] to its name for serialization.
String blendModeName(BlendMode mode) {
  switch (mode) {
    case BlendMode.normal:
      return 'normal';
    case BlendMode.multiply:
      return 'multiply';
    case BlendMode.screen:
      return 'screen';
    case BlendMode.overlay:
      return 'overlay';
    case BlendMode.softLight:
      return 'soft_light';
    case BlendMode.hardLight:
      return 'hard_light';
    case BlendMode.colorDodge:
      return 'color_dodge';
    case BlendMode.colorBurn:
      return 'color_burn';
    case BlendMode.add:
      return 'add';
    case BlendMode.subtract:
      return 'subtract';
    case BlendMode.darken:
      return 'darken';
    case BlendMode.lighten:
      return 'lighten';
    case BlendMode.erase:
      return 'erase';
    case BlendMode.replace:
      return 'replace';
  }
}

/// Lookup of [BlendMode] by name (inverse of [blendModeName]).
BlendMode blendModeFromName(String name) {
  switch (name) {
    case 'normal':
      return BlendMode.normal;
    case 'multiply':
      return BlendMode.multiply;
    case 'screen':
      return BlendMode.screen;
    case 'overlay':
      return BlendMode.overlay;
    case 'soft_light':
      return BlendMode.softLight;
    case 'hard_light':
      return BlendMode.hardLight;
    case 'color_dodge':
      return BlendMode.colorDodge;
    case 'color_burn':
      return BlendMode.colorBurn;
    case 'add':
      return BlendMode.add;
    case 'subtract':
      return BlendMode.subtract;
    case 'darken':
      return BlendMode.darken;
    case 'lighten':
      return BlendMode.lighten;
    case 'erase':
      return BlendMode.erase;
    case 'replace':
      return BlendMode.replace;
    default:
      return BlendMode.normal;
  }
}

/// Edge handling strategies when sampling outside [0, 1) UV space.
enum WrapMode {
  /// UVs outside [0, 1) are wrapped to the other side (tiling).
  wrap,

  /// UVs are clamped to the edge.
  clamp,

  /// Out-of-range samples are treated as transparent.
  transparent,
}

/// A 2D texture that brush dabs are stamped into.
class TexturePainter {
  TexturePainter({
    int width = 2048,
    int height = 2048,
    this.wrapMode = WrapMode.wrap,
    this.maxUndoSteps = 30,
  })  : _width = width,
        _height = height,
        _pixels = Uint8List(width * height * 4),
        _undoStack = <Uint8List>[],
        _redoStack = <Uint8List>[];

  final int _width;
  final int _height;
  final Uint8List _pixels;
  final WrapMode wrapMode;
  final int maxUndoSteps;

  final List<Uint8List> _undoStack;
  final List<Uint8List> _redoStack;

  /// Width of the texture in pixels.
  int get width => _width;

  /// Height of the texture in pixels.
  int get height => _height;

  /// Direct read access to the backing RGBA8 buffer (use with care).
  Uint8List get pixels => _pixels;

  /// Total number of bytes per row.
  int get stride => _width * 4;

  /// Returns true if the texture contains no opaque pixels.
  bool get isEmpty {
    for (var i = 3; i < _pixels.length; i += 4) {
      if (_pixels[i] != 0) return false;
    }
    return true;
  }

  /// Clears the texture to fully transparent black.
  void clear() {
    _pushUndo();
    _pixels.fillRange(0, _pixels.length, 0);
  }

  /// Fills the texture with a solid color.
  void fill(int r, int g, int b, [int a = 255]) {
    _pushUndo();
    for (var i = 0; i < _pixels.length; i += 4) {
      _pixels[i] = r;
      _pixels[i + 1] = g;
      _pixels[i + 2] = b;
      _pixels[i + 3] = a;
    }
  }

  /// Pushes the current buffer onto the undo stack.
  void _pushUndo() {
    _undoStack.add(Uint8List.fromList(_pixels));
    if (_undoStack.length > maxUndoSteps) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Reverts to the previous texture state if any.
  bool undo() {
    if (_undoStack.isEmpty) return false;
    _redoStack.add(Uint8List.fromList(_pixels));
    final prev = _undoStack.removeLast();
    _pixels.setAll(0, prev);
    return true;
  }

  /// Redoes a previously undone operation if any.
  bool redo() {
    if (_redoStack.isEmpty) return false;
    _undoStack.add(Uint8List.fromList(_pixels));
    final next = _redoStack.removeLast();
    _pixels.setAll(0, next);
    return true;
  }

  // ----- UV / pixel conversion -------------------------------------------

  /// Converts a UV coordinate in [0, 1) to a pixel coordinate.
  ///
  /// UV (0, 0) maps to the top-left pixel, (1, 1) maps to the bottom-right.
  math.Point<int> uvToPixel(double u, double v) {
    final px = (u * _width).floor() % _width;
    final py = (v * _height).floor() % _height;
    return math.Point<int>(
      px < 0 ? px + _width : px,
      py < 0 ? py + _height : py,
    );
  }

  /// Converts a pixel coordinate to UV.
  math.Point<double> pixelToUV(int x, int y) {
    return math.Point<double>(x / _width, y / _height);
  }

  /// Wraps an integer pixel coordinate according to [wrapMode].
  /// Returns -1 if the coordinate should be treated as transparent.
  int _wrapX(int x) {
    switch (wrapMode) {
      case WrapMode.wrap:
        var v = x % _width;
        if (v < 0) v += _width;
        return v;
      case WrapMode.clamp:
        return x.clamp(0, _width - 1);
      case WrapMode.transparent:
        if (x < 0 || x >= _width) return -1;
        return x;
    }
  }

  int _wrapY(int y) {
    switch (wrapMode) {
      case WrapMode.wrap:
        var v = y % _height;
        if (v < 0) v += _height;
        return v;
      case WrapMode.clamp:
        return y.clamp(0, _height - 1);
      case WrapMode.transparent:
        if (y < 0 || y >= _height) return -1;
        return y;
    }
  }

  // ----- Painting --------------------------------------------------------

  /// Stamps [dab] into the texture centered at UV ([u], [v]).
  ///
  /// The dab is rotated by [rotation] radians and scaled by [scale]. The
  /// [mode] controls how source pixels are combined with the destination.
  /// When [mode] is [BlendMode.erase] the dab alpha is subtracted from the
  /// destination, and the global [eraser] flag forces this behavior.
  ///
  /// Returns the number of destination pixels that were modified.
  int paintDab(
    BrushDab dab,
    double u,
    double v, {
    double rotation = 0.0,
    double scale = 1.0,
    BlendMode mode = BlendMode.normal,
    bool eraser = false,
    double opacity = 1.0,
  }) {
    if (dab.isEmpty) return 0;
    _pushUndo();

    final effectiveMode = eraser ? BlendMode.erase : mode;
    final dabW = dab.width;
    final dabH = dab.height;
    final dabPixels = dab.pixels;
    final dabStride = dab.stride == 0 ? dabW * 4 : dab.stride;

    // Convert UV center to absolute pixel center.
    final cx = u * _width;
    final cy = v * _height;

    // The dab is rotated around its own center and scaled. Compute the
    // bounding box of the rotated dab so we only iterate over destination
    // pixels that may be affected.
    final halfW = (dabW * scale) * 0.5;
    final halfH = (dabH * scale) * 0.5;
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);

    // Corners of the dab in destination space (before clipping).
    final corners = <math.Point<double>>[
      math.Point(-halfW, -halfH),
      math.Point(halfW, -halfH),
      math.Point(halfW, halfH),
      math.Point(-halfW, halfH),
    ];
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final c in corners) {
      final rx = c.x * cosR - c.y * sinR + cx;
      final ry = c.x * sinR + c.y * cosR + cy;
      if (rx < minX) minX = rx;
      if (rx > maxX) maxX = rx;
      if (ry < minY) minY = ry;
      if (ry > maxY) maxY = ry;
    }

    // Iterate destination pixels in the bounding box.
    var modified = 0;
    final x0 = (minX - 1).floor();
    final x1 = (maxX + 1).ceil();
    final y0 = (minY - 1).floor();
    final y1 = (maxY + 1).ceil();

    final invScale = scale == 0 ? 1.0 : 1.0 / scale;
    final invCos = scale == 0 || rotation == 0 ? 1.0 : math.cos(-rotation);
    final invSin = scale == 0 || rotation == 0 ? 0.0 : math.sin(-rotation);

    for (var dy = y0; dy <= y1; dy++) {
      for (var dx = x0; dx <= x1; dx++) {
        // Map destination pixel center to dab-local coords.
        final ox = (dx + 0.5) - cx;
        final oy = (dy + 0.5) - cy;
        final lx = (ox * invCos - oy * invSin) * invScale + dabW * 0.5;
        final ly = (ox * invSin + oy * invCos) * invScale + dabH * 0.5;

        if (lx < 0 || lx >= dabW || ly < 0 || ly >= dabH) continue;

        // Bilinear sample the dab.
        final sx = lx.floor();
        final sy = ly.floor();
        final fx = lx - sx;
        final fy = ly - sy;

        final s00 = (sy * dabStride + sx * 4);
        final s10 = (sy * dabStride + (sx + 1).clamp(0, dabW - 1) * 4);
        final s01 = ((sy + 1).clamp(0, dabH - 1) * dabStride + sx * 4);
        final s11 = ((sy + 1).clamp(0, dabH - 1) * dabStride +
            (sx + 1).clamp(0, dabW - 1) * 4);

        final sr = _bilinear(
            dabPixels[s00], dabPixels[s10], dabPixels[s01], dabPixels[s11], fx, fy);
        final sg = _bilinear(
            dabPixels[s00 + 1],
            dabPixels[s10 + 1],
            dabPixels[s01 + 1],
            dabPixels[s11 + 1],
            fx,
            fy);
        final sb = _bilinear(
            dabPixels[s00 + 2],
            dabPixels[s10 + 2],
            dabPixels[s01 + 2],
            dabPixels[s11 + 2],
            fx,
            fy);
        final sa = _bilinear(
            dabPixels[s00 + 3],
            dabPixels[s10 + 3],
            dabPixels[s01 + 3],
            dabPixels[s11 + 3],
            fx,
            fy);
        if (sa == 0) continue;

        final dstX = _wrapX(dx);
        final dstY = _wrapY(dy);
        if (dstX < 0 || dstY < 0) continue;
        final di = (dstY * _width + dstX) * 4;

        final srcA = (sa * opacity).round().clamp(0, 255);
        _composite(
          _pixels,
          di,
          sr,
          sg,
          sb,
          srcA,
          effectiveMode,
        );
        modified++;
      }
    }
    return modified;
  }

  /// Bilinear sample helper for a single channel value.
  int _bilinear(
      int v00, int v10, int v01, int v11, double fx, double fy) {
    final top = v00 + ((v10 - v00) * fx).round();
    final bot = v01 + ((v11 - v01) * fx).round();
    return (top + ((bot - top) * fy).round()).clamp(0, 255);
  }

  /// Composites a single source RGBA into the destination at byte offset
  /// [di] using [mode]. Performs in-place premultiplied math.
  void _composite(
    Uint8List dst,
    int di,
    int sr,
    int sg,
    int sb,
    int sa,
    BlendMode mode,
  ) {
    final dr = dst[di];
    final dg = dst[di + 1];
    final db = dst[di + 2];
    final da = dst[di + 3];

    // Source alpha as fraction.
    final sAf = sa / 255.0;
    final dAf = da / 255.0;

    switch (mode) {
      case BlendMode.replace:
        dst[di] = sr;
        dst[di + 1] = sg;
        dst[di + 2] = sb;
        dst[di + 3] = sa;
        return;

      case BlendMode.erase:
        final newA = (da - sa).clamp(0, 255);
        if (newA == 0) {
          dst[di] = 0;
          dst[di + 1] = 0;
          dst[di + 2] = 0;
          dst[di + 3] = 0;
        } else {
          // Preserve color, reduce alpha.
          dst[di + 3] = newA;
        }
        return;

      case BlendMode.normal:
        // Porter-Duff source-over with premultiplied math.
        final outA = sAf + dAf * (1 - sAf);
        if (outA == 0) {
          dst[di] = 0;
          dst[di + 1] = 0;
          dst[di + 2] = 0;
          dst[di + 3] = 0;
          return;
        }
        final outR = ((sr * sAf + dr * dAf * (1 - sAf)) / outA).round().clamp(0, 255);
        final outG = ((sg * sAf + dg * dAf * (1 - sAf)) / outA).round().clamp(0, 255);
        final outB = ((sb * sAf + db * dAf * (1 - sAf)) / outA).round().clamp(0, 255);
        dst[di] = outR;
        dst[di + 1] = outG;
        dst[di + 2] = outB;
        dst[di + 3] = (outA * 255).round().clamp(0, 255);
        return;

      case BlendMode.multiply:
        final outA = sAf + dAf * (1 - sAf);
        if (outA == 0) return;
        final blendR = sr * dr / 255;
        final blendG = sg * dg / 255;
        final blendB = sb * db / 255;
        dst[di] = ((blendR * sAf + dr * dAf * (1 - sAf)) / outA)
            .round()
            .clamp(0, 255);
        dst[di + 1] = ((blendG * sAf + dg * dAf * (1 - sAf)) / outA)
            .round()
            .clamp(0, 255);
        dst[di + 2] = ((blendB * sAf + db * dAf * (1 - sAf)) / outA)
            .round()
            .clamp(0, 255);
        dst[di + 3] = (outA * 255).round().clamp(0, 255);
        return;

      case BlendMode.screen:
        final outA = sAf + dAf * (1 - sAf);
        if (outA == 0) return;
        final blendR = 255 - (255 - sr) * (255 - dr) / 255;
        final blendG = 255 - (255 - sg) * (255 - dg) / 255;
        final blendB = 255 - (255 - sb) * (255 - db) / 255;
        dst[di] = ((blendR * sAf + dr * dAf * (1 - sAf)) / outA)
            .round()
            .clamp(0, 255);
        dst[di + 1] = ((blendG * sAf + dg * dAf * (1 - sAf)) / outA)
            .round()
            .clamp(0, 255);
        dst[di + 2] = ((blendB * sAf + db * dAf * (1 - sAf)) / outA)
            .round()
            .clamp(0, 255);
        dst[di + 3] = (outA * 255).round().clamp(0, 255);
        return;

      case BlendMode.overlay:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _overlay);
        return;
      case BlendMode.softLight:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _softLight);
        return;
      case BlendMode.hardLight:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _hardLight);
        return;
      case BlendMode.colorDodge:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _colorDodge);
        return;
      case BlendMode.colorBurn:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _colorBurn);
        return;
      case BlendMode.add:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _add);
        return;
      case BlendMode.subtract:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _subtract);
        return;
      case BlendMode.darken:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _darken);
        return;
      case BlendMode.lighten:
        _applyBlendLayer(sr, dr, sg, dg, sb, db, sa, da, dst, di, _lighten);
        return;
    }
  }

  /// Generic helper to apply a per-channel blend function with Porter-Duff
  /// source-over compositing on top.
  void _applyBlendLayer(
    int sr,
    int dr,
    int sg,
    int dg,
    int sb,
    int db,
    int sa,
    int da,
    Uint8List dst,
    int di,
    int Function(int src, int dst) fn,
  ) {
    final sAf = sa / 255.0;
    final dAf = da / 255.0;
    final outA = sAf + dAf * (1 - sAf);
    if (outA == 0) {
      dst[di] = 0;
      dst[di + 1] = 0;
      dst[di + 2] = 0;
      dst[di + 3] = 0;
      return;
    }
    final blendR = fn(sr, dr);
    final blendG = fn(sg, dg);
    final blendB = fn(sb, db);
    dst[di] = ((blendR * sAf + dr * dAf * (1 - sAf)) / outA)
        .round()
        .clamp(0, 255);
    dst[di + 1] = ((blendG * sAf + dg * dAf * (1 - sAf)) / outA)
        .round()
        .clamp(0, 255);
    dst[di + 2] = ((blendB * sAf + db * dAf * (1 - sAf)) / outA)
        .round()
        .clamp(0, 255);
    dst[di + 3] = (outA * 255).round().clamp(0, 255);
  }

  // ----- Per-channel blend functions -------------------------------------

  static int _overlay(int s, int d) {
    if (d < 128) return (2 * s * d / 255).round().clamp(0, 255);
    return (255 - 2 * (255 - s) * (255 - d) / 255).round().clamp(0, 255);
  }

  static int _softLight(int s, int d) {
    final sf = s / 255.0;
    final df = d / 255.0;
    double res;
    if (sf <= 0.5) {
      res = df - (1 - 2 * sf) * df * (1 - df);
    } else {
      final g = df <= 0.25
          ? ((16 * df - 12) * df + 4) * df
          : math.sqrt(df);
      res = df + (2 * sf - 1) * (g - df);
    }
    return (res * 255).round().clamp(0, 255);
  }

  static int _hardLight(int s, int d) {
    if (s < 128) return (2 * s * d / 255).round().clamp(0, 255);
    return (255 - 2 * (255 - s) * (255 - d) / 255).round().clamp(0, 255);
  }

  static int _colorDodge(int s, int d) {
    if (s == 255) return 255;
    final v = (d * 255 / (255 - s)).round();
    return v.clamp(0, 255);
  }

  static int _colorBurn(int s, int d) {
    if (s == 0) return 0;
    final v = (255 - (255 - d) * 255 / s).round();
    return v.clamp(0, 255);
  }

  static int _add(int s, int d) => (s + d).clamp(0, 255);

  static int _subtract(int s, int d) => (d - s).clamp(0, 255);

  static int _darken(int s, int d) => math.min(s, d);

  static int _lighten(int s, int d) => math.max(s, d);

  // ----- Sampling --------------------------------------------------------

  /// Samples the texture at the given UV with bilinear filtering.
  ///
  /// Returns a 4-element list [r, g, b, a] in [0, 255].
  List<int> sample(double u, double v) {
    final fx = u * _width - 0.5;
    final fy = v * _height - 0.5;
    final x0 = fx.floor();
    final y0 = fy.floor();
    final tx = fx - x0;
    final ty = fy - y0;

    final x0i = _wrapX(x0);
    final x1i = _wrapX(x0 + 1);
    final y0i = _wrapY(y0);
    final y1i = _wrapY(y0 + 1);

    int sampleAt(int x, int y, int channel) {
      if (x < 0 || y < 0) return 0;
      return _pixels[(y * _width + x) * 4 + channel];
    }

    final r = _lerp(
        _lerp(sampleAt(x0i, y0i, 0), sampleAt(x1i, y0i, 0), tx),
        _lerp(sampleAt(x0i, y1i, 0), sampleAt(x1i, y1i, 0), tx),
        ty);
    final g = _lerp(
        _lerp(sampleAt(x0i, y0i, 1), sampleAt(x1i, y0i, 1), tx),
        _lerp(sampleAt(x0i, y1i, 1), sampleAt(x1i, y1i, 1), tx),
        ty);
    final b = _lerp(
        _lerp(sampleAt(x0i, y0i, 2), sampleAt(x1i, y0i, 2), tx),
        _lerp(sampleAt(x0i, y1i, 2), sampleAt(x1i, y1i, 2), tx),
        ty);
    final a = _lerp(
        _lerp(sampleAt(x0i, y0i, 3), sampleAt(x1i, y0i, 3), tx),
        _lerp(sampleAt(x0i, y1i, 3), sampleAt(x1i, y1i, 3), tx),
        ty);
    return [r.round(), g.round(), b.round(), a.round()];
  }

  static int _lerp(int a, int b, double t) => (a + (b - a) * t).round();

  // ----- Serialization ---------------------------------------------------

  /// Returns a snapshot of the current pixel buffer (defensive copy).
  Uint8List snapshot() => Uint8List.fromList(_pixels);

  /// Restores the texture from a snapshot. The buffer length must match.
  void restore(Uint8List snapshot) {
    if (snapshot.length != _pixels.length) {
      throw ArgumentError(
          'Snapshot length ${snapshot.length} does not match texture size ${_pixels.length}');
    }
    _pixels.setAll(0, snapshot);
  }

  /// Resets the undo / redo history (does not modify current pixels).
  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
  }
}
