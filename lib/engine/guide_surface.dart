// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// guide_surface.dart — 3D guide surfaces (Feather 3D style).
//
// A guide surface is a parametric mesh that the artist draws ONTO. The
// surface provides a UV mapping so that 3D points can be projected back
// into a 2D texture space — exactly how Feather 3D's curved guides work.
//
// Each surface type generates:
//   - A triangle mesh (positions, UVs, indices)
//   - A [raycast] method that converts a screen ray to a UV coordinate.
//
// All math uses the `vector_math` package and the helpers in
// `vector_math_utils.dart`.

import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/utils/vector_math_utils.dart';

/// Supported guide surface types.
enum GuideSurfaceType {
  sphere,
  cylinder,
  cone,
  ring,
  plane,
  customCurve,
}

/// Returns the human-readable name for [type].
String guideSurfaceTypeName(GuideSurfaceType type) {
  switch (type) {
    case GuideSurfaceType.sphere:
      return 'Sphere';
    case GuideSurfaceType.cylinder:
      return 'Cylinder';
    case GuideSurfaceType.cone:
      return 'Cone';
    case GuideSurfaceType.ring:
      return 'Ring / Torus';
    case GuideSurfaceType.plane:
      return 'Plane';
    case GuideSurfaceType.customCurve:
      return 'Custom Curve';
  }
}

/// Parses a [GuideSurfaceType] from a display name (as written by
/// [guideSurfaceTypeName]) or a raw enum name. Falls back to
/// [GuideSurfaceType.sphere] for unknown values.
GuideSurfaceType guideSurfaceTypeFromName(String? name) {
  switch (name?.trim().toLowerCase()) {
    case 'sphere':
      return GuideSurfaceType.sphere;
    case 'cylinder':
      return GuideSurfaceType.cylinder;
    case 'cone':
      return GuideSurfaceType.cone;
    case 'ring / torus':
    case 'ring':
    case 'torus':
      return GuideSurfaceType.ring;
    case 'plane':
      return GuideSurfaceType.plane;
    case 'custom curve':
    case 'customcurve':
    case 'custom_curve':
      return GuideSurfaceType.customCurve;
    default:
      return GuideSurfaceType.sphere;
  }
}

/// A 3D control point used to shape a [GuideSurface].
class SurfaceControlPoint {
  SurfaceControlPoint(this.position, [this.weight = 1.0]);

  final Vector3 position;
  final double weight;

  SurfaceControlPoint copy() => SurfaceControlPoint(position.clone(), weight);

  Map<String, dynamic> toJson() => {
        'x': position.x,
        'y': position.y,
        'z': position.z,
        'w': weight,
      };

  factory SurfaceControlPoint.fromJson(Map<String, dynamic> json) =>
      SurfaceControlPoint(
        Vector3(
          (json['x'] as num).toDouble(),
          (json['y'] as num).toDouble(),
          (json['z'] as num).toDouble(),
        ),
        (json['w'] as num?)?.toDouble() ?? 1.0,
      );
}

/// Triangle mesh generated for a guide surface.
class SurfaceMesh {
  SurfaceMesh({
    required this.positions,
    required this.uvs,
    required this.indices,
    required this.normals,
  });

  /// Flat list of vertex positions (length == vertexCount * 3).
  final List<Vector3> positions;

  /// Per-vertex UV coordinates (length == vertexCount).
  final List<Vector2> uvs;

  /// Triangle indices (length == triangleCount * 3).
  final List<int> indices;

  /// Per-vertex normals (length == vertexCount).
  final List<Vector3> normals;

  int get vertexCount => positions.length;
  int get triangleCount => indices.length ~/ 3;

  /// Computes the axis-aligned bounding box of all vertices.
  Aabb3 get bounds {
    final out = Aabb3();
    for (final p in positions) {
      out.hullPoint(p);
    }
    return out;
  }
}

/// Result of a raycast against a [GuideSurface].
class SurfaceRayHit {
  const SurfaceRayHit({
    required this.uv,
    required this.point,
    required this.normal,
    required this.distance,
    required this.triangleIndex,
  });

