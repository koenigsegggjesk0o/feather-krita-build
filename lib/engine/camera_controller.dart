// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// camera_controller.dart — 3D orbit camera with touch gestures.
//
// Implements an orbit (turntable) camera that always looks at a target
// point in 3D space and supports:
//   - Smooth damped rotation / pan / zoom.
//   - One-finger drag to orbit.
//   - Two-finger pinch to zoom.
//   - Two-finger rotate / pan.
//   - Mouse wheel on desktop.
//
// The controller exposes the resulting view matrix via [viewMatrix] and
// a perspective projection via [projectionMatrix]. Consumers (e.g. the
// Flutter GL viewport) call [tick] each frame to advance the damping
// animation.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/utils/vector_math_utils.dart';

/// Smoothing / damping configuration for the camera.
class CameraDamping {
  const CameraDamping({
    this.rotationLerp = 0.18,
    this.panLerp = 0.20,
    this.zoomLerp = 0.22,
    this.snapThreshold = 1e-4,
  });

  /// Per-frame lerp factor (0 = no motion, 1 = instant snap) for yaw /
  /// pitch.
  final double rotationLerp;

  /// Per-frame lerp factor for the target position (pan).
  final double panLerp;

  /// Per-frame lerp factor for distance.
  final double zoomLerp;

  /// Below this delta the current value snaps to the target.
  final double snapThreshold;

  static const CameraDamping smooth = CameraDamping();
  static const CameraDamping instant =
      CameraDamping(rotationLerp: 1, panLerp: 1, zoomLerp: 1, snapThreshold: 0);
}

/// Configuration for the perspective projection.
class CameraProjectionConfig {
  const CameraProjectionConfig({
    this.fovYRadians = 60.0 * math.pi / 180.0,
    this.near = 0.05,
    this.far = 1000.0,
  });

  final double fovYRadians;
  final double near;
  final double far;
}

/// Orbit camera controller.
///
/// State is split into "current" (what the renderer sees) and "target"
/// (what the user / gestures request). Each [tick] lerps current →
/// target with the configured damping factors.
class CameraController extends ChangeNotifier {
  CameraController({
    Vector3? target,
    double yaw = 0.0,
    double pitch = -0.4,
    double distance = 6.0,
    this.projection = const CameraProjectionConfig(),
    this.damping = CameraDamping.smooth,
    double minDistance = 0.5,
    double maxDistance = 200.0,
    double minPitch = -1.55,
    double maxPitch = 1.55,
  })  : _target = target ?? Vector3.zero(),
        _currentTarget = (target ?? Vector3.zero()).clone(),
        _yawTarget = yaw,
        _yawCurrent = yaw,
        _pitchTarget = pitch,
        _pitchCurrent = pitch,
        _distanceTarget = distance,
        _distanceCurrent = distance,
        _minDistance = minDistance,
        _maxDistance = maxDistance,
        _minPitch = minPitch,
        _maxPitch = maxPitch;

  final CameraProjectionConfig projection;
  CameraDamping damping;

  // Orbit state — split into target (what the user requested) and current
  // (what the camera is at, after damping).
  Vector3 _target;
  Vector3 _currentTarget;
  double _yawTarget;
  double _yawCurrent;
  double _pitchTarget;
  double _pitchCurrent;
  double _distanceTarget;
  double _distanceCurrent;

  final double _minDistance;
  final double _maxDistance;
  final double _minPitch;
  final double _maxPitch;

  /// The point the camera orbits around (target value).
  Vector3 get target => _target;
  set target(Vector3 value) {
    _target = value.clone();
    notifyListeners();
  }

  /// Yaw (horizontal rotation) in radians — target value.
  double get yaw => _yawTarget;
  set yaw(double value) {
    _yawTarget = value;
    notifyListeners();
  }

