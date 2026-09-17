// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// vector_math_utils.dart — Math utilities for 3D engine.
//
// Provides:
//   - Ray-triangle intersection (Möller-Trumbore).
//   - Barycentric coordinate helpers (2D and 3D).
//   - Quaternion helpers (slerp, look-at, axis extraction).
//   - Matrix4 helpers (compose / decompose, normal transform).
//   - Plane / line intersection helpers.
//
// All functions are stateless and operate on the `vector_math` types so
// they can be used from anywhere in the engine.

import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Result of a ray-triangle intersection.
class RayTriangleHit {
  const RayTriangleHit({
    required this.t,
    required this.barycentric,
    required this.point,
  });

  /// Distance along the ray direction from origin to hit point.
  final double t;

  /// Barycentric coordinates (x = weight for v0, y for v1, z for v2). All
  /// three sum to 1. The hit is inside the triangle when all are >= 0.
  final Vector3 barycentric;

  /// World-space hit point (origin + direction * t).
  final Vector3 point;
}

/// A flat utility class exposing all helpers as static methods.
class VectorMathUtils {
  const VectorMathUtils._();

  // ----- Ray-triangle intersection --------------------------------------

  /// Möller-Trumbore ray-triangle intersection.
  ///
  /// Returns `null` if the ray does not hit the triangle (or hits it
  /// behind the origin). [direction] should be normalized for [hit.t] to
  /// be in world units.
  static RayTriangleHit? rayTriangle(
    Vector3 origin,
    Vector3 direction,
    Vector3 v0,
    Vector3 v1,
    Vector3 v2, {
    double epsilon = 1e-7,
    bool cullBackfaces = false,
  }) {
    final edge1 = v1 - v0;
    final edge2 = v2 - v0;
    final h = direction.cross(edge2);
    final a = edge1.dot(h);
    if (a > -epsilon && a < epsilon) return null; // parallel
    if (cullBackfaces && a < 0) return null;
    final f = 1.0 / a;
    final s = origin - v0;
    final u = f * s.dot(h);
    if (u < 0.0 || u > 1.0) return null;
    final q = s.cross(edge1);
    final v = f * direction.dot(q);
    if (v < 0.0 || u + v > 1.0) return null;
    final t = f * edge2.dot(q);
    if (t < epsilon) return null; // behind origin
    final w = 1.0 - u - v;
    final point = origin + direction * t;
    return RayTriangleHit(
      t: t,
      barycentric: Vector3(w, u, v),
      point: point,
    );
  }

  /// Casts a ray against a triangle mesh (positions + indices) and returns
  /// the closest hit. [indices] is a flat list of vertex indices, three
  /// per triangle.
  static RayTriangleHit? rayMesh(
    Vector3 origin,
    Vector3 direction,
    List<Vector3> positions,
    List<int> indices, {
    double epsilon = 1e-7,
    double maxDistance = double.infinity,
  }) {
    RayTriangleHit? best;
    for (var i = 0; i < indices.length; i += 3) {
      final hit = rayTriangle(
        origin,
        direction,
        positions[indices[i]],
        positions[indices[i + 1]],
        positions[indices[i + 2]],
        epsilon: epsilon,
      );
      if (hit == null) continue;
      if (hit.t >= maxDistance) continue;
      if (best == null || hit.t < best.t) best = hit;
    }
    return best;
  }

  // ----- Barycentric coordinates ----------------------------------------

  /// Computes barycentric coordinates of point [p] inside triangle
  /// [a]-[b]-[c] in 2D. Returns `null` if the triangle is degenerate.
  /// The result components are (alpha, beta, gamma) where
  ///   p = alpha*a + beta*b + gamma*c
  /// and alpha + beta + gamma = 1.
  static Vector3? barycentric2D(Vector2 p, Vector2 a, Vector2 b, Vector2 c) {
    final v0 = b - a;
    final v1 = c - a;
    final v2 = p - a;
    final d00 = v0.dot(v0);
    final d01 = v0.dot(v1);
    final d11 = v1.dot(v1);
    final d20 = v2.dot(v0);
    final d21 = v2.dot(v1);
    final denom = d00 * d11 - d01 * d01;
    if (denom.abs() < 1e-12) return null;
    final invDenom = 1.0 / denom;
    final v = (d11 * d20 - d01 * d21) * invDenom;
    final w = (d00 * d21 - d01 * d20) * invDenom;
    final u = 1.0 - v - w;
    return Vector3(u, v, w);
  }

