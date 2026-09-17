// ignore_for_file: avoid_print
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

final class BrushInputNative extends Struct {
  @Double() external double x;
  @Double() external double y;
  @Double() external double pressure;
  @Double() external double tiltX;
  @Double() external double tiltY;
  @Double() external double time;
  @Float() external double velocityX;
  @Float() external double velocityY;
  @Int32() external int flags;
  // ignore: unused_field
  @Int32() external int _padding;
}

final class BrushDabNative extends Struct {
  @Int32() external int width;
  @Int32() external int height;
  @Int32() external int stride;
  @Int32() external int reserved;
  external Pointer<Uint8> pixels;
}

void main() {
  final lib = DynamicLibrary.open('build/libkrita_bridge.so');
  final init = lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('krita_brush_init');
  final destroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('krita_brush_destroy');
  final setSize = lib.lookupFunction<Void Function(Pointer<Void>, Double), void Function(Pointer<Void>, double)>('krita_brush_set_size');
  final setColor = lib.lookupFunction<Void Function(Pointer<Void>, Uint32), void Function(Pointer<Void>, int)>('krita_brush_set_color');
  final setOpacity = lib.lookupFunction<Void Function(Pointer<Void>, Double), void Function(Pointer<Void>, double)>('krita_brush_set_opacity');
  final setSpacing = lib.lookupFunction<Void Function(Pointer<Void>, Double), void Function(Pointer<Void>, double)>('krita_brush_set_spacing');
  final generateDab = lib.lookupFunction<Bool Function(Pointer<Void>, Pointer<BrushInputNative>, Pointer<BrushDabNative>), bool Function(Pointer<Void>, Pointer<BrushInputNative>, Pointer<BrushDabNative>)>('krita_brush_generate_dab');
  final releaseDab = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<BrushDabNative>), void Function(Pointer<Void>, Pointer<BrushDabNative>)>('krita_brush_release_dab');
  final cleanup = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('krita_brush_cleanup');
  final lastError = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>('krita_brush_last_error');
  final version = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('krita_brush_version');

  final ctx = init();
  if (ctx == nullptr) { print('FAIL: init null'); exit(1); }
  print('bridge: ${version().toDartString()}');

  const W = 512, H = 512;
  final canvas = img.Image(W, H);
  img.fill(canvas, 0xFFFAFAFA);

  final inputPtr = calloc<BrushInputNative>();
  final dabPtr = calloc<BrushDabNative>();

  try {
    // Stroke 1: red sine wave
    paintStroke(ctx, canvas, inputPtr, dabPtr, setSize, setColor, setOpacity, setSpacing, generateDab, releaseDab, cleanup, lastError,
      color: 0xFFFF0000, size: 28, opacity: 0.9, spacing: 0.12,
      path: (t) => (40.0 + t * (W - 80), H / 2 + 80 * math.sin(t * math.pi * 4)),
      steps: 180);
    // Stroke 2: green diagonal
    paintStroke(ctx, canvas, inputPtr, dabPtr, setSize, setColor, setOpacity, setSpacing, generateDab, releaseDab, cleanup, lastError,
      color: 0xFF00CC44, size: 18, opacity: 0.85, spacing: 0.10,
      path: (t) => (60.0 + t * (W - 120), 80.0 + t * (H - 160)),
      steps: 150);
    // Stroke 3: blue circle
    final cx = W / 2, cy = H / 2, r = 140.0;
    paintStroke(ctx, canvas, inputPtr, dabPtr, setSize, setColor, setOpacity, setSpacing, generateDab, releaseDab, cleanup, lastError,
      color: 0xFF1E6FE8, size: 14, opacity: 0.95, spacing: 0.08,
      path: (t) { final a = t * math.pi * 2; return (cx + r * math.cos(a), cy + r * math.sin(a)); },
      steps: 220);
    // Stroke 4: orange pressure-varying
    paintStroke(ctx, canvas, inputPtr, dabPtr, setSize, setColor, setOpacity, setSpacing, generateDab, releaseDab, cleanup, lastError,
      color: 0xFFFF8800, size: 36, opacity: 0.7, spacing: 0.18,
      path: (t) => (80.0 + t * (W - 160), H - 80.0 - 60 * t),
      pressure: (t) => 0.3 + 0.7 * (1 - (2 * t - 1).abs()),
      steps: 60);
  } finally {
    calloc.free(inputPtr);
    if (dabPtr.ref.pixels != nullptr) releaseDab(ctx, dabPtr);
    calloc.free(dabPtr);
  }

  cleanup(ctx);
  destroy(ctx);

  final png = img.encodePng(canvas);
  File('build/stroke_test.png').writeAsBytesSync(png);
  print('saved build/stroke_test.png (${png.length} bytes)');
  print('STROKE TEST COMPLETE');
}