  /// Pitch (vertical rotation) in radians — target value.
  double get pitch => _pitchTarget;
  set pitch(double value) {
    _pitchTarget = value.clamp(_minPitch, _maxPitch);
    notifyListeners();
  }

  /// Distance from target — target value.
  double get distance => _distanceTarget;
  set distance(double value) {
    _distanceTarget = value.clamp(_minDistance, _maxDistance);
    notifyListeners();
  }

  /// Current (damped) yaw.
  double get currentYaw => _yawCurrent;

  /// Current (damped) pitch.
  double get currentPitch => _pitchCurrent;

  /// Current (damped) distance.
  double get currentDistance => _distanceCurrent;

  /// Current (damped) target.
  Vector3 get currentTarget => _currentTarget;

  /// True if any current value differs from its target beyond the snap
  /// threshold. Useful for deciding whether to keep rendering.
  bool get isAnimating {
    final s = damping.snapThreshold;
    if ((yaw - _yawCurrent).abs() > s) return true;
    if ((pitch - _pitchCurrent).abs() > s) return true;
    if ((distance - _distanceCurrent).abs() > s) return true;
    if ((target - _currentTarget).length > s) return true;
    return false;
  }

  // ----- Derived matrices ------------------------------------------------

  /// Computes the current camera position in world space.
  Vector3 get position {
    final cp = math.cos(_pitchCurrent);
    final sp = math.sin(_pitchCurrent);
    final cy = math.cos(_yawCurrent);
    final sy = math.sin(_yawCurrent);
    return _currentTarget +
        Vector3(
          _distanceCurrent * cp * cy,
          _distanceCurrent * sp,
          _distanceCurrent * cp * sy,
        );
  }

  /// World-space forward direction (from camera toward target).
  Vector3 get forward => (_currentTarget - position)..normalize();

  /// World-space right direction.
  Vector3 get right => forward.cross(Vector3(0, 1, 0))..normalize();

  /// World-space up direction.
  Vector3 get up => right.cross(forward)..normalize();

  /// Builds the view matrix from the current (damped) state.
  Matrix4 get viewMatrix {
    return VectorMathUtils.lookAt(position, _currentTarget, Vector3(0, 1, 0));
  }

  /// Builds the projection matrix for the given viewport aspect.
  Matrix4 projectionMatrixFor(double aspect) {
    return VectorMathUtils.makeViewMatrix(
      projection.fovYRadians,
      aspect,
      projection.near,
      projection.far,
    );
  }

  /// Builds the combined view-projection matrix.
  Matrix4 viewProjectionMatrix(double aspect) =>
      projectionMatrixFor(aspect) * viewMatrix;

  // ----- Animation -------------------------------------------------------

  /// Instantly moves the camera to the given pose: both the damped
  /// (current) values and the gesture targets jump to [yaw]/[pitch]/
  /// [distance]/[target], so the next frame renders from the new pose
  /// with no damping animation. Used by project-file restore (loop-18):
  /// opening a saved document must not play a fly-in animation.
  ///
  /// Values are clamped to the controller's pitch/distance limits like
  /// the corresponding setters. Only supplied values are changed.
  void snapTo({
    Vector3? target,
    double? yaw,
    double? pitch,
    double? distance,
  }) {
    if (target != null) {
      _target = target.clone();
      _currentTarget = target.clone();
    }
    if (yaw != null) {
      _yawTarget = yaw;
      _yawCurrent = yaw;
    }
    if (pitch != null) {
      _pitchTarget = pitch.clamp(_minPitch, _maxPitch);
      _pitchCurrent = _pitchTarget;
    }
    if (distance != null) {
      _distanceTarget = distance.clamp(_minDistance, _maxDistance);
      _distanceCurrent = _distanceTarget;
    }
    notifyListeners();
  }