  /// UV coordinate in [0, 1] x [0, 1] on the surface.
  final Vector2 uv;

  /// World-space hit point.
  final Vector3 point;

  /// Surface normal at the hit point (interpolated).
  final Vector3 normal;

  /// Distance from the ray origin to the hit point.
  final double distance;

  /// Index of the triangle that was hit.
  final int triangleIndex;
}

/// A parametric guide surface mesh with a transform and raycast method.
///
/// The mesh is generated in local space and transformed to world space via
/// [transform]. Raycasts are performed against the world-space mesh.
class GuideSurface {
  GuideSurface({
    required this.type,
    required this.mesh,
    Matrix4? transform,
    List<SurfaceControlPoint>? controlPoints,
    Vector3? color,
    this.visible = true,
    this.locked = false,
  })  : transform = transform ?? Matrix4.identity(),
        controlPoints = controlPoints ?? [],
        color = color ?? Vector3(0.4, 0.6, 1.0);

  final GuideSurfaceType type;
  final SurfaceMesh mesh;
  Matrix4 transform;
  List<SurfaceControlPoint> controlPoints;
  Vector3 color;
  bool visible;
  bool locked;

  /// Inverse of [transform], cached and invalidated on change.
  Matrix4 _inverse = Matrix4.identity();
  bool _inverseDirty = true;

  void _ensureInverse() {
    if (_inverseDirty) {
      _inverse = Matrix4.inverted(transform);
      _inverseDirty = false;
    }
  }

  /// Marks the cached inverse as dirty after [transform] is mutated.
  void markTransformDirty() => _inverseDirty = true;

  /// Builds a default-shaped surface of [type] with the editor's standard
  /// dimensions. Used when restoring a project that stores only the
  /// surface's type name.
  factory GuideSurface.forType(GuideSurfaceType type) {
    switch (type) {
      case GuideSurfaceType.sphere:
        return GuideSurface.sphere(radius: 1.4, segments: 24, rings: 14);
      case GuideSurfaceType.cylinder:
        return GuideSurface.cylinder();
      case GuideSurfaceType.cone:
        return GuideSurface.cone();
      case GuideSurfaceType.ring:
        return GuideSurface.ring();
      case GuideSurfaceType.plane:
        return GuideSurface.plane();
      case GuideSurfaceType.customCurve:
        return GuideSurface.plane();
    }
  }

  // ----- Factory constructors for each surface type ---------------------

  /// Creates a sphere guide of [radius] centered at the origin.
  factory GuideSurface.sphere({
    double radius = 1.0,
    int segments = 32,
    int rings = 16,
  }) {
    radius = radius.abs();
    final positions = <Vector3>[];
    final uvs = <Vector2>[];
    final normals = <Vector3>[];
    final indices = <int>[];

    // Top pole.
    positions.add(Vector3(0, radius, 0));
    uvs.add(Vector2(0.5, 0.0));
    normals.add(Vector3(0, 1, 0));

    for (var r = 1; r < rings; r++) {
      final phi = math.pi * r / rings;
      final sinPhi = math.sin(phi);
      final cosPhi = math.cos(phi);
      final v = r / rings;
      for (var s = 0; s <= segments; s++) {
        final theta = 2 * math.pi * s / segments;
        final sinT = math.sin(theta);
        final cosT = math.cos(theta);
        final x = radius * sinPhi * cosT;
        final y = radius * cosPhi;
        final z = radius * sinPhi * sinT;
        positions.add(Vector3(x, y, z));
        uvs.add(Vector2(s / segments, v));
        normals.add(Vector3(sinPhi * cosT, cosPhi, sinPhi * sinT)..normalize());
      }
    }

    // Bottom pole.
    positions.add(Vector3(0, -radius, 0));
    uvs.add(Vector2(0.5, 1.0));
    normals.add(Vector3(0, -1, 0));

    final topPole = 0;
    final bottomPole = positions.length - 1;

    // Top fan.
    for (var s = 0; s < segments; s++) {
      final a = 1 + s;
      final b = 1 + s + 1;
      indices.addAll([topPole, a, b]);
    }
    // Middle quads.
    for (var r = 0; r < rings - 2; r++) {
      for (var s = 0; s < segments; s++) {
        final a = 1 + r * (segments + 1) + s;
        final b = a + 1;
        final c = a + (segments + 1);
        final d = c + 1;
        indices.addAll([a, c, b, b, c, d]);
      }
    }
    // Bottom fan.
    final lastRingStart = 1 + (rings - 2) * (segments + 1);
    for (var s = 0; s < segments; s++) {
      final a = lastRingStart + s;
      final b = a + 1;
      indices.addAll([a, bottomPole, b]);
    }

    return GuideSurface(
      type: GuideSurfaceType.sphere,
      mesh: SurfaceMesh(
        positions: positions,
        uvs: uvs,
        indices: indices,
        normals: normals,
      ),
    );
  }

