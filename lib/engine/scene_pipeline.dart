// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// scene_pipeline.dart — Feather-3D unified depth-sorted scene pipeline.
//
// loop-50: the renderer's first UNIFIED scene pass. Previously the guide
// surface was depth-sorted among its own triangles and ALL strokes were
// painted on top afterwards — a stroke on the far side of a curved guide
// still floated in front of it — and stroke widths were scaled by a
// global camera-distance heuristic instead of true perspective.
//
// This module builds ONE back-to-front draw list containing both the
// surface's triangles and the strokes' camera-facing ribbon segments:
//   - TRUE perspective-correct stroke width: each sample's screen width
//     scales with referenceDepth / clipW (anchored at the default orbit
//     distance, so the default view matches the legacy heuristic exactly).
//   - Lambert directional shading per ribbon segment: the segment's
//     view-facing normal is lit by a fixed key light, ambient-floored, so
//     strokes read as lit 3D geometry instead of flat wireframes.
//   - Camera-space depth shared by surface AND stroke primitives, sorted
//     back-to-front → correct mutual occlusion between paint and surface.
//
// The output primitives are plain data (screen-space), so the caller can
// draw them with any backend — CustomPainter today, the pluggable
// hardware renderer later. Pure Dart: no widget bindings, fully unit
// testable.

import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Size;

import 'package:vector_math/vector_math_64.dart';

/// Camera-space depth that maps to the legacy width heuristic's scale 1.
///
/// The orbit camera's default distance is 6.0; anchoring the perspective
/// width there means the default view renders stroke widths identical to
/// the pre-pipeline heuristic (`distScale == 1` at the default pose).
const double kSceneReferenceDepth = 6.0;

/// Fixed key light direction (world space, pointing FROM the light).
/// Top-left-front key light — matches the glassmorphism scene's soft
/// overhead look. Constant for now; the Light tool may drive it later.
final Vector3 kSceneKeyLight =
    Vector3(-0.35, -1.0, -0.55)..normalize();

/// Ambient floor of the Lambert ramp. Diffuse contributes the remainder
/// up to 1.0, so fully-lit geometry doubles an ambient-only sample.
const double kSceneAmbient = 0.62;

/// Clamp for the perspective width scale. Prevents singular widths near
/// the camera (clipW → 0) and ultra-thin strokes when zoomed far out.
const double kMinWidthScale = 0.12;
const double kMaxWidthScale = 5.0;

/// One drawable primitive in the unified, back-to-front scene list.
abstract class SceneDrawItem {
  const SceneDrawItem(this.depth, this.seq);

  /// Camera-space depth (view-matrix z). More negative = farther from
  /// the camera (standard look-down-minus-Z convention). Sorted ascending
  /// → drawn back-to-front.
  final double depth;

  /// Insertion order tiebreaker for equal depths (Dart's sort is not
  /// stable; this makes the ordering deterministic — surface items are
  /// appended before stroke items, so ties read surface-first).
  final int seq;
}

/// A projected, shaded surface triangle.
class SceneTri extends SceneDrawItem {
  const SceneTri(this.s0, this.s1, this.s2, this.color, double depth, int seq)
      : super(depth, seq);

  final Offset s0;
  final Offset s1;
  final Offset s2;

  /// Final fill color — texture/tint blending AND the translucency alpha
  /// are resolved by the caller's sampler before the pipeline sees it.
  final Color color;
}

/// A stroke ribbon segment between two consecutive visible samples,
/// shaded and perspective-scaled.
class SceneSegment extends SceneDrawItem {
  const SceneSegment(this.a, this.b, this.widthPx, this.color, double depth,
      int seq)
      : super(depth, seq);

  final Offset a;
  final Offset b;

  /// Screen-space stroke width for this segment (average of the two
  /// per-sample perspective widths). Draw with round caps/joins.
  final double widthPx;

  /// Lambert-shaded stroke color (mirror dimming already applied).
  final Color color;
}

/// A lone visible stroke sample (segment runs of length 1 or zero-length
/// segments) — rendered as a round dab.
class SceneDot extends SceneDrawItem {
  const SceneDot(this.center, this.radius, this.color, double depth, int seq)
      : super(depth, seq);

  final Offset center;
  final double radius;
  final Color color;
}

/// A world-space point projected to screen space together with its clip
/// w (needed for perspective-correct width).
class SceneProjection {
  const SceneProjection(this.screen, this.clipW);

  final Offset screen;
  final double clipW;
}

/// Camera inputs for the pipeline.
class SceneCameraInput {
  const SceneCameraInput({
    required this.position,
    required this.view,
    required this.viewProjection,
    required this.fovYRadians,
    this.referenceDepth = kSceneReferenceDepth,
  });

  /// World-space camera position (for backface culling and shading).
  final Vector3 position;

  /// World → camera-space matrix (depth source).
  final Matrix4 view;

  /// World → clip matrix (projection source).
  final Matrix4 viewProjection;

  /// Vertical field of view in radians (focal length source).
  final double fovYRadians;

