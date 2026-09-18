// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// stroke_manager.dart — 3D stroke management with Liquify + Mirror.
//
// Owns the document's list of [Stroke] objects and exposes high-level
// operations used by the editor:
//   - Add / select / delete strokes.
//   - Move / rotate / scale strokes (joystick-driven transforms).
//   - 3D Liquify: push, pull, twist, inflate, deflate, smooth.
//   - Live mirror across X / Y / Z planes.
//   - Undo / redo up to 50 levels.
//
// State changes are emitted via [notifyListeners] (ChangeNotifier).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/models/stroke.dart';

/// Liquify deformation modes supported by [StrokeManager.applyLiquify].
enum LiquifyMode {
  /// Move points away from the input direction.
  push,

  /// Move points toward the input direction (opposite of push).
  pull,

  /// Rotate points around the input axis.
  twist,

  /// Move points outward from a center point.
  inflate,

  /// Move points inward toward a center point.
  deflate,

  /// Laplacian-like smoothing of point positions.
  smooth,
}

/// Joystick-driven transform modes.
enum TransformMode {
  move,
  rotate,
  scale,
}

/// A pending live-mirror configuration. When [enabledX/Y/Z] are true, any
/// transform applied to a stroke is also mirrored across the corresponding
/// plane at [origin].
class MirrorConfig {
  MirrorConfig({
    this.enabledX = false,
    this.enabledY = false,
    this.enabledZ = false,
    Vector3? origin,
  }) : origin = origin ?? Vector3.zero();

  bool enabledX;
  bool enabledY;
  bool enabledZ;
  Vector3 origin;

  bool get anyEnabled => enabledX || enabledY || enabledZ;

  /// Returns the list of mirror sign vectors (excluding the identity) that
  /// are active. Each entry is a Vector3 with components +/-1 used to
  /// negate the corresponding axes.
  List<Vector3> activeMirrors() {
    final out = <Vector3>[];
    // We generate the cartesian product of enabled axes.
    final xs = enabledX ? [1.0, -1.0] : [1.0];
    final ys = enabledY ? [1.0, -1.0] : [1.0];
    final zs = enabledZ ? [1.0, -1.0] : [1.0];
    for (final x in xs) {
      for (final y in ys) {
        for (final z in zs) {
          if (x == 1.0 && y == 1.0 && z == 1.0) continue;
          out.add(Vector3(x, y, z));
        }
      }
    }
    return out;
  }

  MirrorConfig copy() => MirrorConfig(
        enabledX: enabledX,
        enabledY: enabledY,
        enabledZ: enabledZ,
        origin: origin.clone(),
      );

  Map<String, dynamic> toJson() => {
        'x': enabledX,
        'y': enabledY,
        'z': enabledZ,
        'origin': [origin.x, origin.y, origin.z],
      };

  factory MirrorConfig.fromJson(Map<String, dynamic> json) => MirrorConfig(
        enabledX: json['x'] as bool? ?? false,
        enabledY: json['y'] as bool? ?? false,
        enabledZ: json['z'] as bool? ?? false,
        origin: Vector3(
          (json['origin'] as List?)?[0] as double? ?? 0.0,
          (json['origin'] as List?)?[1] as double? ?? 0.0,
          (json['origin'] as List?)?[2] as double? ?? 0.0,
        ),
      );
}

/// Manages a list of [Stroke] objects plus selection, transforms, liquify,
/// mirror, and undo/redo.
class StrokeManager extends ChangeNotifier {
  StrokeManager({this.maxUndoLevels = 50});

  final int maxUndoLevels;

  final List<Stroke> _strokes = <Stroke>[];
  final Set<int> _selectedIds = <int>{};
  final List<String> _undoStack = <String>[];
  final List<String> _redoStack = <String>[];

  MirrorConfig _mirror = MirrorConfig();
  int _nextId = 1;
  int _activeBrushIndex = 0;

  /// Fired at the start of every recordable mutation ([_pushUndo]). The
  /// unified undo journal ([EditorState], loop-20) hooks this to capture
  /// the pre-operation state; when set, the manager skips its own
  /// internal undo/redo stacks to avoid double bookkeeping. Direct
  /// [StrokeManager] users (engine tests) that never set the hook keep
  /// the classic manager-owned history.
  void Function()? onBeforeMutate;

  /// The active mirror configuration. Mutating it directly does not push
  /// an undo entry; call [setMirror] to record history.
  MirrorConfig get mirror => _mirror;