  /// Creates a cylinder guide (closed at both ends) of given dimensions.
  factory GuideSurface.cylinder({
    double radius = 1.0,
    double height = 2.0,
    int segments = 32,
  }) {
    radius = radius.abs();
    height = height.abs();
    final positions = <Vector3>[];
    final uvs = <Vector2>[];
    final normals = <Vector3>[];
    final indices = <int>[];

    final halfH = height * 0.5;

    // Side wall: two rings of vertices.
    for (var r = 0; r < 2; r++) {
      final y = r == 0 ? -halfH : halfH;
      final v = r == 0.0 ? 0.0 : 1.0;
      for (var s = 0; s <= segments; s++) {
        final theta = 2 * math.pi * s / segments;
        final x = radius * math.cos(theta);
        final z = radius * math.sin(theta);
        positions.add(Vector3(x, y, z));
        uvs.add(Vector2(s / segments, v));
        normals.add(Vector3(math.cos(theta), 0, math.sin(theta))..normalize());
      }
    }

    // Side quads.
    for (var s = 0; s < segments; s++) {
      final a = s;
      final b = s + 1;
      final c = s + (segments + 1);
      final d = c + 1;
      indices.addAll([a, c, b, b, c, d]);
    }

    // Caps — center + ring each.
    final topCenter = positions.length;
    positions.add(Vector3(0, halfH, 0));
    uvs.add(Vector2(0.5, 0.5));
    normals.add(Vector3(0, 1, 0));
    final bottomCenter = positions.length;
    positions.add(Vector3(0, -halfH, 0));
    uvs.add(Vector2(0.5, 0.5));
    normals.add(Vector3(0, -1, 0));

    final topRingStart = positions.length;
    for (var s = 0; s <= segments; s++) {
      final theta = 2 * math.pi * s / segments;
      positions.add(Vector3(radius * math.cos(theta), halfH, radius * math.sin(theta)));
      final u = 0.5 + 0.5 * math.cos(theta);
      final v = 0.5 + 0.5 * math.sin(theta);
      uvs.add(Vector2(u, v));
      normals.add(Vector3(0, 1, 0));
    }
    final bottomRingStart = positions.length;
    for (var s = 0; s <= segments; s++) {
      final theta = 2 * math.pi * s / segments;
      positions.add(Vector3(radius * math.cos(theta), -halfH, radius * math.sin(theta)));
      final u = 0.5 + 0.5 * math.cos(theta);
      final v = 0.5 + 0.5 * math.sin(theta);
      uvs.add(Vector2(u, v));
      normals.add(Vector3(0, -1, 0));
    }

    for (var s = 0; s < segments; s++) {
      final a = topRingStart + s;
      final b = topRingStart + s + 1;
      indices.addAll([a, topCenter, b]); // CCW from top
    }
    for (var s = 0; s < segments; s++) {
      final a = bottomRingStart + s;
      final b = bottomRingStart + s + 1;
      indices.addAll([b, bottomCenter, a]); // flipped winding
    }

    return GuideSurface(
      type: GuideSurfaceType.cylinder,
      mesh: SurfaceMesh(
        positions: positions,
        uvs: uvs,
        indices: indices,
        normals: normals,
      ),
    );
  }

