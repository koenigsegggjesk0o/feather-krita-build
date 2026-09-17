// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// stroke.dart — 3D stroke model.
//
// A stroke is the fundamental artistic object in Feather-Krita: a list of
// [StrokePoint]s in 3D space, each carrying pressure / tilt / timing data,
// drawn with a particular [brushType], color, and thickness.
//
// A [Stroke] also owns a local [Matrix4] transform that is applied to all
// of its points. The point positions are stored in local space and only
// converted to world space when needed (e.g. for rendering or raycasts).
//
// Both classes serialize to JSON for save / load and undo / redo.

import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/utils/vector_math_utils.dart';

/// One sample on a 3D stroke.
class StrokePoint {
  StrokePoint({
    required this.position,
    this.pressure = 0.5,
    Vector2? tilt,
    this.time = 0.0,
  }) : tilt = tilt ?? Vector2.zero();

  /// Position in stroke-local space.
  Vector3 position;

  /// Normalized stylus pressure in [0, 1].
  double pressure;

  /// Stylus tilt in degrees. X = tilt-x, Y = tilt-y.
  Vector2 tilt;

  /// Time in seconds since the start of the stroke.
  double time;

  /// Linearly interpolates between this point and [other] by [t].
  StrokePoint lerp(StrokePoint other, double t) => StrokePoint(
        position: position * (1 - t) + other.position * t,
        pressure: pressure * (1 - t) + other.pressure * t,
        tilt: tilt * (1 - t) + other.tilt * t,
        time: time * (1 - t) + other.time * t,
      );

  /// Returns a deep copy of this point.
  StrokePoint copy() => StrokePoint(
        position: position.clone(),
        pressure: pressure,
        tilt: tilt.clone(),
        time: time,
      );

  /// Returns a copy with optional field overrides.
  StrokePoint copyWith({
    Vector3? position,
    double? pressure,
    Vector2? tilt,
    double? time,
  }) =>
      StrokePoint(
        position: position ?? this.position.clone(),
        pressure: pressure ?? this.pressure,
        tilt: tilt ?? this.tilt.clone(),
        time: time ?? this.time,
      );

  Map<String, dynamic> toJson() => {
        'x': position.x,
        'y': position.y,
        'z': position.z,
        'p': pressure,
        'tx': tilt.x,
        'ty': tilt.y,
        't': time,
      };

  factory StrokePoint.fromJson(Map<String, dynamic> json) {
    return StrokePoint(
      position: Vector3(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        (json['z'] as num).toDouble(),
      ),
      pressure: (json['p'] as num?)?.toDouble() ?? 0.5,
      tilt: Vector2(
        (json['tx'] as num?)?.toDouble() ?? 0.0,
        (json['ty'] as num?)?.toDouble() ?? 0.0,
      ),
      time: (json['t'] as num?)?.toDouble() ?? 0.0,
    );
  }

  @override
  String toString() =>
      'StrokePoint(pos=$position, p=$pressure, tilt=$tilt, t=$time)';
}

/// Catalog of built-in brush types. Each value maps to a Krita paintop ID
/// in the engine layer.
enum BrushType {
  basic,
  pencil,
  airbrush,
  marker,
  watercolor,
  ink,
  eraser,
  smudge,
  spray,
  custom,
}

/// Returns the Krita paintop ID for [type].
String brushTypePaintopId(BrushType type) {
  switch (type) {
    case BrushType.basic:
      return 'basic';
    case BrushType.pencil:
      return 'pencil';
    case BrushType.airbrush:
      return 'airbrush';
    case BrushType.marker:
      return 'marker';
    case BrushType.watercolor:
      return 'colorsmudge';
    case BrushType.ink:
      return 'ink';
    case BrushType.eraser:
      return 'eraser';
    case BrushType.smudge:
      return 'colorsmudge';
    case BrushType.spray:
      return 'spray';
    case BrushType.custom:
      return 'custom';
  }
}

