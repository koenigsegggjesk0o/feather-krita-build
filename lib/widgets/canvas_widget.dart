// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// canvas_widget.dart — 3D canvas viewport (Feather 3D style).
//
// A software-rendered 3D viewport built on [CustomPainter]. It:
//   - Renders the active [GuideSurface] as a backface-culled, depth-sorted
//     triangle mesh textured by sampling [TexturePainter] at each
//     triangle's UV centroid (a real software texture mapper).
//   - Renders all 3D strokes as projected polylines with per-point
//     thickness, plus the in-progress "live" stroke.
//   - Draws a ground grid and translucent mirror planes.
//   - Advances the [CameraController]'s damping animation every frame via
//     a [Ticker].
//   - Translates touch / mouse / stylus input into:
//       * Drawing — pan on the guide surface → raycast → UV → brush dab
//         stamped into the texture + a 3D stroke point recorded.
//       * Camera orbit / zoom (one-finger drag in non-draw tools, two-finger
//         pinch + rotate, mouse wheel).
//       * Liquify — pan applies a liquify deformation at the hit point.
//
// The renderer is intentionally pluggable: swapping [CustomPainter] for a
// flutter_gl hardware renderer only requires replacing [_ScenePainter];
// the input handling and engine wiring above it stay the same.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/engine/stroke_manager.dart';
import 'package:feather_krita/models/stroke.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';

/// The 3D canvas viewport.
class CanvasWidget extends StatefulWidget {
  const CanvasWidget({super.key, required this.state});

  final EditorState state;

  @override
  State<CanvasWidget> createState() => _CanvasWidgetState();
}

