// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// canvas_widget.dart — 3D canvas viewport (Feather 3D style).
//
// A software-rendered 3D viewport built on [CustomPainter]. It:
//   - Renders the active [GuideSurface] as a backface-culled, depth-sorted
//     triangle mesh mapped PER FRAGMENT from the rasterized guide texture
//     (drawVertices + ImageShader; loop-51), falling back to the legacy
//     per-triangle flat sample while the texture image decodes. Contour
//     edges carry a soft silhouette feather quad (loop-56) so the
//     non-AA drawVertices rasterization reads antialiased.
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
import 'dart:typed_data' show Float64List;
import 'dart:ui' show Vertices, VertexMode;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/glass_slider.dart';
import 'package:feather_krita/engine/synthetic_dab.dart';
import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/engine/scene_pipeline.dart';
import 'package:feather_krita/engine/stroke_manager.dart';
import 'package:feather_krita/engine/texture_image.dart';
import 'package:feather_krita/engine/texture_painter.dart'
    show applySurfaceContract;
import 'package:feather_krita/models/stroke.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/utils/stroke_smoother.dart';

/// The 3D canvas viewport.
class CanvasWidget extends StatefulWidget {
  const CanvasWidget({super.key, required this.state});

  final EditorState state;

  @override
  State<CanvasWidget> createState() => CanvasWidgetState();
}