  /// Depth that maps to width scale 1.0.
  final double referenceDepth;
}

/// Guide-surface inputs (world-space triangle soup + UV sampler).
class SceneSurfaceInput {
  const SceneSurfaceInput({
    required this.positions,
    required this.indices,
    required this.uvs,
    required this.sampleColor,
  });

  /// World-space vertex positions (caller applies the surface transform).
  final List<Vector3> positions;

  /// Triangle index list (3 per triangle).
  final List<int> indices;

  /// Per-vertex UV coordinates (indexed like [positions]).
  final List<Vector2> uvs;

  /// Resolves the final fill color for a UV (texture × tint × alpha).
  final Color Function(Vector2 uv) sampleColor;
}

/// One stroke's render inputs (world-space samples).
class SceneStrokeInput {
  const SceneStrokeInput({
    required this.points,
    required this.pressures,
    required this.thickness,
    required this.color,
    this.isMirror = false,
  });

  /// World-space stroke samples (caller applies the stroke transform).
  final List<Vector3> points;

  /// Per-sample pressure in [0, 1] (parallel to [points]).
  final List<double> pressures;

  /// Stroke thickness in screen px at [SceneCameraInput.referenceDepth].
  final double thickness;

  /// Stroke color (opaque alpha expected; mirror dimming is applied here).
  final Color color;

  /// Mirror strokes render at 55% alpha (legacy contract).
  final bool isMirror;
}

/// Projects a world-space point. Returns null behind the near plane.
SceneProjection? projectScenePoint(
    Vector3 world, Matrix4 vp, Size size) {
  final m = vp.storage;
  final x = world.x;
  final y = world.y;
  final z = world.z;
  final w = m[3] * x + m[7] * y + m[11] * z + m[15];
  if (w <= 1e-6) return null;
  final nx = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
  final ny = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
  return SceneProjection(
    Offset(
      (nx + 1) * 0.5 * size.width,
      (1 - (ny + 1) * 0.5) * size.height,
    ),
    w,
  );
}

/// Perspective-correct stroke width in screen px for one sample.
///
/// `clipW` is the sample's clip-space w (≈ camera-space depth for a
/// perspective projection). Width scales with referenceDepth / clipW —
/// the exact inverse of how geometry shrinks with distance — so strokes
/// visually sit ON the surface they were drawn on. Pressure modulates
/// width with the legacy 0.4 + 0.6·p ramp.
double sceneStrokeWidthPx({
  required double thickness,
  required double pressure,
  required double clipW,
  required double referenceDepth,
}) {
  final scale =
      (referenceDepth / clipW).clamp(kMinWidthScale, kMaxWidthScale);
  return thickness * 0.5 * scale * (0.4 + 0.6 * pressure.clamp(0.0, 1.0));
}

/// Lambert-shades [color] for a ribbon segment with world-space tangent
/// [tangent] viewed from [cameraPos] toward [mid].
///
/// The view-facing normal N = T × V is lit by the key light; brightness
/// is floored at [kSceneAmbient]. Mirror strokes keep their alpha dimming
/// handled by [applyMirrorAlpha] — this function only scales RGB.
Color shadeSegment(
    Color color, Vector3 tangent, Vector3 mid, Vector3 cameraPos) {
  final t = tangent.clone()..normalize();
  final v = (cameraPos - mid)..normalize();
  final n = t.cross(v);
  var brightness = kSceneAmbient;
  if (n.length2 > 1e-12) {
    n.normalize();
    brightness =
        (kSceneAmbient + (1.0 - kSceneAmbient) * math.max(0.0, n.dot(kSceneKeyLight)))
            .clamp(0.0, 1.0);
  }
  return Color.fromARGB(
    (color.a * 255.0).round() & 0xff,
    (color.r * brightness * 255.0).round() & 0xff,
    (color.g * brightness * 255.0).round() & 0xff,
    (color.b * brightness * 255.0).round() & 0xff,
  );
}

/// Applies the mirror-stroke alpha contract (55% of the source alpha).
Color applyMirrorAlpha(Color color) =>
    color.withValues(alpha: (color.a * 0.55).clamp(0.0, 1.0));

/// Builds the surface pass items (culled + projected triangles).
List<SceneDrawItem> buildSurfaceItems({
  required SceneSurfaceInput surface,
  required SceneCameraInput camera,
  required Size viewport,
  required int seqStart,
}) {
  final items = <SceneDrawItem>[];
  final indices = surface.indices;
  final positions = surface.positions;
  final uvs = surface.uvs;
  var seq = seqStart;

  for (var i = 0; i < indices.length; i += 3) {
    final w0 = positions[indices[i]];
    final w1 = positions[indices[i + 1]];
    final w2 = positions[indices[i + 2]];

    // Backface cull (geometric normal vs view direction).
    final e1 = w1 - w0;
    final e2 = w2 - w0;
    final n = e1.cross(e2);
    if (n.length2 < 1e-12) continue;
    final centroid = (w0 + w1 + w2).scaled(1.0 / 3.0);
    final toCam = camera.position - centroid;
    if (n.dot(toCam) < 0) continue; // back-facing

    final s0 = projectScenePoint(w0, camera.viewProjection, viewport);
    final s1 = projectScenePoint(w1, camera.viewProjection, viewport);
    final s2 = projectScenePoint(w2, camera.viewProjection, viewport);
    if (s0 == null || s1 == null || s2 == null) continue;

    final depth = camera.view.transform3(centroid.clone()).z;
    final uv = (uvs[indices[i]] + uvs[indices[i + 1]] + uvs[indices[i + 2]])
        .scaled(1.0 / 3.0);
    items.add(SceneTri(
        s0.screen, s1.screen, s2.screen, surface.sampleColor(uv), depth, seq));
    seq++;
  }
  return items;
}

