// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// light_rig_test.dart — unit tests for the loop-52 scene key-light rig:
// the sun-position parametrization, drag mapping, intensity ramp, the
// pipeline's legacy-exact default reduction, and the EditorState wiring.

import 'dart:math' as math;
import 'dart:ui' show Color, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/light_rig.dart';
import 'package:feather_krita/engine/scene_pipeline.dart';
import 'package:feather_krita/state/editor_state.dart';

const Size _viewport = Size(800, 600);

// Color channel helpers on the non-deprecated double API.
int _r(Color c) => (c.r * 255.0).round() & 0xff;
int _g(Color c) => (c.g * 255.0).round() & 0xff;

SceneCameraInput _camera() {
  const fov = 60.0 * math.pi / 180.0;
  final pos = Vector3(0, 0, 6);
  final view = makeViewMatrix(pos, Vector3.zero(), Vector3(0, 1, 0));
  final proj = makePerspectiveMatrix(
      fov, _viewport.width / _viewport.height, 0.05, 1000.0);
  return SceneCameraInput(
    position: pos,
    view: view,
    viewProjection: proj * view,
    fovYRadians: fov,
  );
}

SceneStrokeInput _stroke({List<Vector3>? points}) => SceneStrokeInput(
      points: points ?? [Vector3(-1, 0, 0), Vector3(1, 0, 0)],
      pressures: const [1.0, 1.0],
      thickness: 20,
      color: const Color(0xFF808080),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rig parametrization', () {
    test('defaults reproduce the legacy fixed key light exactly', () {
      final rig = SceneLightRig();
      final d = rig.direction;
      expect((d - kSceneKeyLight).length, lessThan(1e-9));
      expect(d.length, closeTo(1.0, 1e-9));
      expect(rig.intensity, 1.0);
      // The default sun sits well above the horizon (soft overhead look).
      expect(rig.sunElevationDeg, greaterThan(30.0));
      expect(rig.sunElevationDeg, lessThan(kMaxSunElevationDeg));
    });

    test('azimuth/elevation roundtrip preserves the direction', () {
      final rig = SceneLightRig(direction: Vector3(0.3, -0.8, -0.5));
      final before = rig.direction.clone();
      rig.setSunAzimuthElevation(rig.sunAzimuth, rig.sunElevation);
      expect((rig.direction - before).length, lessThan(1e-9));
    });

    test('direction is the OPPOSITE of the sun position', () {
      final rig = SceneLightRig();
      rig.setSunAzimuthElevation(0.0, 30.0 * math.pi / 180.0);
      final d = rig.direction;
      // Sun at azimuth 0 → position (+cos el, +sin el, 0) → direction
      // points back at the origin: y negative (downward), x negative.
      expect(d.y, closeTo(-math.sin(30.0 * math.pi / 180.0), 1e-12));
      expect(d.x, closeTo(-math.cos(30.0 * math.pi / 180.0), 1e-12));
      expect(d.z, closeTo(0.0, 1e-12));
    });

    test('setDirection normalizes and never mutates its input', () {
      final input = Vector3(0.0, -3.0, 0.0);
      final rig = SceneLightRig();
      rig.setDirection(input);
      expect(input.length, 3.0, reason: 'input vector must be untouched');
      expect(rig.direction.length, closeTo(1.0, 1e-12));
      // Directly overhead sun → the pipeline's max-lit direction.
      expect(rig.direction.y, closeTo(-1.0, 1e-12));
    });

    test('elevation clamps below the horizon and at the zenith', () {
      final rig = SceneLightRig();
      rig.setSunAzimuthElevation(0.0, -90.0 * math.pi / 180.0);
      // asin∘sin roundtrips through floating point — compare with ε.
      expect(rig.sunElevationDeg, closeTo(kMinSunElevationDeg, 1e-9));
      rig.setSunAzimuthElevation(0.0, 90.0 * math.pi / 180.0);
      expect(rig.sunElevationDeg, closeTo(kMaxSunElevationDeg, 1e-9));
      // Direction stays unit-length and finite at both clamps.
      expect(rig.direction.length, closeTo(1.0, 1e-12));
    });

    test('orbitBy maps pixels to degrees with the documented sensitivity',
        () {
      final rig = SceneLightRig();
      final az0 = rig.sunAzimuth;
      final el0 = rig.sunElevationDeg;
      rig.orbitBy(90, 0); // 90 px right → +36° azimuth
      expect((rig.sunAzimuth - az0) * 180.0 / math.pi,
          closeTo(90 * kLightAzimuthDegPerPx, 1e-9));
      rig.orbitBy(0, -100); // 100 px up → +30° elevation
      expect(rig.sunElevationDeg, closeTo(el0 + 100 * kLightElevationDegPerPx,
          1e-9));
    });

    test('orbitBy never escapes the elevation clamp', () {
      final rig = SceneLightRig();
      rig.orbitBy(0, -100000);
      expect(rig.sunElevationDeg, closeTo(kMaxSunElevationDeg, 1e-9));
      expect(rig.direction.length, closeTo(1.0, 1e-12));
      rig.orbitBy(0, 100000);
      expect(rig.sunElevationDeg, closeTo(kMinSunElevationDeg, 1e-9));
      expect(rig.direction.length, closeTo(1.0, 1e-12));
    });
  });

  group('intensity', () {
    test('clamps to [0, 1]', () {
      final rig = SceneLightRig();
      rig.setIntensity(-0.5);
      expect(rig.intensity, 0.0);
      rig.setIntensity(1.7);
      expect(rig.intensity, 1.0);
      rig.setIntensity(0.5);
      expect(rig.intensity, 0.5);
    });
  });

  group('pipeline integration', () {
    test('null light is byte-identical to the explicit legacy default', () {
      final cam = _camera();
      final s = _stroke();
      final legacy = buildStrokeItems(
          stroke: s, camera: cam, viewport: _viewport, seqStart: 0);
      final explicit = buildStrokeItems(
          stroke: s,
          camera: cam,
          viewport: _viewport,
          seqStart: 0,
          keyLight: kSceneKeyLight,
          lightIntensity: 1.0);
      expect(explicit.length, legacy.length);
      for (var i = 0; i < legacy.length; i++) {
        final a = legacy[i] as SceneSegment;
        final b = explicit[i] as SceneSegment;
        expect(b.color, a.color);
        expect(b.widthPx, closeTo(a.widthPx, 1e-12));
      }
    });

    test('default rig through buildUnifiedDrawList matches the fixed light',
        () {
      final cam = _camera();
      final s = _stroke();
      final legacy = buildUnifiedDrawList(
          surface: SceneSurfaceInput(
            positions: const <Vector3>[],
            indices: const <int>[],
            uvs: const <Vector2>[],
            sampleColor: (uv) => const Color(0xFF808080),
          ),
          strokes: [s],
          camera: cam,
          viewport: _viewport);
      final rig = SceneLightRig();
      final rigged = buildUnifiedDrawList(
          surface: SceneSurfaceInput(
            positions: const <Vector3>[],
            indices: const <int>[],
            uvs: const <Vector2>[],
            sampleColor: (uv) => const Color(0xFF808080),
          ),
          strokes: [s],
          camera: cam,
          viewport: _viewport,
          keyLight: rig.direction,
          lightIntensity: rig.intensity);
      expect(rigged.length, legacy.length);
      for (var i = 0; i < legacy.length; i++) {
        final a = legacy[i] as SceneSegment;
        final b = rigged[i] as SceneSegment;
        expect(b.color, a.color);
      }
    });

    test('overhead sun + full intensity fully lights a top-facing ribbon',
        () {
      final rig = SceneLightRig();
      rig.setDirection(Vector3(0, -1, 0)); // sun at the zenith
      final color = shadeSegment(
        const Color(0xFF808080),
        Vector3(1, 0, 0), // tangent → normal (0,−1,0) aligns with the light
        Vector3.zero(),
        Vector3(0, 0, 6),
        keyLight: rig.direction,
        lightIntensity: rig.intensity,
      );
      expect(_r(color), 128, reason: 'n·L = 1 → brightness 1.0');
      expect(_r(color), _g(color));
    });

    test('intensity scales the diffuse term linearly onto the ambient floor',
        () {
      final rig = SceneLightRig();
      rig.setDirection(Vector3(0, -1, 0));
      Color shadeAt(double intensity) => shadeSegment(
            const Color(0xFF808080),
            Vector3(1, 0, 0),
            Vector3.zero(),
            Vector3(0, 0, 6),
            keyLight: rig.direction,
            lightIntensity: intensity,
          );
      // intensity 0 → pure ambient floor, independent of the light.
      expect(_r(shadeAt(0.0)), (128 * kSceneAmbient).round());
      // Half intensity sits exactly halfway up the ramp.
      expect(_r(shadeAt(0.5)),
          (128 * (kSceneAmbient + (1.0 - kSceneAmbient) * 0.5)).round());
      // Monotonic ramp.
      expect(_r(shadeAt(0.25)), lessThan(_r(shadeAt(0.75))));
    });

    test('intensity 0 renders segments at the ambient floor via the pipeline',
        () {
      final cam = _camera();
      final items = buildStrokeItems(
        stroke: _stroke(),
        camera: cam,
        viewport: _viewport,
        seqStart: 0,
        keyLight: Vector3(0, -1, 0),
        lightIntensity: 0.0,
      );
      final seg = items.whereType<SceneSegment>().single;
      expect(_r(seg.color), (128 * kSceneAmbient).round());
    });
  });

  group('editor state wiring', () {
    test('EditorState exposes the default rig', () {
      final state = EditorState();
      addTearDown(state.dispose);
      expect((state.lightRig.direction - kSceneKeyLight).length,
          lessThan(1e-9));
      expect(state.lightRig.intensity, 1.0);
    });

    test('orbiting through the state mutates the shared rig', () {
      final state = EditorState();
      addTearDown(state.dispose);
      final el0 = state.lightRig.sunElevationDeg;
      state.lightRig.orbitBy(0, -50); // drag up 50 px
      expect(state.lightRig.sunElevationDeg,
          closeTo(el0 + 50 * kLightElevationDegPerPx, 1e-9));
    });
  });
}