  /// Read-only view of all strokes.
  List<Stroke> get strokes => List.unmodifiable(_strokes);

  /// IDs of currently selected strokes.
  Set<int> get selectedIds => Set<int>.unmodifiable(_selectedIds);

  /// All selected stroke objects (in document order).
  List<Stroke> get selectedStrokes =>
      _strokes.where((s) => _selectedIds.contains(s.id)).toList(growable: false);

  /// Number of strokes (including invisible ones).
  int get strokeCount => _strokes.length;

  /// Index of the brush currently active for new strokes (UI hint).
  int get activeBrushIndex => _activeBrushIndex;

  set activeBrushIndex(int value) {
    if (_activeBrushIndex != value) {
      _activeBrushIndex = value;
      notifyListeners();
    }
  }

  /// Public hook that re-broadcasts the current state to listeners. Use this
  /// after mutating a [Stroke] field directly (e.g. toggling visibility)
  /// so the UI rebuilds.
  void notify() => notifyListeners();

  /// True if there is at least one undo entry available.
  bool get canUndo => _undoStack.isNotEmpty;

  /// True if there is at least one redo entry available.
  bool get canRedo => _redoStack.isNotEmpty;

  // ----- Stroke lifecycle ------------------------------------------------

  /// Adds [stroke] to the document and assigns it a fresh ID. If [stroke]
  /// already has an ID, that ID is preserved unless it collides with an
  /// existing stroke — in which case a new one is allocated.
  ///
  /// When mirror is enabled, mirror copies are also inserted.
  Stroke addStroke(Stroke stroke, {bool recordUndo = true}) {
    if (recordUndo) _pushUndo();
    if (stroke.id <= 0 || _strokes.any((s) => s.id == stroke.id)) {
      stroke.id = _nextId++;
    } else if (stroke.id >= _nextId) {
      _nextId = stroke.id + 1;
    }
    _strokes.add(stroke);

    // Mirror copies — these get their own IDs but track the original via
    // mirrorOfId. Their transforms are kept in sync by the transform
    // methods below.
    if (_mirror.anyEnabled) {
      for (final sign in _mirror.activeMirrors()) {
        final mirrored = stroke.mirrored(_mirror.origin, sign);
        mirrored.id = _nextId++;
        mirrored.mirrorOfId = stroke.id;
        _strokes.add(mirrored);
      }
    }

    notifyListeners();
    return stroke;
  }

  /// Removes a stroke by ID. Mirror copies are removed too.
  void removeStroke(int id, {bool recordUndo = true}) {
    if (!_strokes.any((s) => s.id == id)) return;
    if (recordUndo) _pushUndo();
    final removed = _strokes.where((s) => s.id == id || s.mirrorOfId == id).toList();
    for (final s in removed) {
      _strokes.remove(s);
      _selectedIds.remove(s.id);
    }
    notifyListeners();
  }

  /// Removes all strokes.
  void clearAll({bool recordUndo = true}) {
    if (_strokes.isEmpty) return;
    if (recordUndo) _pushUndo();
    _strokes.clear();
    _selectedIds.clear();
    notifyListeners();
  }

  // ----- Selection -------------------------------------------------------

  /// Selects a single stroke (replaces the current selection).
  void selectStroke(int id, {bool recordUndo = false}) {
    if (recordUndo) _pushUndo();
    _selectedIds
      ..clear()
      ..add(id);
    notifyListeners();
  }

  /// Adds a stroke to the selection (multi-select).
  void addToSelection(int id) {
    if (_selectedIds.add(id)) {
      notifyListeners();
    }
  }

  /// Removes a stroke from the selection.
  void removeFromSelection(int id) {
    if (_selectedIds.remove(id)) {
      notifyListeners();
    }
  }

  /// Toggles the selection state of a stroke.
  void toggleSelection(int id) {
    if (!_selectedIds.add(id)) {
      _selectedIds.remove(id);
    }
    notifyListeners();
  }

  /// Selects all visible strokes.
  void selectAll() {
    _selectedIds
      ..clear()
      ..addAll(_strokes.where((s) => s.isVisible).map((s) => s.id));
    notifyListeners();
  }

  /// Clears the current selection.
  void clearSelection() {
    if (_selectedIds.isEmpty) return;
    _selectedIds.clear();
    notifyListeners();
  }

  // ----- Transforms ------------------------------------------------------