  /// Computes barycentric coordinates in 3D using the projection trick.
  /// Returns `null` if the triangle is degenerate.
  static Vector3? barycentric3D(Vector3 p, Vector3 a, Vector3 b, Vector3 c) {
    final v0 = b - a;
    final v1 = c - a;
    final v2 = p - a;
    final d00 = v0.dot(v0);
    final d01 = v0.dot(v1);
    final d11 = v1.dot(v1);
    final d20 = v2.dot(v0);
    final d21 = v2.dot(v1);
    final denom = d00 * d11 - d01 * d01;
    if (denom.abs() < 1e-12) return null;
    final invDenom = 1.0 / denom;
    final v = (d11 * d20 - d01 * d21) * invDenom;
    final w = (d00 * d21 - d01 * d20) * invDenom;
    final u = 1.0 - v - w;
    return Vector3(u, v, w);
  }

  /// Linearly interpolates between two UV coordinates using barycentric
  /// weights.
  static Vector2 interpolateUV(
          Vector2 uv0, Vector2 uv1, Vector2 uv2, Vector3 bary) =>
      Vector2(
        uv0.x * bary.x + uv1.x * bary.y + uv2.x * bary.z,
        uv0.y * bary.x + uv1.y * bary.y + uv2.y * bary.z,
      );

  /// Linearly interpolates between three Vector3 using barycentric weights.
  static Vector3 interpolateVector3(
          Vector3 v0, Vector3 v1, Vector3 v2, Vector3 bary) =>
      v0 * bary.x + v1 * bary.y + v2 * bary.z;

  // ----- Quaternion helpers ---------------------------------------------

  /// Spherical linear interpolation between two quaternions.
  static Quaternion slerp(Quaternion a, Quaternion b, double t) {
    final result = Quaternion.identity();
    final copy = a.clone();
    var dot = copy.x * b.x + copy.y * b.y + copy.z * b.z + copy.w * b.w;
    if (dot < 0) {
      copy
        ..x = -copy.x
        ..y = -copy.y
        ..z = -copy.z
        ..w = -copy.w;
      dot = -dot;
    }
    const threshold = 0.9995;
    if (dot > threshold) {
      // Linear interpolation when very close.
      result
        ..x = copy.x + (b.x - copy.x) * t
        ..y = copy.y + (b.y - copy.y) * t
        ..z = copy.z + (b.z - copy.z) * t
        ..w = copy.w + (b.w - copy.w) * t;
      return result..normalize();
    }
    final theta0 = math.acos(dot.clamp(-1.0, 1.0));
    final theta = theta0 * t;
    final sinTheta = math.sin(theta);
    final sinTheta0 = math.sin(theta0);
    final s0 = math.cos(theta) - dot * sinTheta / sinTheta0;
    final s1 = sinTheta / sinTheta0;
    result
      ..x = s0 * copy.x + s1 * b.x
      ..y = s0 * copy.y + s1 * b.y
      ..z = s0 * copy.z + s1 * b.z
      ..w = s0 * copy.w + s1 * b.w;
    return result;
  }

  /// Builds a quaternion that rotates [from] to align with [to]. Both
  /// vectors should be normalized.
  static Quaternion fromToRotation(Vector3 from, Vector3 to) {
    final f = from.normalized();
    final t = to.normalized();
    final dot = f.dot(t);
    if (dot > 0.999999) {
      return Quaternion.identity();
    }
    if (dot < -0.999999) {
      // 180° rotation around any perpendicular axis.
      var axis = Vector3(1, 0, 0).cross(f);
      if (axis.length2 < 1e-6) {
        axis = Vector3(0, 1, 0).cross(f);
      }
      axis.normalize();
      return Quaternion.axisAngle(axis, math.pi);
    }
    final axis = f.cross(t);
    final angle = math.acos(dot.clamp(-1.0, 1.0));
    return Quaternion.axisAngle(axis.normalized(), angle);
  }

