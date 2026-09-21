// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// light_rig.dart — the scene key-light rig (loop-52).
//
// loop-50 introduced a fixed Lambert key light ([kSceneKeyLight]) that lit
// stroke ribbons from a hard-coded top-left-front direction, and the bottom
// bar's "Light" tool was a stub that merely toggled the grid overlay. This
// module makes the light a first-class, user-controllable scene object:
//
//   - The rig holds the SUN'S SKY POSITION (azimuth around the scene +
//     elevation above the horizon) — an intuitive parametrization for a
//     drag interaction — and converts it to the renderer's light DIRECTION
//     (pointing from the light toward the scene, the convention
//     [kSceneKeyLight] established).
//   - [orbitBy] maps one-finger canvas drags onto that sky position, so the
//     Light tool "grabs the sun and moves it around the model".
//   - [intensity] scales the diffuse term of the Lambert ramp (0 = pure
//     ambient floor, 1 = the legacy full-strength key light).
//
// The scene pipeline consumes the rig through the optional
// `keyLight` / `lightIntensity` parameters on shadeSegment /
// buildStrokeItems / buildUnifiedDrawList. With the rig at its defaults the
// rendered output is byte-identical to the legacy fixed-light look, so all
// loop-50/51 rendering contracts survive unchanged.

import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/scene_pipeline.dart' show kSceneKeyLight;

/// Elevation clamp (degrees). The sun never reaches the zenith — the
/// direction parametrization degenerates at the pole — and dips at most
/// [kMinSunElevationDeg] below the horizon (dramatic rim light without a
/// full up-light flip).
const double kMaxSunElevationDeg = 88.0;
const double kMinSunElevationDeg = -30.0;

/// Drag sensitivity (degrees per logical pixel): a full 900 px-wide drag
/// sweeps ~360° of azimuth, a full 600 px-tall drag sweeps ~180° of
/// elevation.
const double kLightAzimuthDegPerPx = 0.4;
const double kLightElevationDegPerPx = 0.3;

double get _degToRad => math.pi / 180.0;

/// The scene key light, parametrized as a sun position in the sky.
///
/// State is plain data with no Flutter bindings — fully unit-testable, and
/// safe to mutate from the canvas input handlers (the canvas repaints via
/// its own setState; chrome reads it through [EditorState.lightRig]).
class SceneLightRig {
  SceneLightRig({Vector3? direction, double intensity = 1.0}) {
    setDirection(direction ?? kSceneKeyLight.clone());
    setIntensity(intensity);
  }

  /// Unit-length world-space light direction, pointing FROM the light
  /// TOWARD the scene (same convention as [kSceneKeyLight]).
  Vector3 _direction = Vector3.zero();

  /// Diffuse-term scale in [0, 1]. 1.0 = the legacy full-strength key
  /// light; 0.0 = every surface reads at the ambient floor.
  double _intensity = 1.0;

  Vector3 get direction => _direction.clone();

  double get intensity => _intensity;

  /// The sun's azimuth around the scene in radians — atan2 of the sun's
  /// position at unit radius (the position is opposite [direction]).
  double get sunAzimuth => math.atan2(-_direction.z, -_direction.x);

  /// The sun's elevation above the horizon in radians, in
  /// [[kMinSunElevationDeg], [kMaxSunElevationDeg]].
  double get sunElevation => math.asin((-_direction.y).clamp(-1.0, 1.0));

  /// [sunAzimuth] in degrees, normalized to [0, 360).
  double get sunAzimuthDeg {
    var d = sunAzimuth / _degToRad;
    d %= 360.0;
    return d < 0 ? d + 360.0 : d;
  }

  /// [sunElevation] in degrees.
  double get sunElevationDeg => sunElevation / _degToRad;

  /// Sets the light direction. The vector is normalized (cloned first —
  /// the input is never mutated).
  void setDirection(Vector3 dir) {
    _direction = dir.clone()..normalize();
  }

  /// Sets the diffuse intensity, clamped to [0, 1].
  void setIntensity(double value) {
    _intensity = value.clamp(0.0, 1.0);
  }

  /// Positions the sun at [azimuth] radians around the scene and
  /// [elevation] radians above the horizon (elevation clamped to
  /// [[kMinSunElevationDeg], [kMaxSunElevationDeg]] so the direction never
  /// degenerates at the pole).
  ///
  /// The renderer direction points OPPOSITE the sun position (from the
  /// light toward the scene): dir = -(cos el·cos az, sin el, cos el·sin az).
  void setSunAzimuthElevation(double azimuth, double elevation) {
    final el =
        elevation.clamp(kMinSunElevationDeg * _degToRad, kMaxSunElevationDeg * _degToRad);
    final cosEl = math.cos(el);
    _direction = Vector3(
      -cosEl * math.cos(azimuth),
      -math.sin(el),
      -cosEl * math.sin(azimuth),
    );
  }

  /// One Light-tool drag step: [dxPx] pixels right move the sun's azimuth
  /// by [kLightAzimuthDegPerPx] per pixel, [dyPx] pixels DOWN lower the
  /// sun's elevation by [kLightElevationDegPerPx] per pixel (dragging up
  /// raises the sun).
  void orbitBy(double dxPx, double dyPx) {
    setSunAzimuthElevation(
      sunAzimuth + dxPx * kLightAzimuthDegPerPx * _degToRad,
      sunElevation - dyPx * kLightElevationDegPerPx * _degToRad,
    );
  }
}