  /// Moves the current selection by [delta] in world space. Mirror copies
  /// move in the mirrored direction.
  void moveSelection(Vector3 delta, {bool recordUndo = true}) {
    if (_selectedIds.isEmpty) return;
    if (recordUndo) _pushUndo();
    for (final stroke in _strokes) {
      if (_selectedIds.contains(stroke.id)) {
        stroke.applyTranslation(delta);
      } else if (stroke.mirrorOfId != null &&
          _selectedIds.contains(stroke.mirrorOfId)) {
        final mirroredDelta = _mirrorVector(delta);
        stroke.applyTranslation(mirroredDelta);
      }
    }
    notifyListeners();
  }

  /// Rotates the current selection by [rotation] around [pivot].
  void rotateSelection(Quaternion rotation,
      {Vector3? pivot, bool recordUndo = true}) {
    if (_selectedIds.isEmpty) return;
    if (recordUndo) _pushUndo();
    final p = pivot ?? _selectionCenter();
    for (final stroke in _strokes) {
      if (_selectedIds.contains(stroke.id)) {
        stroke.applyRotation(rotation, pivot: p);
      } else if (stroke.mirrorOfId != null &&
          _selectedIds.contains(stroke.mirrorOfId)) {
        // Mirror the rotation: invert the axis components that are mirrored.
        final mirrored = _mirrorQuaternion(rotation);
        stroke.applyRotation(mirrored, pivot: _mirrorPoint(p));
      }
    }
    notifyListeners();
  }

  /// Scales the current selection uniformly by [factor] around [pivot].
  void scaleSelection(double factor,
      {Vector3? pivot, bool recordUndo = true}) {
    if (_selectedIds.isEmpty || factor <= 0) return;
    if (recordUndo) _pushUndo();
    final p = pivot ?? _selectionCenter();
    for (final stroke in _strokes) {
      if (_selectedIds.contains(stroke.id)) {
        stroke.applyScale(factor, pivot: p);
      } else if (stroke.mirrorOfId != null &&
          _selectedIds.contains(stroke.mirrorOfId)) {
        stroke.applyScale(factor, pivot: _mirrorPoint(p));
      }
    }
    notifyListeners();
  }

  /// Applies a transform derived from a joystick input vector.
  ///
  /// [input] is in range [-1, 1] x [-1, 1]. The transform applied depends
  /// on [mode]:
  ///   - move: XY of input maps to XY world translation; the input's
  ///     magnitude scales the step size.
  ///   - rotate: input.x rotates around Y, input.y around X.
  ///   - scale: input.y > 0 enlarges, < 0 shrinks.
  void applyJoystickTransform(
    Vector2 input,
    TransformMode mode, {
    double moveStep = 0.05,
    double rotateStep = 0.05,
    double scaleStep = 0.02,
  }) {
    switch (mode) {
      case TransformMode.move:
        moveSelection(Vector3(input.x * moveStep, input.y * moveStep, 0));
        break;
      case TransformMode.rotate:
        final qX = Quaternion.axisAngle(Vector3(1, 0, 0), input.y * rotateStep);
        final qY = Quaternion.axisAngle(Vector3(0, 1, 0), input.x * rotateStep);
        rotateSelection(qY * qX);
        break;
      case TransformMode.scale:
        final factor = 1.0 + input.y * scaleStep;
        scaleSelection(factor);
        break;
    }
  }

  // ----- Liquify ---------------------------------------------------------

  /// Applies a liquify deformation to the current selection.
  ///
  /// [center] is the world-space center of the brush. [radius] is the
  /// affected radius; [strength] is the magnitude of the effect per call.
  /// [direction] is interpreted per [mode]:
  ///   - push / pull: the direction the points move along.
  ///   - twist: the axis to rotate around (length scaled by strength).
  ///   - inflate / deflate: ignored (uses center-to-point direction).
  ///   - smooth: ignored.
  void applyLiquify(
    LiquifyMode mode,
    Vector3 center,
    double radius,
    double strength,
    Vector3 direction, {
    bool recordUndo = true,
  }) {
    if (_selectedIds.isEmpty || radius <= 0) return;
    if (recordUndo) _pushUndo();

    final targets = _strokes
        .where((s) => _selectedIds.contains(s.id))
        .toList(growable: false);

    for (final stroke in targets) {
      _applyLiquifyToStroke(stroke, mode, center, radius, strength, direction);
      // Apply to mirror copies too.
      for (final mirror in _strokes.where((s) => s.mirrorOfId == stroke.id)) {
        final mirroredCenter = _mirrorPoint(center);
        final mirroredDirection = _mirrorVector(direction);
        _applyLiquifyToStroke(mirror, mode, mirroredCenter, radius, strength,
            mirroredDirection);
      }
    }
    notifyListeners();
  }