  /// Creates a cone guide.
  factory GuideSurface.cone({
    double radius = 1.0,
    double height = 2.0,
    int segments = 32,
  }) {
    radius = radius.abs();
    height = height.abs();
    final positions = <Vector3>[];
    final uvs = <Vector2>[];
    final normals = <Vector3>[];
    final indices = <int>[];

    final halfH = height * 0.5;

    // Apex.
    final apex = 0;
    positions.add(Vector3(0, halfH, 0));
    uvs.add(Vector2(0.5, 0.0));
    normals.add(Vector3(0, 1, 0));

    // Base ring.
    final baseStart = positions.length;
    for (var s = 0; s <= segments; s++) {
      final theta = 2 * math.pi * s / segments;
      final x = radius * math.cos(theta);
      final z = radius * math.sin(theta);
      positions.add(Vector3(x, -halfH, z));
      uvs.add(Vector2(s / segments, 1.0));
      normals.add(Vector3(math.cos(theta), 0.3, math.sin(theta))..normalize());
    }

    // Side triangles from apex to base.
    for (var s = 0; s < segments; s++) {
      final a = baseStart + s;
      final b = baseStart + s + 1;
      indices.addAll([apex, a, b]);
    }

    // Base cap.
    final baseCenter = positions.length;
    positions.add(Vector3(0, -halfH, 0));
    uvs.add(Vector2(0.5, 0.5));
    normals.add(Vector3(0, -1, 0));

    for (var s = 0; s < segments; s++) {
      final a = baseStart + s;
      final b = baseStart + s + 1;
      indices.addAll([b, baseCenter, a]);
    }

    return GuideSurface(
      type: GuideSurfaceType.cone,
      mesh: SurfaceMesh(
        positions: positions,
        uvs: uvs,
        indices: indices,
        normals: normals,
      ),
    );
  }

  /// Creates a torus / ring guide.
  factory GuideSurface.ring({
    double majorRadius = 1.0,
    double minorRadius = 0.25,
    int majorSegments = 32,
    int minorSegments = 12,
  }) {
    majorRadius = majorRadius.abs();
    minorRadius = minorRadius.abs();
    final positions = <Vector3>[];
    final uvs = <Vector2>[];
    final normals = <Vector3>[];
    final indices = <int>[];

    for (var i = 0; i <= majorSegments; i++) {
      final u = i / majorSegments;
      final theta = 2 * math.pi * u;
      final cosT = math.cos(theta);
      final sinT = math.sin(theta);
      for (var j = 0; j <= minorSegments; j++) {
        final v = j / minorSegments;
        final phi = 2 * math.pi * v;
        final cosP = math.cos(phi);
        final sinP = math.sin(phi);
        final r = majorRadius + minorRadius * cosP;
        positions.add(Vector3(r * cosT, minorRadius * sinP, r * sinT));
        uvs.add(Vector2(u, v));
        normals.add(Vector3(cosP * cosT, sinP, cosP * sinT)..normalize());
      }
    }

    for (var i = 0; i < majorSegments; i++) {
      for (var j = 0; j < minorSegments; j++) {
        final a = i * (minorSegments + 1) + j;
        final b = a + 1;
        final c = a + (minorSegments + 1);
        final d = c + 1;
        indices.addAll([a, c, b, b, c, d]);
      }
    }

    return GuideSurface(
      type: GuideSurfaceType.ring,
      mesh: SurfaceMesh(
        positions: positions,
        uvs: uvs,
        indices: indices,
        normals: normals,
      ),
    );
  }