void paintStroke(
  Pointer<Void> ctx, img.Image canvas,
  Pointer<BrushInputNative> inputPtr, Pointer<BrushDabNative> dabPtr,
  void Function(Pointer<Void>, double) setSize,
  void Function(Pointer<Void>, int) setColor,
  void Function(Pointer<Void>, double) setOpacity,
  void Function(Pointer<Void>, double) setSpacing,
  bool Function(Pointer<Void>, Pointer<BrushInputNative>, Pointer<BrushDabNative>) generateDab,
  void Function(Pointer<Void>, Pointer<BrushDabNative>) releaseDab,
  void Function(Pointer<Void>) cleanup,
  Pointer<Utf8> Function(Pointer<Void>) lastError,
  { required int color, required double size, required double opacity, required double spacing,
    required (double, double) Function(double t) path, double Function(double t)? pressure, required int steps }
) {
  setSize(ctx, size);
  setColor(ctx, color);
  setOpacity(ctx, opacity);
  setSpacing(ctx, spacing);
  cleanup(ctx);
  int dabCount = 0;
  for (int i = 0; i < steps; i++) {
    final t = i / (steps - 1);
    final (px, py) = path(t);
    final press = pressure != null ? pressure(t) : 1.0;
    inputPtr.ref.x = px; inputPtr.ref.y = py;
    inputPtr.ref.pressure = press; inputPtr.ref.time = t * 2.0;
    inputPtr.ref.tiltX = 0; inputPtr.ref.tiltY = 0;
    inputPtr.ref.velocityX = 0; inputPtr.ref.velocityY = 0;
    inputPtr.ref.flags = 0;
    dabPtr.ref.width = 0; dabPtr.ref.height = 0; dabPtr.ref.stride = 0; dabPtr.ref.pixels = nullptr;
    if (!generateDab(ctx, inputPtr, dabPtr)) {
      print('  dab $i FAILED: ${lastError(ctx).toDartString()}');
      continue;
    }
    compositeDab(canvas, dabPtr.ref, px, py);
    releaseDab(ctx, dabPtr);
    dabPtr.ref.pixels = nullptr;
    dabCount++;
  }
  print('  painted $dabCount dabs (size=$size color=0x${color.toRadixString(16)})');
}

void compositeDab(img.Image canvas, BrushDabNative dab, double cx, double cy) {
  final w = dab.width, h = dab.height, stride = dab.stride == 0 ? w * 4 : dab.stride;
  final px = dab.pixels;
  if (w <= 0 || h <= 0 || px == nullptr) return;
  final offX = (cx - w / 2).round();
  final offY = (cy - h / 2).round();
  for (var y = 0; y < h; y++) {
    final dy = offY + y;
    if (dy < 0 || dy >= canvas.height) continue;
    for (var x = 0; x < w; x++) {
      final off = y * stride + x * 4;
      final a = px[off + 3];
      if (a == 0) continue;
      final dx = offX + x;
      if (dx < 0 || dx >= canvas.width) continue;
      final r = px[off], g = px[off + 1], b = px[off + 2];
      final af = a / 255.0;
      final dst = canvas.getPixel(dx, dy);
      final dr = (dst >> 16) & 0xFF, dg = (dst >> 8) & 0xFF, db = dst & 0xFF;
      final nr = (r * af + dr * (1 - af)).round();
      final ng = (g * af + dg * (1 - af)).round();
      final nb = (b * af + db * (1 - af)).round();
      canvas.setPixel(dx, dy, (0xFF << 24) | (nr << 16) | (ng << 8) | nb);
    }
  }
}