  /// Advances the damping animation by one frame. Returns `true` if the
  /// camera state changed (i.e. the renderer should redraw).
  ///
  /// [dt] is the time delta in seconds since the previous frame. The
  /// damping factors are framerate-independent: a larger [dt] yields a
  /// larger lerp step so the perceived smoothing stays consistent.
  bool tick(double dt) {
    if (dt <= 0) dt = 1 / 60;
    // Convert per-frame lerp factor to a framerate-independent value.
    final r = 1.0 - math.pow(1.0 - damping.rotationLerp, dt * 60.0).toDouble();
    final p = 1.0 - math.pow(1.0 - damping.panLerp, dt * 60.0).toDouble();
    final z = 1.0 - math.pow(1.0 - damping.zoomLerp, dt * 60.0).toDouble();

    var changed = false;
    if ((_yawTarget - _yawCurrent).abs() > damping.snapThreshold) {
      _yawCurrent = _lerp(_yawCurrent, _yawTarget, r);
      changed = true;
    } else if (_yawCurrent != _yawTarget) {
      _yawCurrent = _yawTarget;
      changed = true;
    }
    if ((_pitchTarget - _pitchCurrent).abs() > damping.snapThreshold) {
      _pitchCurrent = _lerp(_pitchCurrent, _pitchTarget, r);
      changed = true;
    } else if (_pitchCurrent != _pitchTarget) {
      _pitchCurrent = _pitchTarget;
      changed = true;
    }
    if ((_distanceTarget - _distanceCurrent).abs() > damping.snapThreshold) {
      _distanceCurrent = _lerp(_distanceCurrent, _distanceTarget, z);
      changed = true;
    } else if (_distanceCurrent != _distanceTarget) {
      _distanceCurrent = _distanceTarget;
      changed = true;
    }
    final targetDelta = _target - _currentTarget;
    if (targetDelta.length > damping.snapThreshold) {
      _currentTarget = _currentTarget + targetDelta * p;
      changed = true;
    } else if (_currentTarget != _target) {
      _currentTarget = _target.clone();
      changed = true;
    }

    if (changed) notifyListeners();
    return changed;
  }