/// Parses a [BrushType] from a name string.
BrushType brushTypeFromName(String? name) {
  switch (name) {
    case 'basic':
      return BrushType.basic;
    case 'pencil':
      return BrushType.pencil;
    case 'airbrush':
      return BrushType.airbrush;
    case 'marker':
      return BrushType.marker;
    case 'watercolor':
      return BrushType.watercolor;
    case 'ink':
      return BrushType.ink;
    case 'eraser':
      return BrushType.eraser;
    case 'smudge':
      return BrushType.smudge;
    case 'spray':
      return BrushType.spray;
    case 'custom':
      return BrushType.custom;
    default:
      return BrushType.basic;
  }
}

/// Returns the name for a [BrushType].
String brushTypeName(BrushType type) {
  switch (type) {
    case BrushType.basic:
      return 'basic';
    case BrushType.pencil:
      return 'pencil';
    case BrushType.airbrush:
      return 'airbrush';
    case BrushType.marker:
      return 'marker';
    case BrushType.watercolor:
      return 'watercolor';
    case BrushType.ink:
      return 'ink';
    case BrushType.eraser:
      return 'eraser';
    case BrushType.smudge:
      return 'smudge';
    case BrushType.spray:
      return 'spray';
    case BrushType.custom:
      return 'custom';
  }
}

/// A 3D stroke.
///
/// Points are stored in stroke-local space. The [transform] matrix maps
/// local → world. This lets transforms (move / rotate / scale) be applied
/// to whole strokes efficiently without mutating individual points.
class Stroke {
  Stroke({
    this.id = 0,
    this.brushType = BrushType.basic,
    this.color = 0xFF000000,
    this.thickness = 8.0,
    List<StrokePoint>? points,
    this.isVisible = true,
    this.name,
    Matrix4? transform,
    this.mirrorOfId,
  })  : points = points ?? <StrokePoint>[],
        transform = transform ?? Matrix4.identity();

  /// Document-unique ID. 0 means "not yet assigned".
  int id;

  /// Which brush type was used to draw this stroke.
  BrushType brushType;

  /// ARGB packed color (0xAARRGGBB).
  int color;

  /// Maximum stroke thickness in pixels (at full pressure).
  double thickness;

  /// Sample points along the stroke (local space).
  final List<StrokePoint> points;

  /// Whether the stroke is rendered.
  bool isVisible;

  /// Optional human-readable name.
  String? name;

  /// Local-to-world transform applied to all points.
  Matrix4 transform;

  /// If this stroke is a mirror copy, the ID of the original. `null`
  /// otherwise.
  int? mirrorOfId;

  /// Number of points in the stroke.
  int get length => points.length;

  /// True if the stroke has no points.
  bool get isEmpty => points.isEmpty;

  /// True if the stroke has at least one point.
  bool get isNotEmpty => points.isNotEmpty;

  /// Returns the world-space position of [index].
  Vector3 worldPosition(int index) =>
      transform.transform3(points[index].position.clone());

  /// Returns the world-space centroid of the stroke.
  Vector3 worldCenter() {
    if (points.isEmpty) return Vector3.zero();
    final sum = Vector3.zero();
    for (final p in points) {
      sum.add(transform.transform3(p.position.clone()));
    }
    return sum..scale(1.0 / points.length);
  }

  /// Returns the world-space axis-aligned bounding box.
  Aabb3 worldBounds() {
    final out = Aabb3();
    for (final p in points) {
      out.hullPoint(transform.transform3(p.position.clone()));
    }
    return out;
  }

  // ----- Transform helpers -----------------------------------------------

  /// Translates the stroke by [delta] in world space.
  void applyTranslation(Vector3 delta) {
    final m = Matrix4.identity()..setTranslation(delta);
    transform = m * transform;
  }

  /// Rotates the stroke by [rotation] around [pivot] (world space).
  void applyRotation(Quaternion rotation, {Vector3? pivot}) {
    final p = pivot ?? worldCenter();
    final toOrigin = Matrix4.identity()..setTranslation(-p);
    final rotMat = VectorMathUtils.matrix3ToMatrix4(rotation.asRotationMatrix());
    final fromOrigin = Matrix4.identity()..setTranslation(p);
    transform = fromOrigin * rotMat * toOrigin * transform;
  }