  void _applyLiquifyToStroke(
    Stroke stroke,
    LiquifyMode mode,
    Vector3 center,
    double radius,
    double strength,
    Vector3 direction,
  ) {
    if (stroke.points.isEmpty) return;
    final positions = stroke.points.map((p) => p.position.clone()).toList();
    final worldPositions = positions
        .map((p) => stroke.transform.transform3(p.clone()))
        .toList(growable: false);

    switch (mode) {
      case LiquifyMode.push:
        for (var i = 0; i < worldPositions.length; i++) {
          final p = worldPositions[i];
          final d = p - center;
          final dist = d.length;
          if (dist >= radius) continue;
          final falloff = (1 - dist / radius);
          p.add(direction.scaled(strength * falloff));
        }
        break;

      case LiquifyMode.pull:
        for (var i = 0; i < worldPositions.length; i++) {
          final p = worldPositions[i];
          final d = p - center;
          final dist = d.length;
          if (dist >= radius) continue;
          final falloff = (1 - dist / radius);
          p.add(direction.scaled(-strength * falloff));
        }
        break;

      case LiquifyMode.twist:
        final axis = direction.normalized();
        final angle = strength * 2.0;
        for (var i = 0; i < worldPositions.length; i++) {
          final p = worldPositions[i];
          final d = p - center;
          final dist = d.length;
          if (dist >= radius) continue;
          final falloff = (1 - dist / radius);
          final q = Quaternion.axisAngle(axis, angle * falloff);
          final rotated = q.rotate(d);
          p.setFrom(center + rotated);
        }
        break;

      case LiquifyMode.inflate:
        for (var i = 0; i < worldPositions.length; i++) {
          final p = worldPositions[i];
          final d = p - center;
          final dist = d.length;
          if (dist >= radius || dist < 1e-6) continue;
          final falloff = (1 - dist / radius);
          final dir = d / dist;
          p.add(dir.scaled(strength * falloff));
        }
        break;

      case LiquifyMode.deflate:
        for (var i = 0; i < worldPositions.length; i++) {
          final p = worldPositions[i];
          final d = p - center;
          final dist = d.length;
          if (dist >= radius || dist < 1e-6) continue;
          final falloff = (1 - dist / radius);
          final dir = d / dist;
          p.add(dir.scaled(-strength * falloff));
        }
        break;

      case LiquifyMode.smooth:
        _smoothPositions(worldPositions, center, radius, strength);
        break;
    }

    // Bake world positions back into local positions.
    final inv = Matrix4.inverted(stroke.transform);
    for (var i = 0; i < stroke.points.length; i++) {
      final local = inv.transform3(worldPositions[i].clone());
      stroke.points[i] = stroke.points[i].copyWith(position: local);
    }
  }

  void _smoothPositions(
    List<Vector3> positions,
    Vector3 center,
    double radius,
    double strength,
  ) {
    if (positions.length < 3) return;
    final updated = List<Vector3>.generate(
        positions.length, (i) => positions[i].clone(),
        growable: false);
    for (var i = 1; i < positions.length - 1; i++) {
      final p = positions[i];
      final d = p - center;
      final dist = d.length;
      if (dist >= radius) continue;
      final falloff = (1 - dist / radius);
      final prev = positions[i - 1];
      final next = positions[i + 1];
      final avg = (prev + next) * 0.5;
      updated[i] = p + (avg - p) * (strength * falloff);
    }
    for (var i = 0; i < positions.length; i++) {
      positions[i].setFrom(updated[i]);
    }
  }

  // ----- Mirror ----------------------------------------------------------

  /// Replaces the current mirror configuration. Existing mirror copies are
  /// regenerated so that all selected strokes have their mirrors.
  void setMirror(MirrorConfig config, {bool recordUndo = true}) {
    if (recordUndo) _pushUndo();
    _mirror = config;
    _rebuildMirrors();
    notifyListeners();
  }