/// State for [CanvasWidget]. Public (with a testing-only accessor) so
/// widget tests can assert the ticker's idle-muting behavior.
class CanvasWidgetState extends State<CanvasWidget>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  bool _drawing = false;

  /// Elapsed of the previous tick — the Ticker callback reports CUMULATIVE
  /// time since start (which resets on restart), so frame deltas must be
  /// derived here. Feeding cumulative time into camera.tick() made the
  /// damping snap instantly after ~1s of app uptime.
  Duration? _lastElapsed;

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

  /// Whether the frame ticker is currently running. The ticker mutes
  /// itself once the camera damping settles and no stroke is in flight —
  /// a permanently-running ticker burns battery for zero visual change.
  @visibleForTesting
  bool get isTicking => _ticker.isActive;

  /// Restarts the muted ticker. Called from every input path that can
  /// move the camera or start a stroke.
  void wake() {
    if (_ticker.isActive) return;
    _lastElapsed = null;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final last = _lastElapsed;
    _lastElapsed = elapsed;
    final dt = last == null
        ? 1 / 60.0
        : ((elapsed - last).inMicroseconds / 1000000.0)
            .clamp(1 / 1000.0, 0.25);
    final changed = widget.state.camera.tick(dt);
    if (changed || _drawing) {
      setState(() {});
    } else {
      // Camera settled and nothing is animating — stop scheduling frames
      // until the next interaction wakes us.
      _ticker.stop();
    }
  }

  bool get _isDrawTool =>
      widget.state.activeTool == Tool.draw ||
      widget.state.activeTool == Tool.erase ||
      widget.state.activeTool == Tool.shapes;

  bool get _isLiquifyTool => widget.state.activeTool == Tool.liquify;

  bool get _isLightTool => widget.state.activeTool == Tool.light;

  // ----- Input handling --------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    wake();
    _pressure = 0.85;
    if (_isDrawTool && details.pointerCount == 1) {
      _beginStroke(details.localFocalPoint);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    wake();
    if (details.pointerCount == 1) {
      if (_isDrawTool && _drawing) {
        _continueStroke(details.localFocalPoint);
      } else if (_isLiquifyTool) {
        _applyLiquify(details.localFocalPoint);
      } else if (_isLightTool) {
        _orbitLight(details.focalPointDelta.dx, details.focalPointDelta.dy);
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
      wake();
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
      uv: hit.uv.clone(),
    ));
    // One unified journal entry for the whole stroke (loop-20): the
    // pre-stroke strokes+texture state is held pending and committed by
    // endPaintStroke when the stroke is added. (Loop-14 history: per-dab
    // snapshots were full-texture copies, 16 MB each, and could OOM-kill
    // the app.)
    widget.state.beginPaintStroke();
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
      uv: hit.uv.clone(),
    ));
    _stampDab(hit.uv);
    setState(() {});
  }

  void _endStroke() {
    _drawing = false;
    if (_livePoints.isNotEmpty) {
      final isErase = widget.state.activeTool == Tool.erase;
      // Loop-25: stabilize the captured path before commit. Live dabbing
      // used the raw pointer stream (so the user sees no input lag while
      // drawing); only the recorded stroke geometry is smoothed. A
      // strength of 0 returns a deep copy unchanged (cheap no-op).
      final smoothed = StrokeSmoother.smooth(_livePoints,
          strength: widget.state.brushSmoothing);
      final stroke = Stroke(
        brushType: isErase ? BrushType.eraser : _brushTypeForTool(),
        color: widget.state.brushColor,
        thickness: widget.state.brushSize,
        points: smoothed,
        name: isErase ? 'Eraser' : widget.state.brushPresetName,
      );
      // Commits ONE journal entry (pre-stroke strokes + pixels) and adds
      // the stroke — texture and stroke list now undo in lockstep.
      widget.state.endPaintStroke(stroke);
    } else {
      widget.state.discardPaintStroke();
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

  /// Light tool drag (loop-52): orbit the scene key light around the
  /// scene. Horizontal drags sweep the sun's azimuth, vertical drags
  /// raise / lower its elevation. Two-finger gestures still drive the
  /// camera (handled in the same callback), so the rig never fights the
  /// camera orbit.
  void _orbitLight(double dx, double dy) {
    if (dx == 0 && dy == 0) return;
    widget.state.lightRig.orbitBy(dx, dy);
    widget.state.notify();
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
    return syntheticDab(state.brushSize, state.brushColor);
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
                  // Light intensity dial (loop-54): only while the Light
                  // tool is active. The slider sits above the HUD block
                  // and wins the gesture arena over the canvas, so
                  // dragging it never orbits the camera or the sun.
                  if (state.activeTool == Tool.light)
                    _LightIntensityPanel(
                      state: state,
                      onLightChanged: () {
                        widget.state.notify();
                        setState(() {});
                      },
                    ),
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
// Light intensity panel (loop-54).
// ---------------------------------------------------------------------------

/// A compact glass slider driving the scene key light's diffuse intensity
/// while the Light tool is active (loop-54). Until now the HUD's
/// "power %" readout had no control behind it — the intensity could not
/// be changed from the UI at all. The rig's own [SceneLightRig.setIntensity]
/// clamps to [0, 1]; 1% divisions make the keyboard arrows (handled inside
/// [GlassSlider]) step exactly 1 power point. Positioned above the HUD
/// block; the slider's own gesture detector wins the arena over the
/// canvas, so a drag here never orbits the sun or the camera.
class _LightIntensityPanel extends StatelessWidget {
  const _LightIntensityPanel({
    required this.state,
    required this.onLightChanged,
  });

  final EditorState state;
  final VoidCallback onLightChanged;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 12,
      bottom: 88,
      child: SizedBox(
        width: 230,
        child: GlassSlider(
          key: const ValueKey('light_intensity_slider'),
          value: state.lightRig.intensity,
          min: 0,
          max: 1,
          divisions: 100,
          label: 'Light power',
          icon: Icons.wb_sunny_outlined,
          accent: AppTheme.toolLight,
          valueFormatter: (v) => '${(v * 100).round()}%',
          onChanged: (v) {
            state.lightRig.setIntensity(v);
            onLightChanged();
          },
        ),
      ),
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
              if (state.activeTool == Tool.light) ...[
                const SizedBox(height: 2),
                Text(
                  'sun ${state.lightRig.sunElevationDeg.toStringAsFixed(0)}° '
                      'az ${state.lightRig.sunAzimuthDeg.toStringAsFixed(0)}° · '
                      'power ${(state.lightRig.intensity * 100).round()}%',
                  style: const TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 9,
                  ),
                ),
              ],
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

// Identity UV transform for the surface shader (no matrix4 param in
// this Flutter version's ImageShader).
final Float64List _identityShaderMatrix =
    Float64List.fromList(const [
  1, 0, 0, 0, //
  0, 1, 0, 0, //
  0, 0, 1, 0, //
  0, 0, 0, 1,
]);

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

    // Unified depth-sorted scene pass (loop-50 pipeline): surface
    // triangles and stroke ribbons live in ONE back-to-front draw list,
    // so paint occludes correctly behind curved guides and stroke widths
    // are true perspective (anchored at the default orbit distance).
    final items = buildUnifiedDrawList(
      surface: _buildSurfaceInput(state),
      strokes: _buildStrokeInputs(state),
      camera: SceneCameraInput(
        position: state.camera.position,
        view: view,
        viewProjection: vp,
        fovYRadians: state.camera.projection.fovYRadians,
      ),
      viewport: size,
      keyLight: state.lightRig.direction,
      lightIntensity: state.lightRig.intensity,
    );

    // loop-51: rasterize the guide texture with the shading contract
    // baked in (async, cached per texture version / tint) and map it
    // per-fragment across the surface triangles. Null until the first
    // decode lands — the flat per-triangle paint covers those frames.
    TextureImageCache.refresh(
      state.texture,
      tintR: state.guideSurface.color.x,
      tintG: state.guideSurface.color.y,
      tintB: state.guideSurface.color.z,
    );
    _drawSceneItems(canvas, items, TextureImageCache.current);

    // Light tool gizmo (loop-52): a projected sun marker + light ray so
    // the user sees where the key light sits while orbiting it. Drawn on
    // top of the scene — it is an editor overlay, not scene geometry.
    if (state.activeTool == Tool.light) {
      _drawLightGizmo(canvas, size, vp);
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

  // ----- Unified scene pipeline inputs -----------------------------------

  /// Surface pass input: world-transformed mesh + the legacy per-triangle
  /// shading contract (tint × texture sample, fill alpha rising from
  /// 0.35 bare glass to 0.95 painted) resolved into a single sampler.
  /// The contract math lives in [applySurfaceContract] so the whole-
  /// buffer bake for per-fragment mapping blends identically.
  SceneSurfaceInput _buildSurfaceInput(EditorState state) {
    final surface = state.guideSurface;
    final mesh = surface.mesh;
    final world = List<Vector3>.generate(
      mesh.positions.length,
      (i) => surface.transform.transform3(mesh.positions[i].clone()),
      growable: false,
    );
    final tint = Color.fromARGB(
      255,
      (surface.color.x * 255).round().clamp(0, 255),
      (surface.color.y * 255).round().clamp(0, 255),
      (surface.color.z * 255).round().clamp(0, 255),
    );
    return SceneSurfaceInput(
      positions: world,
      indices: mesh.indices,
      uvs: mesh.uvs,
      sampleColor: (uv) {
        final s = state.texture.sample(uv.x, uv.y);
        final c = applySurfaceContract(
            s[0], s[1], s[2], s[3], tint.r, tint.g, tint.b);
        return Color.fromARGB(c[3], c[0], c[1], c[2]);
      },
    );
  }

  /// Stroke pass inputs: world-space samples for every visible stroke.
  List<SceneStrokeInput> _buildStrokeInputs(EditorState state) {
    return [
      for (final stroke in state.strokes.strokes)
        if (stroke.isVisible)
          SceneStrokeInput(
            points: [
              for (final p in stroke.points)
                stroke.transform.transform3(p.position.clone()),
            ],
            pressures: [for (final p in stroke.points) p.pressure],
            thickness: stroke.thickness,
            color: Color(stroke.color),
            isMirror: stroke.mirrorOfId != null,
          ),
    ];
  }

  /// Draws the pipeline's ordered primitives (back-to-front). Surface
  /// triangles carrying UV corners are texture-mapped per fragment from
  /// [surfaceImage] when it is ready; otherwise they fall back to their
  /// flat sampled color (identical to the legacy centroid paint).
  void _drawSceneItems(
      Canvas canvas, List<SceneDrawItem> items, dynamic surfaceImage) {
    final surfaceShader = surfaceImage == null
        ? null
        : ImageShader(surfaceImage, TileMode.clamp, TileMode.clamp,
            _identityShaderMatrix,
            filterQuality: FilterQuality.low);
    final imgW = surfaceImage?.width.toDouble() ?? 1.0;
    final imgH = surfaceImage?.height.toDouble() ?? 1.0;
    for (final item in items) {
      if (item is SceneTri) {
        final path = Path()
          ..moveTo(item.s0.dx, item.s0.dy)
          ..lineTo(item.s1.dx, item.s1.dy)
          ..lineTo(item.s2.dx, item.s2.dy)
          ..close();
        if (surfaceShader != null &&
            item.uv0 != null &&
            item.uv1 != null &&
            item.uv2 != null) {
          // Per-fragment texture mapping (loop-51): the baked image
          // already carries the tint × texture × fill-alpha contract, so
          // plain source-over of the mapped texels is the final paint.
          final verts = Vertices(
            VertexMode.triangles,
            [item.s0, item.s1, item.s2],
            textureCoordinates: [
              Offset(item.uv0!.dx * imgW, item.uv0!.dy * imgH),
              Offset(item.uv1!.dx * imgW, item.uv1!.dy * imgH),
              Offset(item.uv2!.dx * imgW, item.uv2!.dy * imgH),
            ],
          );
          canvas.drawVertices(
              verts, BlendMode.srcOver, Paint()..shader = surfaceShader);
          verts.dispose();
        } else {
          canvas.drawPath(
            path,
            Paint()
              ..color = item.color
              ..style = PaintingStyle.fill,
          );
        }
        // Subtle edge.
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0x15FFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.4,
        );
      } else if (item is SceneFeather) {
        // loop-56: silhouette contour feather — a two-triangle strip
        // whose base edge repeats the surface color and whose outer edge
        // repeats it at alpha 0; per-vertex interpolation produces the
        // linear coverage ramp that softens the non-AA silhouette into
        // the background (MSAA-ish edge softening).
        final faded = item.color.withAlpha(0);
        final verts = Vertices(
          VertexMode.triangleStrip,
          [item.a, item.b, item.aOuter, item.bOuter],
          colors: [item.color, item.color, faded, faded],
        );
        canvas.drawVertices(verts, BlendMode.srcOver, Paint());
        verts.dispose();
      } else if (item is SceneSegment) {
        canvas.drawLine(
          item.a,
          item.b,
          Paint()
            ..color = item.color
            ..strokeWidth = item.widthPx
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke,
        );
      } else if (item is SceneDot) {
        canvas.drawCircle(
          item.center,
          item.radius,
          Paint()..color = item.color,
        );
      }
    }
  }

  // ----- Light gizmo ------------------------------------------------------

  void _drawLightGizmo(Canvas canvas, Size size, Matrix4 vp) {
    // The sun sits OPPOSITE the light direction at a fixed radius, well
    // outside the default 1.4 guide sphere.
    final sunWorld = state.lightRig.direction.scaled(-2.6);
    final sun = _project(sunWorld, vp, size);
    final target = _project(Vector3.zero(), vp, size);
    if (sun == null || target == null) return;
    canvas.drawLine(
      sun,
      target,
      Paint()
        ..color = AppTheme.toolLight.withValues(alpha: 0.35)
        ..strokeWidth = 1.2,
    );
    canvas.drawCircle(sun, 6.5, Paint()..color = AppTheme.toolLight);
    canvas.drawCircle(
      sun,
      10,
      Paint()
        ..color = AppTheme.toolLight.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  void _drawLiveStroke(Canvas canvas, Size size, Matrix4 vp) {
    if (livePoints.isEmpty) return;
    final paint = Paint()
      ..color = Color(liveColor)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final glow = Paint()
      ..color = Color(liveColor).withValues(alpha: 0.35)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    // Same perspective-correct width as committed strokes (loop-50), so a
    // stroke does not jump in width when it commits.
    SceneProjection? prev;
    for (final p in livePoints) {
      final s = projectScenePoint(p.position, vp, size);
      if (s == null) {
        prev = null;
        continue;
      }
      final w = sceneStrokeWidthPx(
        thickness: liveThickness,
        pressure: p.pressure,
        clipW: s.clipW,
        referenceDepth: kSceneReferenceDepth,
      );
      if (prev != null) {
        canvas.drawLine(prev.screen, s.screen, glow..strokeWidth = w + 3);
        canvas.drawLine(prev.screen, s.screen, paint..strokeWidth = w);
      } else {
        canvas.drawCircle(s.screen, w * 0.5, paint);
      }
      prev = s;
    }
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) => true;
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