  /// Uniformly scales the stroke by [factor] around [pivot].
  void applyScale(double factor, {Vector3? pivot}) {
    final p = pivot ?? worldCenter();
    final toOrigin = Matrix4.identity()..setTranslation(-p);
    final scaleMat = Matrix4.identity()..scale(factor);
    final fromOrigin = Matrix4.identity()..setTranslation(p);
    transform = fromOrigin * scaleMat * toOrigin * transform;
    thickness *= factor;
  }

  /// Bakes the current [transform] into the point positions and resets
  /// [transform] to identity. Useful for liquify operations that need
  /// canonical world-space positions.
  void bakeTransform() {
    if (transform.isIdentity()) return;
    for (final p in points) {
      p.position = transform.transform3(p.position.clone());
    }
    transform = Matrix4.identity();
  }

  /// Returns a mirrored copy of this stroke. [sign] is a vector with
  /// components +/-1 indicating which axes to flip around [origin].
  ///
  /// The mirrored transform is `T(origin) * S(sign) * T(-origin) * this.transform`,
  /// which moves the world-space mirror origin to (0,0,0), applies the
  /// sign-flip scale, then moves the mirror origin back, and finally
  /// composes the original stroke transform.
  Stroke mirrored(Vector3 origin, Vector3 sign) {
    final sx = sign.x == 0 ? 1.0 : sign.x;
    final sy = sign.y == 0 ? 1.0 : sign.y;
    final sz = sign.z == 0 ? 1.0 : sign.z;
    final toOrigin = Matrix4.identity()..setTranslation(-origin);
    final scaleMat = Matrix4.identity()..scale(sx, sy, sz);
    final fromOrigin = Matrix4.identity()..setTranslation(origin);
    final newTransform = fromOrigin * scaleMat * toOrigin * transform;

    return Stroke(
      brushType: brushType,
      color: color,
      thickness: thickness,
      points: points.map((p) => p.copy()).toList(),
      isVisible: isVisible,
      name: name,
      transform: newTransform,
    );
  }

  /// Returns a deep copy of this stroke.
  Stroke copy() => Stroke(
        id: id,
        brushType: brushType,
        color: color,
        thickness: thickness,
        points: points.map((p) => p.copy()).toList(),
        isVisible: isVisible,
        name: name,
        transform: transform.clone(),
        mirrorOfId: mirrorOfId,
      );

  // ----- Serialization ---------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'brushType': brushTypeName(brushType),
        'color': color,
        'thickness': thickness,
        'points': points.map((p) => p.toJson()).toList(),
        'isVisible': isVisible,
        'name': name,
        'transform': transform.storage.toList(),
        'mirrorOfId': mirrorOfId,
      };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final transformList = (json['transform'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        Matrix4.identity().storage.toList();
    return Stroke(
      id: (json['id'] as num?)?.toInt() ?? 0,
      brushType: brushTypeFromName(json['brushType'] as String?),
      color: (json['color'] as num?)?.toInt() ?? 0xFF000000,
      thickness: (json['thickness'] as num?)?.toDouble() ?? 8.0,
      points: ((json['points'] as List?) ?? [])
          .map((e) => StrokePoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      isVisible: json['isVisible'] as bool? ?? true,
      name: json['name'] as String?,
      transform: Matrix4.fromList(transformList),
      mirrorOfId: (json['mirrorOfId'] as num?)?.toInt(),
    );
  }

  @override
  String toString() =>
      'Stroke(id=$id, brush=$brushType, points=${points.length}, visible=$isVisible)';
}

/// A simple ARGB color helper for strokes.
class StrokeColor {
  const StrokeColor(this.r, this.g, this.b, [this.a = 255]);

  final int a;
  final int r;
  final int g;
  final int b;

  int get packed => (a << 24) | (r << 16) | (g << 8) | b;

  static StrokeColor fromPacked(int packed) => StrokeColor(
        (packed >> 16) & 0xff,
        (packed >> 8) & 0xff,
        packed & 0xff,
        (packed >> 24) & 0xff,
      );

  static const StrokeColor black = StrokeColor(0, 0, 0);
  static const StrokeColor white = StrokeColor(255, 255, 255);
  static const StrokeColor red = StrokeColor(255, 0, 0);
  static const StrokeColor green = StrokeColor(0, 255, 0);
  static const StrokeColor blue = StrokeColor(0, 0, 255);
}