  /// Rebuilds all mirror copies based on the current configuration. Call
  /// this after mutating [_mirror] directly.
  void _rebuildMirrors() {
    // Remove old mirrors.
    _strokes.removeWhere((s) => s.mirrorOfId != null);
    if (!_mirror.anyEnabled) return;
    final originals = _strokes.where((s) => s.mirrorOfId == null).toList();
    for (final original in originals) {
      for (final sign in _mirror.activeMirrors()) {
        final mirrored = original.mirrored(_mirror.origin, sign);
        mirrored.id = _nextId++;
        mirrored.mirrorOfId = original.id;
        _strokes.add(mirrored);
      }
    }
  }

  /// Mirrors a vector according to the active mirror axes.
  Vector3 _mirrorVector(Vector3 v) {
    final out = v.clone();
    if (_mirror.enabledX) out.x = -out.x;
    if (_mirror.enabledY) out.y = -out.y;
    if (_mirror.enabledZ) out.z = -out.z;
    return out;
  }

  /// Mirrors a point about the mirror origin.
  Vector3 _mirrorPoint(Vector3 p) {
    final rel = p - _mirror.origin;
    return _mirror.origin + _mirrorVector(rel);
  }

  /// Mirrors a quaternion: invert rotation components on mirrored axes.
  Quaternion _mirrorQuaternion(Quaternion q) {
    // Build the equivalent rotation matrix, mirror it, extract the new
    // quaternion. This is the most robust general approach.
    final m = q.asRotationMatrix();
    final sx = _mirror.enabledX ? -1.0 : 1.0;
    final sy = _mirror.enabledY ? -1.0 : 1.0;
    final sz = _mirror.enabledZ ? -1.0 : 1.0;
    final mirrored = Matrix3(
      m.entry(0, 0) * sx, m.entry(1, 0) * sy, m.entry(2, 0) * sz, // col 0
      m.entry(0, 1) * sx, m.entry(1, 1) * sy, m.entry(2, 1) * sz, // col 1
      m.entry(0, 2) * sx, m.entry(1, 2) * sy, m.entry(2, 2) * sz, // col 2
    );
    final out = Quaternion.fromRotation(mirrored);
    return out;
  }

  /// Returns the centroid of all selected stroke points.
  Vector3 _selectionCenter() {
    var count = 0;
    final sum = Vector3.zero();
    for (final stroke in selectedStrokes) {
      for (final point in stroke.points) {
        sum.add(stroke.transform.transform3(point.position.clone()));
        count++;
      }
    }
    if (count == 0) return Vector3.zero();
    return sum..scale(1.0 / count);
  }

  // ----- Undo / Redo -----------------------------------------------------

  void _pushUndo() {
    final hook = onBeforeMutate;
    if (hook != null) {
      // Unified journal owns history (loop-20): the hook captured the
      // pre-op state; the internal stacks stay out of the way.
      hook();
      return;
    }
    _undoStack.add(_serialize());
    if (_undoStack.length > maxUndoLevels) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  String _serialize() {
    final map = {
      'strokes': _strokes.map((s) => s.toJson()).toList(),
      'selectedIds': _selectedIds.toList(),
      'nextId': _nextId,
      'mirror': _mirror.toJson(),
    };
    return jsonEncode(map);
  }

  /// Restores the document state from a serialized snapshot.
  void _restore(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    _strokes
      ..clear()
      ..addAll(((decoded['strokes'] as List?) ?? [])
          .map((e) => Stroke.fromJson(e as Map<String, dynamic>)));
    _selectedIds
      ..clear()
      ..addAll(((decoded['selectedIds'] as List?) ?? []).map((e) => e as int));
    _nextId = decoded['nextId'] as int? ?? _nextId;
    _mirror = decoded['mirror'] is Map
        ? MirrorConfig.fromJson(decoded['mirror'] as Map<String, dynamic>)
        : MirrorConfig();
  }

  /// Reverts the last operation. Returns `true` if anything was undone.
  bool undo() {
    if (_undoStack.isEmpty) return false;
    _redoStack.add(_serialize());
    final prev = _undoStack.removeLast();
    _restore(prev);
    notifyListeners();
    return true;
  }

  /// Redoes a previously undone operation. Returns `true` if anything was
  /// redone.
  bool redo() {
    if (_redoStack.isEmpty) return false;
    _undoStack.add(_serialize());
    final next = _redoStack.removeLast();
    _restore(next);
    notifyListeners();
    return true;
  }

  /// Clears undo / redo history (does not modify current strokes).
  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
  }

  // ----- Serialization (project save / load) ----------------------------