  /// Instantly snaps the current state to the target state (no damping).
  void snap() {
    _yawCurrent = _yawTarget;
    _pitchCurrent = _pitchTarget;
    _distanceCurrent = _distanceTarget;
    _currentTarget = _target.clone();
    notifyListeners();
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  // ----- Orbit gestures --------------------------------------------------

  /// Rotates the camera by [deltaYaw] / [deltaPitch] radians.
  void orbit(double deltaYaw, double deltaPitch) {
    _yawTarget += deltaYaw;
    // Keep yaw in a reasonable range to avoid float precision loss.
    while (_yawTarget > math.pi) {
      _yawTarget -= 2 * math.pi;
    }
    while (_yawTarget < -math.pi) {
      _yawTarget += 2 * math.pi;
    }
    _pitchTarget = (_pitchTarget + deltaPitch).clamp(_minPitch, _maxPitch);
    notifyListeners();
  }

  /// Pans the target (and thus the camera) by [worldDelta] in world space.
  void panWorld(Vector3 worldDelta) {
    _target = _target + worldDelta;
    notifyListeners();
  }

  /// Pans the target by a screen-space delta. [dx] / [dy] are in pixels,
  /// [viewportWidth] / [viewportHeight] are the viewport size.
  void panScreen(
      double dx, double dy, double viewportWidth, double viewportHeight) {
    // Convert pixel delta to world-space delta along camera right/up.
    final worldPerPixel =
        2.0 * _distanceTarget * math.tan(projection.fovYRadians * 0.5) /
            viewportHeight;
    final moveRight = right * (-dx * worldPerPixel);
    final moveUp = up * (dy * worldPerPixel);
    panWorld(moveRight + moveUp);
  }

  /// Zooms in (positive [factor]) or out (negative). [factor] is a
  /// multiplier on the current distance — e.g. 1.1 means "10% farther".
  void zoomByFactor(double factor) {
    _distanceTarget =
        (_distanceTarget * factor).clamp(_minDistance, _maxDistance);
    notifyListeners();
  }

  /// Zooms by an absolute delta in distance units.
  void zoomByDelta(double delta) {
    _distanceTarget =
        (_distanceTarget + delta).clamp(_minDistance, _maxDistance);
    notifyListeners();
  }

  /// Frames the given [bounds] by setting target/distance appropriately.
  void frameBounds(Aabb3 bounds, {double padding = 1.2}) {
    final center = bounds.center;
    final size = bounds.max - bounds.min;
    final radius = size.length * 0.5 * padding;
    if (radius < 1e-6) return;
    _target = center.clone();
    _distanceTarget = radius / math.tan(projection.fovYRadians * 0.5);
    if (_distanceTarget < _minDistance) _distanceTarget = _minDistance;
    if (_distanceTarget > _maxDistance) _distanceTarget = _maxDistance;
    notifyListeners();
  }

  // ----- High-level gesture handlers -------------------------------------

  /// Handles a one-finger drag — orbits the camera.
  ///
  /// [dx] / [dy] are the pixel deltas since the previous event. The
  /// rotation speed is scaled by [sensitivity] in radians per pixel.
  void handleOneFingerDrag(double dx, double dy,
      {double sensitivity = 0.008}) {
    orbit(dx * sensitivity, dy * sensitivity);
  }

  /// Handles a two-finger gesture: pinch zoom + rotation.
  ///
  /// [rotationDelta] is the change in angle between the two fingers, in
  /// radians. [scaleFactor] is the multiplicative change in pinch
  /// distance (>1 means fingers moved apart).
  void handleTwoFingerGesture({
    required double rotationDelta,
    required double scaleFactor,
    double rotationSensitivity = 1.0,
  }) {
    if ((rotationDelta.abs()) > 1e-4) {
      _yawTarget += rotationDelta * rotationSensitivity;
      notifyListeners();
    }
    if ((scaleFactor - 1.0).abs() > 1e-4) {
      zoomByFactor(1.0 / scaleFactor);
    }
  }

  /// Handles a two-finger pan gesture.
  ///
  /// [dx] / [dy] are the average pixel delta of both fingers.
  void handleTwoFingerPan(double dx, double dy, double viewportWidth,
      double viewportHeight) {
    panScreen(dx, dy, viewportWidth, viewportHeight);
  }

  /// Handles a mouse wheel event. [scrollDelta] is positive for zoom-in
  /// (wheel up) on most platforms.
  void handleMouseWheel(double scrollDelta,
      {double sensitivity = 0.001}) {
    zoomByDelta(-scrollDelta * sensitivity * _distanceTarget);
  }

  // ----- Serialization ---------------------------------------------------

  Map<String, dynamic> toJson() => {
        'target': [_target.x, _target.y, _target.z],
        'yaw': _yawTarget,
        'pitch': _pitchTarget,
        'distance': _distanceTarget,
      };

  factory CameraController.fromJson(Map<String, dynamic> json) {
    final tList = (json['target'] as List).cast<num>();
    return CameraController(
      target: Vector3(tList[0].toDouble(), tList[1].toDouble(), tList[2].toDouble()),
      yaw: (json['yaw'] as num?)?.toDouble() ?? 0.0,
      pitch: (json['pitch'] as num?)?.toDouble() ?? -0.4,
      distance: (json['distance'] as num?)?.toDouble() ?? 6.0,
    );
  }

  /// Returns a deep copy of this controller with the same state.
  CameraController copy() => CameraController(
        target: _target.clone(),
        yaw: _yawTarget,
        pitch: _pitchTarget,
        distance: _distanceTarget,
        projection: projection,
        damping: damping,
        minDistance: _minDistance,
        maxDistance: _maxDistance,
        minPitch: _minPitch,
        maxPitch: _maxPitch,
      );
}