class _CanvasWidgetState extends State<CanvasWidget>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  bool _drawing = false;

  // Live stroke state.
  final List<StrokePoint> _livePoints = <StrokePoint>[];
  Vector2? _lastUV;
  // ignore: unused_field
  Vector3? _lastWorld;
  double _strokeStartTime = 0;

  // Pointer pressure (stylus) tracked via Listener.
  double _pressure = 0.85;

  // Cached renderer inputs.
  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _ticker = Ticker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed.inMicroseconds / 1000000.0;
    final changed = widget.state.camera.tick(dt);
    if (changed || _drawing) {
      setState(() {});
    }
  }

  bool get _isDrawTool =>
      widget.state.activeTool == Tool.draw ||
      widget.state.activeTool == Tool.erase ||
      widget.state.activeTool == Tool.shapes;

  bool get _isLiquifyTool => widget.state.activeTool == Tool.liquify;

  // ----- Input handling --------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    _pressure = 0.85;
    if (_isDrawTool && details.pointerCount == 1) {
      _beginStroke(details.localFocalPoint);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount == 1) {
      if (_isDrawTool && _drawing) {
        _continueStroke(details.localFocalPoint);
      } else if (_isLiquifyTool) {
        _applyLiquify(details.localFocalPoint);
      } else {
        // Orbit.
        widget.state.camera.handleOneFingerDrag(
          details.focalPointDelta.dx,
          details.focalPointDelta.dy,
        );
      }
    } else {
      // Two-finger: orbit + zoom.
      widget.state.camera.handleTwoFingerGesture(
        rotationDelta: details.rotation,
        scaleFactor: details.scale == 0 ? 1.0 : details.scale,
      );
      widget.state.camera.handleTwoFingerPan(
        details.focalPointDelta.dx,
        details.focalPointDelta.dy,
        _viewport.width,
        _viewport.height,
      );
    }
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (_drawing) {
      _endStroke();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      widget.state.camera
          .handleMouseWheel(event.scrollDelta.dy.toInt().toDouble());
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    if (e.pressure > 0 && e.pressure < 1.0) {
      _pressure = e.pressure.clamp(0.05, 1.0);
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pressure > 0 && e.pressure < 1.0) {
      _pressure = e.pressure.clamp(0.05, 1.0);
    }
  }

  // ----- Stroke drawing --------------------------------------------------

  void _beginStroke(Offset screen) {
    final hit = _raycast(screen);
    if (hit == null) {
      _drawing = false;
      return;
    }
    _drawing = true;
    _livePoints.clear();
    _strokeStartTime = DateTime.now().millisecondsSinceEpoch / 1000.0;
    _lastUV = hit.uv.clone();
    _lastWorld = hit.point.clone();
    _livePoints.add(StrokePoint(
      position: hit.point.clone(),
      pressure: _pressure,
      time: 0,
    ));
    _stampDab(hit.uv);
    HapticFeedback.selectionClick();
  }

  void _continueStroke(Offset screen) {
    final hit = _raycast(screen);
    if (hit == null) return;
    final last = _lastUV;
    if (last != null) {
      final du = hit.uv.x - last.x;
      final dv = hit.uv.y - last.y;
      final dist = math.sqrt(du * du + dv * dv);
      final tex = widget.state.texture;
      final step = (widget.state.brushSize / tex.width) *
          (0.25 + widget.state.brushSpacing * 1.5);
      final count = step <= 0 ? 0 : (dist / step).floor();
      for (var i = 1; i <= count; i++) {
        final t = i / (count + 1);
        final u = last.x + du * t;
        final v = last.y + dv * t;
        _stampDab(Vector2(u, v));
      }
    }
    _lastUV = hit.uv.clone();
    _lastWorld = hit.point.clone();
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    _livePoints.add(StrokePoint(
      position: hit.point.clone(),
      pressure: _pressure,
      time: now - _strokeStartTime,
    ));
    _stampDab(hit.uv);
    setState(() {});
  }

  void _endStroke() {
    _drawing = false;
    if (_livePoints.isNotEmpty) {
      final isErase = widget.state.activeTool == Tool.erase;
      final stroke = Stroke(
        brushType: isErase ? BrushType.eraser : _brushTypeForTool(),
        color: widget.state.brushColor,
        thickness: widget.state.brushSize,
        points: _livePoints.map((p) => p.copy()).toList(),
        name: isErase ? 'Eraser' : widget.state.brushPresetName,
      );
      widget.state.strokes.addStroke(stroke);
    }
    _livePoints.clear();
    _lastUV = null;
    _lastWorld = null;
    setState(() {});
  }

  BrushType _brushTypeForTool() {
    switch (widget.state.activeTool) {
      case Tool.shapes:
        return BrushType.marker;
      case Tool.erase:
        return BrushType.eraser;
      default:
        return BrushType.basic;
    }
  }

  void _applyLiquify(Offset screen) {
    final hit = _raycast(screen);
    if (hit == null) return;
    final radius = (widget.state.brushSize / 100).clamp(0.05, 2.0);
    final strength = 0.04 + widget.state.brushOpacity * 0.06;
    final dir = widget.state.camera.forward;
    widget.state.strokes.applyLiquify(
      LiquifyMode.push,
      hit.point,
      radius,
      strength,
      dir,
    );
    setState(() {});
  }

  SurfaceRayHit? _raycast(Offset screen) {
    if (_viewport == Size.zero) return null;
    final aspect = _viewport.width / _viewport.height;
    final vp = widget.state.camera.viewProjectionMatrix(aspect);
    final ray = _screenToRay(screen, _viewport, vp);
    return widget.state.guideSurface.raycast(ray);
  }

  void _stampDab(Vector2 uv) {
    final state = widget.state;
    final isErase = state.activeTool == Tool.erase;
    final dab = _generateDab(state, _pressure);
    state.texture.paintDab(
      dab,
      uv.x,
      uv.y,
      opacity: state.brushOpacity,
      eraser: isErase,
    );
  }

  BrushDab _generateDab(EditorState state, double pressure) {
    final engine = state.brushEngine;
    if (engine != null) {
      try {
        final dab = engine.generateDab(BrushInput(
          x: 0,
          y: 0,
          pressure: pressure,
          time: DateTime.now().millisecondsSinceEpoch / 1000.0,
        ));
        if (!dab.isEmpty) return dab;
      } catch (_) {
        // fall through to synthetic dab.
      }
    }
    return _syntheticDab(state.brushSize, state.brushColor);
  }

  /// Builds a soft radial-gradient dab in pure Dart (used when the native
  /// Krita engine is unavailable). The result is a square RGBA8 image of
  /// side `ceil(radius) * 2` with a smooth falloff.
  static BrushDab _syntheticDab(double radius, int argb) {
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

  // ----- Build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final state = widget.state;
        return Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: ColoredBox(
              color: AppTheme.canvasBackground,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _ScenePainter(
                      state: state,
                      viewport: _viewport,
                      livePoints: _livePoints,
                      liveColor: state.brushColor,
                      liveThickness: state.brushSize,
                      drawing: _drawing,
                    ),
                  ),
                  // HUD: crosshair + cursor hint.
                  _HudOverlay(state: state, drawing: _drawing),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// HUD overlay.
// ---------------------------------------------------------------------------

class _HudOverlay extends StatelessWidget {
  const _HudOverlay({required this.state, required this.drawing});

  final EditorState state;
  final bool drawing;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 12,
      bottom: 12,
      child: IgnorePointer(
        child: GlassContainer(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          borderRadius: AppTheme.radiusMedium,
          color: AppTheme.darkGlass.withOpacity(0.45),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                state.activeTool.name.toUpperCase(),
                style: TextStyle(
                  color: _toolColor(state.activeTool),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                drawing
                    ? 'drawing… ${state.guideSurface.type.name}'
                    : '${state.guideSurface.type.name} guide',
                style: const TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _toolColor(Tool t) {
    switch (t) {
      case Tool.draw:
        return AppTheme.toolDraw;
      case Tool.erase:
        return AppTheme.toolErase;
      case Tool.shapes:
        return AppTheme.toolShape;
      case Tool.liquify:
        return AppTheme.toolLiquify;
      case Tool.select:
        return AppTheme.toolSelect;
      case Tool.light:
        return AppTheme.toolLight;
      case Tool.export:
        return AppTheme.toolExport;
      case Tool.settings:
        return AppTheme.primaryPurple;
    }
  }
}

// ---------------------------------------------------------------------------
// Scene painter (software 3D renderer).
// ---------------------------------------------------------------------------

class _ScenePainter extends CustomPainter {
  _ScenePainter({
    required this.state,
    required this.viewport,
    required this.livePoints,
    required this.liveColor,
    required this.liveThickness,
    required this.drawing,
  });

  final EditorState state;
  final Size viewport;
  final List<StrokePoint> livePoints;
  final int liveColor;
  final double liveThickness;
  final bool drawing;

  @override
  void paint(Canvas canvas, Size size) {
    final aspect = size.width / size.height;
    final vp = state.camera.viewProjectionMatrix(aspect);
    final view = state.camera.viewMatrix;

    // Background gradient.
    final bg = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: [
          const Color(0xFF101015),
          AppTheme.canvasBackground,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    // Grid (below the surface).
    if (state.showGrid) {
      _drawGrid(canvas, size, vp, view);
    }

    // Mirror planes.
    if (state.showMirrorPlanes) {
      _drawMirrorPlanes(canvas, size, vp, view);
    }

    // Guide surface.
    _drawGuideSurface(canvas, size, vp, view);

    // Existing strokes.
    for (final stroke in state.strokes.strokes) {
      if (!stroke.isVisible) continue;
      _drawStroke(canvas, size, vp, stroke,
          isMirror: stroke.mirrorOfId != null);
    }

    // Live stroke.
    if (drawing && livePoints.isNotEmpty) {
      _drawLiveStroke(canvas, size, vp);
    }
  }

  // ----- Grid ------------------------------------------------------------

  void _drawGrid(Canvas canvas, Size size, Matrix4 vp, Matrix4 view) {
    const extent = 3;
    const step = 0.5;
    final yLevel = -1.6;
    final paint = Paint()
      ..color = AppTheme.canvasGrid
      ..strokeWidth = 0.7
      ..style = PaintingStyle.stroke;

    for (var i = -extent; i <= extent; i++) {
      final x = i * step.toDouble();
      final a = _project(Vector3(-extent.toDouble(), yLevel, x), vp, size);
      final b = _project(Vector3(extent.toDouble(), yLevel, x), vp, size);
      if (a != null && b != null) {
        canvas.drawLine(a, b, paint);
      }
      final c = _project(Vector3(x, yLevel, -extent.toDouble()), vp, size);
      final d = _project(Vector3(x, yLevel, extent.toDouble()), vp, size);
      if (c != null && d != null) {
        canvas.drawLine(c, d, paint);
      }
    }
    // Axes.
    final o = _project(Vector3(0, yLevel, 0), vp, size);
    final xx = _project(Vector3(1.2, yLevel, 0), vp, size);
    final zz = _project(Vector3(0, yLevel, 1.2), vp, size);
    if (o != null && xx != null) {
      canvas.drawLine(o, xx, Paint()..color = AppTheme.primaryPink..strokeWidth = 1.2);
    }
    if (o != null && zz != null) {
      canvas.drawLine(o, zz, Paint()..color = AppTheme.primaryBlue..strokeWidth = 1.2);
    }
  }

  // ----- Mirror planes ---------------------------------------------------

  void _drawMirrorPlanes(Canvas canvas, Size size, Matrix4 vp, Matrix4 view) {
    const half = 2.0;
    void drawPlane(Vector3 axis, Color color) {
      // Build two in-plane basis vectors perpendicular to `axis`.
      Vector3 u;
      Vector3 v;
      if (axis.x.abs() > 0.5) {
        u = Vector3(0, 1, 0);
        v = Vector3(0, 0, 1);
      } else if (axis.y.abs() > 0.5) {
        u = Vector3(1, 0, 0);
        v = Vector3(0, 0, 1);
      } else {
        u = Vector3(1, 0, 0);
        v = Vector3(0, 1, 0);
      }
      final p0 = u * -half + v * -half;
      final p1 = u * half + v * -half;
      final p2 = u * half + v * half;
      final p3 = u * -half + v * half;
      final s0 = _project(p0, vp, size);
      final s1 = _project(p1, vp, size);
      final s2 = _project(p2, vp, size);
      final s3 = _project(p3, vp, size);
      if (s0 == null || s1 == null || s2 == null || s3 == null) return;
      final path = Path()
        ..moveTo(s0.dx, s0.dy)
        ..lineTo(s1.dx, s1.dy)
        ..lineTo(s2.dx, s2.dy)
        ..lineTo(s3.dx, s3.dy)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withOpacity(0.10)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withOpacity(0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    if (state.mirrorX) drawPlane(Vector3(1, 0, 0), AppTheme.primaryPink);
    if (state.mirrorY) drawPlane(Vector3(0, 1, 0), AppTheme.primaryGreen);
    if (state.mirrorZ) drawPlane(Vector3(0, 0, 1), AppTheme.primaryBlue);
  }

  // ----- Guide surface ---------------------------------------------------

  void _drawGuideSurface(Canvas canvas, Size size, Matrix4 vp, Matrix4 view) {
    final surface = state.guideSurface;
    final mesh = surface.mesh;
    final indices = mesh.indices;
    final positions = mesh.positions;
    final uvs = mesh.uvs;
    final camPos = state.camera.position;

    // Pre-compute world positions for all vertices.
    final world = List<Vector3>.generate(
      positions.length,
      (i) => surface.transform.transform3(positions[i].clone()),
      growable: false,
    );

    final tris = <_Triangle>[];
    for (var i = 0; i < indices.length; i += 3) {
      final i0 = indices[i];
      final i1 = indices[i + 1];
      final i2 = indices[i + 2];
      final w0 = world[i0];
      final w1 = world[i1];
      final w2 = world[i2];

      // Backface cull (geometric normal vs view direction).
      final e1 = w1 - w0;
      final e2 = w2 - w0;
      final n = e1.cross(e2);
      if (n.length2 < 1e-12) continue;
      final centroid = (w0 + w1 + w2).scaled(1.0 / 3.0);
      final toCam = camPos - centroid;
      if (n.dot(toCam) < 0) continue; // back-facing

      // Project.
      final s0 = _project(w0, vp, size);
      final s1 = _project(w1, vp, size);
      final s2 = _project(w2, vp, size);
      if (s0 == null || s1 == null || s2 == null) continue;

      // Camera-space depth (for painter's sort).
      final cv = view.transform3(centroid.clone());
      // UV centroid → texture sample.
      final uv = (uvs[i0] + uvs[i1] + uvs[i2]).scaled(1.0 / 3.0);
      tris.add(_Triangle(s0, s1, s2, cv.z, uv));
    }

    tris.sort((a, b) => a.depth.compareTo(b.depth));

    final surfaceTint = Color.fromARGB(
      255,
      (state.guideSurface.color.x * 255).round().clamp(0, 255),
      (state.guideSurface.color.y * 255).round().clamp(0, 255),
      (state.guideSurface.color.z * 255).round().clamp(0, 255),
    );

    for (final t in tris) {
      final sample = state.texture.sample(t.uv.x, t.uv.y);
      final sA = sample[3] / 255.0;
      final blendR = (surfaceTint.red * (1 - sA) + sample[0] * sA).round();
      final blendG = (surfaceTint.green * (1 - sA) + sample[1] * sA).round();
      final blendB = (surfaceTint.blue * (1 - sA) + sample[2] * sA).round();
      final alpha = (0.35 + 0.6 * sA).clamp(0.0, 1.0);
      final path = Path()
        ..moveTo(t.s0.dx, t.s0.dy)
        ..lineTo(t.s1.dx, t.s1.dy)
        ..lineTo(t.s2.dx, t.s2.dy)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.fromARGB(
              (alpha * 255).round(), blendR, blendG, blendB)
          ..style = PaintingStyle.fill,
      );
      // Subtle edge.
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0x15FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.4,
      );
    }
  }

  // ----- Strokes ---------------------------------------------------------

  void _drawStroke(Canvas canvas, Size size, Matrix4 vp, Stroke stroke,
      {required bool isMirror}) {
    if (stroke.points.isEmpty) return;
    final pts = <Offset>[];
    final widths = <double>[];
    final distScale = (state.camera.currentDistance / 6.0).clamp(0.3, 3.0);
    for (final p in stroke.points) {
      final w = stroke.transform.transform3(p.position.clone());
      final s = _project(w, vp, size);
      if (s == null) {
        if (pts.isNotEmpty) {
          _strokeSegment(canvas, pts, widths, stroke.color, isMirror);
          pts.clear();
          widths.clear();
        }
        continue;
      }
      pts.add(s);
      widths.add(stroke.thickness * 0.5 * distScale *
          (0.4 + 0.6 * p.pressure));
    }
    if (pts.isNotEmpty) {
      _strokeSegment(canvas, pts, widths, stroke.color, isMirror);
    }
  }

  void _strokeSegment(
      Canvas canvas, List<Offset> pts, List<double> widths, int color,
      bool isMirror) {
    if (pts.length == 1) {
      canvas.drawCircle(
        pts.first,
        widths.first / 2,
        Paint()..color = _strokeColor(color, isMirror),
      );
      return;
    }
    for (var i = 1; i < pts.length; i++) {
      final w = (widths[i - 1] + widths[i]) * 0.5;
      canvas.drawLine(
        pts[i - 1],
        pts[i],
        Paint()
          ..color = _strokeColor(color, isMirror)
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _drawLiveStroke(Canvas canvas, Size size, Matrix4 vp) {
    if (livePoints.isEmpty) return;
    final distScale = (state.camera.currentDistance / 6.0).clamp(0.3, 3.0);
    final paint = Paint()
      ..color = Color(liveColor)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final glow = Paint()
      ..color = Color(liveColor).withOpacity(0.35)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    Offset? prev;
    for (final p in livePoints) {
      final s = _project(p.position.clone(), vp, size);
      if (s == null) {
        prev = null;
        continue;
      }
      if (prev != null) {
        final w = liveThickness * 0.5 * distScale * (0.4 + 0.6 * p.pressure);
        canvas.drawLine(prev, s, glow..strokeWidth = w + 3);
        canvas.drawLine(prev, s, paint..strokeWidth = w);
      } else {
        canvas.drawCircle(s, liveThickness * 0.25 * distScale, paint);
      }
      prev = s;
    }
  }

  Color _strokeColor(int argb, bool isMirror) {
    final c = Color(argb);
    if (!isMirror) return c;
    return c.withOpacity(0.55);
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) => true;
}

// ---------------------------------------------------------------------------
// Geometry helpers.
// ---------------------------------------------------------------------------

class _Triangle {
  const _Triangle(this.s0, this.s1, this.s2, this.depth, this.uv);
  final Offset s0;
  final Offset s1;
  final Offset s2;
  final double depth;
  final Vector2 uv;
}

/// Projects a world-space point to screen space. Returns `null` if the
/// point is behind the camera (w <= 0).
Offset? _project(Vector3 world, Matrix4 vp, Size size) {
  final m = vp.storage;
  final x = world.x;
  final y = world.y;
  final z = world.z;
  final w = m[3] * x + m[7] * y + m[11] * z + m[15];
  if (w <= 1e-6) return null;
  final nx = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
  final ny = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
  return Offset(
    (nx + 1) * 0.5 * size.width,
    (1 - (ny + 1) * 0.5) * size.height,
  );
}

/// Unprojects an NDC point (with perspective divide) using the inverse
/// view-projection matrix.
Vector3 _unproject(double nx, double ny, double ndcZ, Matrix4 invVp) {
  final m = invVp.storage;
  final x = nx;
  final y = ny;
  final z = ndcZ;
  final w = m[3] * x + m[7] * y + m[11] * z + m[15];
  final px = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
  final py = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
  final pz = (m[2] * x + m[6] * y + m[10] * z + m[14]) / w;
  return Vector3(px, py, pz);
}

/// Builds a world-space ray from a screen-space point.
Ray _screenToRay(Offset screen, Size size, Matrix4 vp) {
  final nx = (screen.dx / size.width) * 2 - 1;
  final ny = 1 - (screen.dy / size.height) * 2;
  final inv = Matrix4.inverted(vp);
  final near = _unproject(nx, ny, -1, inv);
  final far = _unproject(nx, ny, 1, inv);
  final dir = (far - near)..normalize();
  return Ray.originDirection(near, dir);
}