  /// Serializes the full document to a JSON string suitable for save.
  String toJsonString() => _serialize();

  /// Replaces the document with the contents of a JSON string.
  void fromJsonString(String json, {bool recordUndo = true}) {
    if (recordUndo) _pushUndo();
    _restore(json);
    notifyListeners();
  }

  // ----- Helpers exposed to the engine ----------------------------------

  /// Returns all stroke points (with world transforms applied) within
  /// [radius] of [center]. Useful for snapping and cursor feedback.
  List<(Stroke, StrokePoint, Vector3)> pointsNearby(
      Vector3 center, double radius) {
    final out = <(Stroke, StrokePoint, Vector3)>[];
    final r2 = radius * radius;
    for (final stroke in _strokes) {
      if (!stroke.isVisible) continue;
      for (final point in stroke.points) {
        final world = stroke.transform.transform3(point.position.clone());
        final d = world - center;
        if (d.length2 <= r2) {
          out.add((stroke, point, world));
        }
      }
    }
    return out;
  }

  /// Returns the world-space bounding box of all visible strokes.
  Aabb3? computeBounds() {
    Aabb3? bounds;
    for (final stroke in _strokes) {
      if (!stroke.isVisible || stroke.points.isEmpty) continue;
      for (final point in stroke.points) {
        final world = stroke.transform.transform3(point.position.clone());
        if (bounds == null) {
          bounds = Aabb3.minMax(world, world.clone());
        } else {
          bounds.hullPoint(world);
        }
      }
    }
    return bounds;
  }

  /// Linearly interpolates between two strokes' points (used for stroke
  /// morphing). The two strokes must have equal point counts.
  Stroke? morph(Stroke a, Stroke b, double t) {
    if (a.points.length != b.points.length) return null;
    final out = Stroke(
      brushType: a.brushType,
      color: a.color,
      thickness: a.thickness * (1 - t) + b.thickness * t,
    );
    for (var i = 0; i < a.points.length; i++) {
      final pa = a.points[i];
      final pb = b.points[i];
      out.points.add(StrokePoint(
        position: pa.position * (1 - t) + pb.position * t,
        pressure: pa.pressure * (1 - t) + pb.pressure * t,
        tilt: pa.tilt * (1 - t) + pb.tilt * t,
        time: pa.time * (1 - t) + pb.time * t,
      ));
    }
    return out;
  }

  /// Splits a stroke into two at the point nearest to [worldPoint].
  /// Returns the new stroke's ID, or -1 if no split occurred.
  int splitAtPoint(int strokeId, Vector3 worldPoint) {
    final stroke = _strokes.firstWhere(
      (s) => s.id == strokeId,
      orElse: () => throw StateError('stroke $strokeId not found'),
    );
    if (stroke.points.length < 4) return -1;
    _pushUndo();
    var bestIdx = 1;
    var bestDist = double.infinity;
    for (var i = 1; i < stroke.points.length - 1; i++) {
      final wp = stroke.transform.transform3(stroke.points[i].position.clone());
      final d = (wp - worldPoint).length2;
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    final partA = stroke.points.sublist(0, bestIdx);
    final partB = stroke.points.sublist(bestIdx);
    stroke.points
      ..clear()
      ..addAll(partA);
    final newStroke = Stroke(
      brushType: stroke.brushType,
      color: stroke.color,
      thickness: stroke.thickness,
      points: partB,
    )..transform = stroke.transform.clone();
    newStroke.id = _nextId++;
    _strokes.add(newStroke);
    notifyListeners();
    return newStroke.id;
  }
}

/// A pair of (stroke, distance) returned by hit-testing routines.
class StrokeHit {
  const StrokeHit(this.stroke, this.pointIndex, this.distance);
  final Stroke stroke;
  final int pointIndex;
  final double distance;
}

/// Helpers to find the closest stroke to a world-space ray or point.
extension StrokeQueryExtensions on StrokeManager {
  /// Finds the closest stroke (by centroid) to [worldPoint].
  StrokeHit? closestStroke(Vector3 worldPoint) {
    StrokeHit? best;
    for (final stroke in strokes) {
      if (!stroke.isVisible) continue;
      for (var i = 0; i < stroke.points.length; i++) {
        final wp = stroke.transform.transform3(stroke.points[i].position.clone());
        final d = (wp - worldPoint).length;
        if (best == null || d < best.distance) {
          best = StrokeHit(stroke, i, d);
        }
      }
    }
    return best;
  }
}