  /// Creates a flat plane guide centered on the origin in the XZ plane.
  factory GuideSurface.plane({
    double size = 2.0,
    int subdivisions = 1,
  }) {
    size = size.abs();
    final positions = <Vector3>[];
    final uvs = <Vector2>[];
    final normals = <Vector3>[];
    final indices = <int>[];

    final half = size * 0.5;
    final step = size / subdivisions;

    for (var j = 0; j <= subdivisions; j++) {
      for (var i = 0; i <= subdivisions; i++) {
        final x = -half + i * step;
        final z = -half + j * step;
        positions.add(Vector3(x, 0, z));
        uvs.add(Vector2(i / subdivisions, j / subdivisions));
        normals.add(Vector3(0, 1, 0));
      }
    }

    final cols = subdivisions + 1;
    for (var j = 0; j < subdivisions; j++) {
      for (var i = 0; i < subdivisions; i++) {
        final a = j * cols + i;
        final b = a + 1;
        final c = a + cols;
        final d = c + 1;
        indices.addAll([a, c, b, b, c, d]);
      }
    }

    return GuideSurface(
      type: GuideSurfaceType.plane,
      mesh: SurfaceMesh(
        positions: positions,
        uvs: uvs,
        indices: indices,
        normals: normals,
      ),
    );
  }

  /// Creates a guide surface that extrudes a circular cross-section along
  /// a Catmull-Rom spline through [controlPoints].
  factory GuideSurface.customCurve({
    required List<SurfaceControlPoint> controlPoints,
    double tubeRadius = 0.15,
    int splineSegments = 64,
    int tubeSegments = 8,
  }) {
    if (controlPoints.length < 2) {
      return GuideSurface.plane();
    }
    tubeRadius = tubeRadius.abs();

    final positions = <Vector3>[];
    final uvs = <Vector2>[];
    final normals = <Vector3>[];
    final indices = <int>[];

    // Sample spline positions + tangents.
    final samples = <Vector3>[];
    final tangents = <Vector3>[];
    final n = controlPoints.length;
    for (var s = 0; s <= splineSegments; s++) {
      final t = s / splineSegments;
      final f = t * (n - 1);
      final i = f.floor().clamp(0, n - 2);
      final local = f - i;
      final p0 = controlPoints[(i - 1).clamp(0, n - 1)].position;
      final p1 = controlPoints[i].position;
      final p2 = controlPoints[(i + 1).clamp(0, n - 1)].position;
      final p3 = controlPoints[(i + 2).clamp(0, n - 1)].position;
      final pos = _catmullRom(p0, p1, p2, p3, local);
      samples.add(pos);
      final tan = _catmullRomTangent(p0, p1, p2, p3, local)..normalize();
      tangents.add(tan);
    }

    // Build frames along the spline (parallel transport).
    var prevNormal = Vector3(0, 1, 0);
    if (prevNormal.dot(tangents[0]).abs() > 0.99) {
      prevNormal = Vector3(1, 0, 0);
    }
    final frames = <List<Vector3>>[];
    for (var s = 0; s < samples.length; s++) {
      final t = tangents[s];
      var n1 = prevNormal - t * prevNormal.dot(t);
      if (n1.length2 < 1e-6) {
        n1 = Vector3(1, 0, 0) - t * Vector3(1, 0, 0).dot(t);
      }
      n1.normalize();
      final n2 = t.cross(n1)..normalize();
      frames.add([t, n1, n2]);
      prevNormal = n1;
    }

    // Generate tube vertices.
    for (var s = 0; s < samples.length; s++) {
      final center = samples[s];
      final frame = frames[s];
      final u = s / (samples.length - 1);
      for (var j = 0; j <= tubeSegments; j++) {
        final v = j / tubeSegments;
        final phi = 2 * math.pi * v;
        final cosP = math.cos(phi);
        final sinP = math.sin(phi);
        final offset = (frame[1] * cosP) + (frame[2] * sinP);
        offset.scale(tubeRadius);
        positions.add(center + offset);
        uvs.add(Vector2(u, v));
        normals.add(offset..normalize());
      }
    }

    // Stitch tube quads.
    for (var s = 0; s < samples.length - 1; s++) {
      for (var j = 0; j < tubeSegments; j++) {
        final a = s * (tubeSegments + 1) + j;
        final b = a + 1;
        final c = a + (tubeSegments + 1);
        final d = c + 1;
        indices.addAll([a, c, b, b, c, d]);
      }
    }

    return GuideSurface(
      type: GuideSurfaceType.customCurve,
      mesh: SurfaceMesh(
        positions: positions,
        uvs: uvs,
        indices: indices,
        normals: normals,
      ),
      controlPoints: controlPoints.map((p) => p.copy()).toList(),
    );
  }