/// Builds the stroke pass items: camera-facing ribbon segments with
/// perspective-correct widths, Lambert shading, and per-segment depth.
List<SceneDrawItem> buildStrokeItems({
  required SceneStrokeInput stroke,
  required SceneCameraInput camera,
  required Size viewport,
  required int seqStart,
}) {
  final items = <SceneDrawItem>[];
  if (stroke.points.isEmpty) return items;

  final baseColor = stroke.isMirror
      ? applyMirrorAlpha(stroke.color)
      : stroke.color;
  final thickness = stroke.thickness;
  final refDepth = camera.referenceDepth;
  var seq = seqStart;

  // Split into runs of consecutively visible samples.
  var run = <SceneProjection>[];
  var runWorld = <Vector3>[];
  var runPressure = <double>[];

  void flushRun() {
    if (run.isEmpty) return;
    if (run.length == 1) {
      final p = run.first;
      final width = sceneStrokeWidthPx(
        thickness: thickness,
        pressure: runPressure.first,
        clipW: p.clipW,
        referenceDepth: refDepth,
      );
      // Lone sample: no tangent → ambient-only shading.
      items.add(SceneDot(
        p.screen,
        width / 2,
        Color.fromARGB(
            (baseColor.a * 255.0).round() & 0xff,
            (baseColor.r * kSceneAmbient * 255.0).round() & 0xff,
            (baseColor.g * kSceneAmbient * 255.0).round() & 0xff,
            (baseColor.b * kSceneAmbient * 255.0).round() & 0xff),
        camera.view.transform3(runWorld.first.clone()).z,
        seq,
      ));
      seq++;
    } else {
      for (var i = 1; i < run.length; i++) {
        final p0 = run[i - 1];
        final p1 = run[i];
        final w0 = sceneStrokeWidthPx(
          thickness: thickness,
          pressure: runPressure[i - 1],
          clipW: p0.clipW,
          referenceDepth: refDepth,
        );
        final w1 = sceneStrokeWidthPx(
          thickness: thickness,
          pressure: runPressure[i],
          clipW: p1.clipW,
          referenceDepth: refDepth,
        );
        final midWorld = (runWorld[i - 1] + runWorld[i]).scaled(0.5);
        final depth = camera.view.transform3(midWorld.clone()).z;
        final tangent = runWorld[i] - runWorld[i - 1];
        final color = shadeSegment(baseColor, tangent, midWorld,
            camera.position);
        items.add(SceneSegment(
          p0.screen,
          p1.screen,
          (w0 + w1) * 0.5,
          color,
          depth,
          seq,
        ));
        seq++;
      }
    }
    run = <SceneProjection>[];
    runWorld = <Vector3>[];
    runPressure = <double>[];
  }

  for (var i = 0; i < stroke.points.length; i++) {
    final proj =
        projectScenePoint(stroke.points[i], camera.viewProjection, viewport);
    if (proj == null) {
      flushRun(); // behind the camera — cut the ribbon here
      continue;
    }
    run.add(proj);
    runWorld.add(stroke.points[i]);
    runPressure.add(
        i < stroke.pressures.length ? stroke.pressures[i] : 1.0);
  }
  flushRun();
  return items;
}

/// Builds the UNIFIED back-to-front draw list: surface triangles and all
/// strokes' ribbon segments depth-sorted together, so paint and surface
/// occlude each other correctly.
List<SceneDrawItem> buildUnifiedDrawList({
  required SceneSurfaceInput surface,
  required List<SceneStrokeInput> strokes,
  required SceneCameraInput camera,
  required Size viewport,
}) {
  final items = <SceneDrawItem>[
    ...buildSurfaceItems(
        surface: surface, camera: camera, viewport: viewport, seqStart: 0),
  ];
  var seq = items.length;
  for (final stroke in strokes) {
    final strokeItems = buildStrokeItems(
        stroke: stroke, camera: camera, viewport: viewport, seqStart: seq);
    items.addAll(strokeItems);
    seq += strokeItems.length;
  }
  items.sort((a, b) {
    final d = a.depth.compareTo(b.depth);
    return d != 0 ? d : a.seq.compareTo(b.seq);
  });
  return items;
}