  /// Builds a "look rotation" — rotation that points the local +Z axis
  /// toward [forward] and orients +Y toward [up].
  static Quaternion lookRotation(Vector3 forward, Vector3 up) {
    final f = forward.normalized();
    var u = up.normalized();
    final right = u.cross(f);
    if (right.length2 < 1e-6) {
      u = (f.x.abs() > 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0));
    }
    final r = u.cross(f).normalized();
    final newUp = f.cross(r).normalized();
    final m = Matrix3(
      r.x, newUp.x, f.x, // column 0
      r.y, newUp.y, f.y, // column 1
      r.z, newUp.z, f.z, // column 2
    );
    return Quaternion.fromRotation(m);
  }

  /// Extracts the axis-angle representation of a quaternion.
  static (Vector3 axis, double angle) toAxisAngle(Quaternion q) {
    final w = q.w.clamp(-1.0, 1.0);
    final angle = 2 * math.acos(w);
    final s = math.sqrt(1 - w * w);
    if (s < 1e-6) {
      return (Vector3(1, 0, 0), 0);
    }
    return (Vector3(q.x / s, q.y / s, q.z / s), angle);
  }

  // ----- Matrix4 helpers ------------------------------------------------

  /// Composes a [Matrix4] from translation, rotation, and scale.
  static Matrix4 compose(
      Vector3 translation, Quaternion rotation, Vector3 scale) {
    final m = rotation.asRotationMatrix();
    final out = Matrix4.zero();
    out.setValues(
      m.entry(0, 0) * scale.x, m.entry(1, 0) * scale.y, m.entry(2, 0) * scale.z,
      0,
      m.entry(0, 1) * scale.x, m.entry(1, 1) * scale.y, m.entry(2, 1) * scale.z,
      0,
      m.entry(0, 2) * scale.x, m.entry(1, 2) * scale.y, m.entry(2, 2) * scale.z,
      0,
      translation.x, translation.y, translation.z, 1,
    );
    return out;
  }

  /// Converts a [Matrix3] (rotation-only) into a [Matrix4] with identity
  /// translation and no scale.
  static Matrix4 matrix3ToMatrix4(Matrix3 m) {
    return Matrix4(
      m.entry(0, 0), m.entry(1, 0), m.entry(2, 0), 0, // column 0
      m.entry(0, 1), m.entry(1, 1), m.entry(2, 1), 0, // column 1
      m.entry(0, 2), m.entry(1, 2), m.entry(2, 2), 0, // column 2
      0, 0, 0, 1, // column 3 (translation)
    );
  }

  /// Decomposes a [Matrix4] into translation, rotation, and scale.
  ///
  /// Returns a record (translation, rotation, scale).
  static (Vector3 translation, Quaternion rotation, Vector3 scale) decompose(
      Matrix4 m) {
    final translation = m.getTranslation();
    final sx = Vector3(m.entry(0, 0), m.entry(1, 0), m.entry(2, 0)).length;
    final sy = Vector3(m.entry(0, 1), m.entry(1, 1), m.entry(2, 1)).length;
    final sz = Vector3(m.entry(0, 2), m.entry(1, 2), m.entry(2, 2)).length;
    final rotationMatrix = Matrix3(
      m.entry(0, 0) / sx, m.entry(1, 0) / sx, m.entry(2, 0) / sx, // col 0
      m.entry(0, 1) / sy, m.entry(1, 1) / sy, m.entry(2, 1) / sy, // col 1
      m.entry(0, 2) / sz, m.entry(1, 2) / sz, m.entry(2, 2) / sz, // col 2
    );
    final rotation = Quaternion.fromRotation(rotationMatrix);
    return (translation, rotation, Vector3(sx, sy, sz));
  }

  /// Transforms a normal by the inverse-transpose of [matrix]. Safe for
  /// non-uniform scaling. Returns a fresh [Vector3].
  static Vector3 transformNormal(Matrix4 matrix, Vector3 normal) {
    final inv = Matrix4.inverted(matrix);
    // Multiply by inverse-transpose for direction (ignore translation).
    final x = normal.x;
    final y = normal.y;
    final z = normal.z;
    final nx = inv.entry(0, 0) * x + inv.entry(1, 0) * y + inv.entry(2, 0) * z;
    final ny = inv.entry(0, 1) * x + inv.entry(1, 1) * y + inv.entry(2, 1) * z;
    final nz = inv.entry(0, 2) * x + inv.entry(1, 2) * y + inv.entry(2, 2) * z;
    return Vector3(nx, ny, nz);
  }

  // ----- Plane / line helpers -------------------------------------------

  /// Intersects a ray with a plane defined by [point] and [normal].
  /// Returns the intersection parameter t (such that hit = origin +
  /// direction * t), or `null` if the ray is parallel to the plane.
  static double? rayPlane(
    Vector3 origin,
    Vector3 direction,
    Vector3 point,
    Vector3 normal, {
    double epsilon = 1e-7,
  }) {
    final denom = direction.dot(normal);
    if (denom.abs() < epsilon) return null;
    final t = (point - origin).dot(normal) / denom;
    return t;
  }

  /// Intersects a ray with a sphere of [center] and [radius]. Returns the
  /// nearest positive t, or `null` if no intersection.
  static double? raySphere(
    Vector3 origin,
    Vector3 direction,
    Vector3 center,
    double radius, {
    double epsilon = 1e-7,
  }) {
    final oc = origin - center;
    final a = direction.dot(direction);
    final b = 2 * oc.dot(direction);
    final c = oc.dot(oc) - radius * radius;
    final disc = b * b - 4 * a * c;
    if (disc < 0) return null;
    final sq = math.sqrt(disc);
    final t1 = (-b - sq) / (2 * a);
    final t2 = (-b + sq) / (2 * a);
    if (t1 > epsilon) return t1;
    if (t2 > epsilon) return t2;
    return null;
  }

  /// Intersects a ray with an axis-aligned bounding box. Returns the
  /// nearest positive t, or `null` if no intersection. Uses the slab
  /// method.
  static double? rayAabb(
    Vector3 origin,
    Vector3 direction,
    Aabb3 box, {
    double epsilon = 1e-7,
  }) {
    var tmin = double.negativeInfinity;
    var tmax = double.infinity;
    final min = box.min;
    final max = box.max;

    for (var i = 0; i < 3; i++) {
      final o = i == 0 ? origin.x : (i == 1 ? origin.y : origin.z);
      final d = i == 0 ? direction.x : (i == 1 ? direction.y : direction.z);
      final lo = i == 0 ? min.x : (i == 1 ? min.y : min.z);
      final hi = i == 0 ? max.x : (i == 1 ? max.y : max.z);
      if (d.abs() < epsilon) {
        if (o < lo || o > hi) return null;
        continue;
      }
      var t1 = (lo - o) / d;
      var t2 = (hi - o) / d;
      if (t1 > t2) {
        final tmp = t1;
        t1 = t2;
        t2 = tmp;
      }
      if (t1 > tmin) tmin = t1;
      if (t2 < tmax) tmax = t2;
      if (tmin > tmax) return null;
    }
    if (tmax < epsilon) return null;
    return tmin > epsilon ? tmin : tmax;
  }

  // ----- Misc geometry helpers ------------------------------------------

  /// Returns the shortest distance from point [p] to the line segment
  /// [a]-[b]. Also returns the closest point on the segment.
  static (double distance, Vector3 closest) pointSegment(
      Vector3 p, Vector3 a, Vector3 b) {
    final ab = b - a;
    final length2 = ab.length2;
    if (length2 < 1e-12) {
      final d = (p - a).length;
      return (d, a.clone());
    }
    final t = ((p - a).dot(ab) / length2).clamp(0.0, 1.0);
    final closest = a + ab * t;
    final distance = (p - closest).length;
    return (distance, closest);
  }

  /// Computes the area of a triangle in 3D space.
  static double triangleArea(Vector3 a, Vector3 b, Vector3 c) {
    final ab = b - a;
    final ac = c - a;
    return 0.5 * ab.cross(ac).length;
  }

  /// Computes the normal of a triangle (CCW winding).
  static Vector3 triangleNormal(Vector3 a, Vector3 b, Vector3 c) {
    final ab = b - a;
    final ac = c - a;
    return ab.cross(ac)..normalize();
  }

  /// Builds a perspective projection matrix.
  static Matrix4 perspective(
      double fovYRadians, double aspect, double near, double far) {
    return makeViewMatrix(fovYRadians, aspect, near, far);
  }

  /// Builds a perspective projection matrix.
  static Matrix4 makeViewMatrix(
      double fovYRadians, double aspect, double near, double far) {
    final f = 1.0 / math.tan(fovYRadians * 0.5);
    final nf = 1.0 / (near - far);
    final m = Matrix4.zero();
    m.setValues(
      f / aspect, 0, 0, 0,
      0, f, 0, 0,
      0, 0, (far + near) * nf, -1,
      0, 0, 2 * far * near * nf, 0,
    );
    return m;
  }

  /// Builds a view matrix looking from [eye] to [target] with up vector [up].
  static Matrix4 lookAt(Vector3 eye, Vector3 target, Vector3 up) {
    final f = (target - eye)..normalize();
    final s = f.cross(up.normalized())..normalize();
    final u = s.cross(f);
    final m = Matrix4.zero();
    m.setValues(
      s.x, u.x, -f.x, 0,
      s.y, u.y, -f.y, 0,
      s.z, u.z, -f.z, 0,
      -s.dot(eye), -u.dot(eye), f.dot(eye), 1,
    );
    return m;
  }

  /// Projects a world-space point to NDC using a combined view-projection
  /// matrix. Returns a Vector3 with (x, y, z) where x,y are in [-1, 1] and
  /// z is the depth value.
  static Vector3 projectToNdc(Vector3 point, Matrix4 viewProjection) {
    final v = viewProjection.transform3(point.clone());
    return v;
  }

  /// Unprojects a screen-space point (in pixels) into a world-space ray.
  ///
  /// [screenX] / [screenY] are pixel coordinates with origin at top-left.
  /// [viewportWidth] / [viewportHeight] are the viewport size in pixels.
  /// [viewProjection] is the combined view-projection matrix.
  /// Returns a [Ray] in world space.
  static Ray unprojectScreen(
    double screenX,
    double screenY,
    double viewportWidth,
    double viewportHeight,
    Matrix4 viewProjection,
  ) {
    // Normalize to [-1, 1], flip Y.
    final ndcX = (2.0 * screenX / viewportWidth) - 1.0;
    final ndcY = 1.0 - (2.0 * screenY / viewportHeight);
    final inv = Matrix4.inverted(viewProjection);
    // Near and far points in world space.
    final near = inv.transform3(Vector3(ndcX, ndcY, -1.0));
    final far = inv.transform3(Vector3(ndcX, ndcY, 1.0));
    final direction = (far - near)..normalize();
    return Ray.originDirection(near, direction);
  }

  // ----- Color helpers --------------------------------------------------

  /// Linearly interpolates between two ARGB-packed colors.
  static int lerpColor(int a, int b, double t) {
    final ar = (a >> 24) & 0xff;
    final ag = (a >> 16) & 0xff;
    final ab2 = (a >> 8) & 0xff;
    final aa = a & 0xff;
    final br = (b >> 24) & 0xff;
    final bg = (b >> 16) & 0xff;
    final bb2 = (b >> 8) & 0xff;
    final ba = b & 0xff;
    final r = (ar + (br - ar) * t).round().clamp(0, 255);
    final g = (ag + (bg - ag) * t).round().clamp(0, 255);
    final bl = (ab2 + (bb2 - ab2) * t).round().clamp(0, 255);
    final al = (aa + (ba - aa) * t).round().clamp(0, 255);
    return (r << 24) | (g << 16) | (bl << 8) | al;
  }
}

/// Extension adding convenience methods to [Vector3].
extension Vector3Utils on Vector3 {
  /// Returns a copy with all components clamped to [min]-[max].
  Vector3 clamped(double min, double max) => Vector3(
        x.clamp(min, max).toDouble(),
        y.clamp(min, max).toDouble(),
        z.clamp(min, max).toDouble(),
      );

  /// Returns the angle (in radians) to [other].
  double angleTo(Vector3 other) {
    final d = normalized().dot(other.normalized());
    return math.acos(d.clamp(-1.0, 1.0));
  }
}

/// Extension adding convenience methods to [Matrix4].
extension Matrix4Utils on Matrix4 {
  /// Returns a copy of this matrix with the translation removed.
  Matrix4 withoutTranslation() {
    final out = clone();
    out.setTranslation(Vector3.zero());
    return out;
  }

  /// Returns the position (translation) component as a [Vector3].
  Vector3 get position => getTranslation();
}