  static Vector3 _catmullRom(
      Vector3 p0, Vector3 p1, Vector3 p2, Vector3 p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    return Vector3(
      0.5 *
          ((2 * p1.x) +
              (-p0.x + p2.x) * t +
              (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
              (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
      0.5 *
          ((2 * p1.y) +
              (-p0.y + p2.y) * t +
              (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
              (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3),
      0.5 *
          ((2 * p1.z) +
              (-p0.z + p2.z) * t +
              (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t2 +
              (-p0.z + 3 * p1.z - 3 * p2.z + p3.z) * t3),
    );
  }

  static Vector3 _catmullRomTangent(
      Vector3 p0, Vector3 p1, Vector3 p2, Vector3 p3, double t) {
    final t2 = t * t;
    return Vector3(
      0.5 *
          ((-p0.x + p2.x) +
              2 * (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t +
              3 * (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t2),
      0.5 *
          ((-p0.y + p2.y) +
              2 * (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t +
              3 * (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t2),
      0.5 *
          ((-p0.z + p2.z) +
              2 * (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t +
              3 * (-p0.z + 3 * p1.z - 3 * p2.z + p3.z) * t2),
    );
  }

  // ----- Raycast --------------------------------------------------------

  /// Casts [ray] (in world space) against this surface.
  ///
  /// Returns the closest hit (smallest positive [SurfaceRayHit.distance]),
  /// or `null` if no triangle is intersected. Uses Möller-Trumbore for
  /// ray-triangle intersection and barycentric interpolation of UVs and
  /// normals.
  SurfaceRayHit? raycast(Ray ray, {double maxDistance = double.infinity}) {
    if (!visible) return null;
    _ensureInverse();

    // Transform the ray into local space — cheaper than transforming every
    // triangle vertex into world space.
    final localOrigin = _inverse.transform3(ray.origin.clone());
    final localDir = _inverse.transform3(ray.direction.clone());
    final localRay = Ray.originDirection(localOrigin, localDir.normalized());

    var bestT = maxDistance;
    var bestTri = -1;
    var bestBary = Vector3.zero();
    for (var i = 0; i < mesh.indices.length; i += 3) {
      final i0 = mesh.indices[i];
      final i1 = mesh.indices[i + 1];
      final i2 = mesh.indices[i + 2];
      final v0 = mesh.positions[i0];
      final v1 = mesh.positions[i1];
      final v2 = mesh.positions[i2];
      final hit = VectorMathUtils.rayTriangle(
        localRay.origin,
        localRay.direction,
        v0,
        v1,
        v2,
      );
      if (hit == null) continue;
      if (hit.t < 1e-6 || hit.t >= bestT) continue;
      bestT = hit.t;
      bestTri = i ~/ 3;
      bestBary = hit.barycentric;
    }
    if (bestTri < 0) return null;

    final i0 = mesh.indices[bestTri * 3];
    final i1 = mesh.indices[bestTri * 3 + 1];
    final i2 = mesh.indices[bestTri * 3 + 2];
    final uv0 = mesh.uvs[i0];
    final uv1 = mesh.uvs[i1];
    final uv2 = mesh.uvs[i2];
    final b = bestBary;
    final uv = Vector2(
      uv0.x * b.x + uv1.x * b.y + uv2.x * b.z,
      uv0.y * b.x + uv1.y * b.y + uv2.y * b.z,
    );

    // Local hit point + normal.
    final localHit = localRay.origin + localRay.direction.scaled(bestT);
    final n0 = mesh.normals[i0];
    final n1 = mesh.normals[i1];
    final n2 = mesh.normals[i2];
    final localNormal = (n0 * b.x + n1 * b.y + n2 * b.z)..normalize();

    // Transform hit point and normal back to world space.
    final worldPoint = transform.transform3(localHit.clone());
    final worldNormal = VectorMathUtils.transformNormal(transform, localNormal)
        .normalized();

    return SurfaceRayHit(
      uv: uv,
      point: worldPoint,
      normal: worldNormal,
      distance: bestT,
      triangleIndex: bestTri,
    );
  }

  /// Samples the surface normal at a UV coordinate by finding the nearest
  /// triangle whose UVs enclose the given point. Returns `null` if the UV
  /// is outside the surface.
  Vector3? normalAtUV(Vector2 uv) {
    for (var i = 0; i < mesh.indices.length; i += 3) {
      final i0 = mesh.indices[i];
      final i1 = mesh.indices[i + 1];
      final i2 = mesh.indices[i + 2];
      final uv0 = mesh.uvs[i0];
      final uv1 = mesh.uvs[i1];
      final uv2 = mesh.uvs[i2];
      final b = VectorMathUtils.barycentric2D(uv, uv0, uv1, uv2);
      if (b == null) continue;
      if (b.x < -1e-6 || b.y < -1e-6 || b.z < -1e-6) continue;
      final n0 = mesh.normals[i0];
      final n1 = mesh.normals[i1];
      final n2 = mesh.normals[i2];
      final localNormal = (n0 * b.x + n1 * b.y + n2 * b.z)..normalize();
      return VectorMathUtils.transformNormal(transform, localNormal)
          .normalized();
    }
    return null;
  }

  // ----- Serialization --------------------------------------------------

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'transform': transform.storage.toList(),
      'color': [color.x, color.y, color.z],
      'visible': visible,
      'locked': locked,
      'controlPoints': controlPoints.map((p) => p.toJson()).toList(),
      // We serialize mesh parameters implicitly via the type so that on
      // load the surface can be regenerated. For non-parametric custom
      // curves we also store the control points above.
    };
  }

  factory GuideSurface.fromJson(Map<String, dynamic> json) {
    final type = GuideSurfaceType.values.firstWhere(
      (t) => t.name == json['type'] as String,
      orElse: () => GuideSurfaceType.plane,
    );
    final controlPoints = (json['controlPoints'] as List? ?? [])
        .map((e) => SurfaceControlPoint.fromJson(e as Map<String, dynamic>))
        .toList();
    final colorList = (json['color'] as List).cast<num>();
    final visible = json['visible'] as bool? ?? true;
    final locked = json['locked'] as bool? ?? false;

    GuideSurface surface;
    switch (type) {
      case GuideSurfaceType.sphere:
        surface = GuideSurface.sphere();
        break;
      case GuideSurfaceType.cylinder:
        surface = GuideSurface.cylinder();
        break;
      case GuideSurfaceType.cone:
        surface = GuideSurface.cone();
        break;
      case GuideSurfaceType.ring:
        surface = GuideSurface.ring();
        break;
      case GuideSurfaceType.plane:
        surface = GuideSurface.plane();
        break;
      case GuideSurfaceType.customCurve:
        surface = controlPoints.isEmpty
            ? GuideSurface.plane()
            : GuideSurface.customCurve(controlPoints: controlPoints);
        break;
    }
    final transformList = (json['transform'] as List).cast<num>();
    surface.transform = Matrix4.fromList(transformList.map((e) => e.toDouble()).toList());
    surface.markTransformDirty();
    surface.color = Vector3(
      colorList[0].toDouble(),
      colorList[1].toDouble(),
      colorList[2].toDouble(),
    );
    surface.visible = visible;
    surface.locked = locked;
    return surface;
  }
}

/// Extension that adds helper methods to [Matrix4] used in this file.
extension Matrix4GuideOps on Matrix4 {
  /// Transforms [normal] by the inverse-transpose of this matrix and
  /// returns the result as a fresh [Vector3]. Safe for non-uniform scaling.
  Vector3 normalTransform(Vector3 normal) {
    return VectorMathUtils.transformNormal(this, normal);
  }
}
