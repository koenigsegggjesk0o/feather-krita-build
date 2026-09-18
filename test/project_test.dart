// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// project_test.dart — .feather project document round-trip tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2, Vector3;

import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/io/feather_project.dart';
import 'package:feather_krita/models/stroke.dart';
import 'package:feather_krita/state/editor_state.dart';

void main() {
  group('FeatherProjectDocument', () {
    test('round-trips an editor state through JSON', () {
      final state = EditorState(
        fileName: 'RoundTrip.feather',
      )
        ..setBrushSize(45.5)
        ..setBrushOpacity(0.75)
        ..setBrushColor(0xFF3366CC)
        ..setBrushPresetName('Ink Fineliner');

      final stroke = Stroke(
        id: 7,
        brushType: BrushType.ink,
        color: 0xFF3366CC,
        thickness: 12,
        name: 'RoundTrip stroke',
        points: [
          StrokePoint(
            position: Vector3(0.2, 0.1, 1.35),
            pressure: 0.9,
            time: 0,
            uv: Vector2(0.42, 0.61),
          ),
          StrokePoint(
            position: Vector3(0.4, -0.1, 1.3),
            pressure: 0.4,
            time: 0.5,
            uv: Vector2(0.55, 0.44),
          ),
        ],
      );
      state.strokes.addStroke(stroke);

      final doc = FeatherProjectDocument.fromEditor(state);
      final json = doc.toJsonString();
      final parsed = FeatherProjectDocument.parse(json);

      expect(parsed.fileName, 'RoundTrip.feather');
      expect(parsed.version, kFeatherProjectVersion);
      expect(parsed.guideSurfaceName, 'Sphere');
      expect(parsed.brushPreset, 'Ink Fineliner');
      expect(parsed.brushSize, closeTo(45.5, 0.01));
      expect(parsed.brushOpacity, closeTo(0.75, 0.001));
      expect(parsed.brushColor, 0xFF3366CC);
      expect(parsed.strokes, hasLength(1));
      expect(parsed.strokes.first.id, 7);
      expect(parsed.strokes.first.brushType, BrushType.ink);
      expect(parsed.strokes.first.points, hasLength(2));
      expect(parsed.strokes.first.points.first.uv, isNotNull);
      expect(parsed.strokes.first.points.first.uv!.x, closeTo(0.42, 1e-9));
      expect(parsed.strokes.first.points.first.uv!.y, closeTo(0.61, 1e-9));
    });

    test('applyTo restores document state and the load is undoable', () {
      // Document A: the "old" document that must come back after undo.
      final state = EditorState(fileName: 'Old.feather');
      state.strokes.addStroke(Stroke(id: 1, name: 'old'));

      final loaded = EditorState(fileName: 'Old.feather');
      loaded.strokes.addStroke(Stroke(id: 1, name: 'old'));

      final doc = FeatherProjectDocument(
        fileName: 'Restored.feather',
        guideSurfaceName: 'Cylinder',
        brushPreset: 'Airbrush Soft',
        brushSize: 88.0,
        brushOpacity: 0.6,
        brushColor: 0xFF112233,
        strokes: [
          Stroke(
            id: 3,
            brushType: BrushType.airbrush,
            color: 0xFF112233,
            thickness: 20,
            name: 'restored',
            points: [
              StrokePoint(
                position: Vector3(0.1, 0.2, 1.4),
                pressure: 1.0,
                uv: Vector2(0.5, 0.5),
              ),
            ],
          ),
        ],
      );
      doc.applyTo(loaded);

      expect(loaded.fileName, 'Restored.feather');
      expect(loaded.brushSize, 88.0);
      expect(loaded.brushOpacity, closeTo(0.6, 1e-9));
      expect(loaded.brushColor, 0xFF112233);
      expect(loaded.brushPresetName, 'Airbrush Soft');
      expect(loaded.guideSurface.type, GuideSurfaceType.cylinder);
      expect(loaded.strokes.strokeCount, 1);
      expect(loaded.strokes.strokes.first.name, 'restored');
      expect(loaded.canUndo, isTrue,
          reason: 'project load must be undoable (unified journal, loop-20)');

      // Undoing the load brings the previous document back.
      loaded.undo();
      expect(loaded.strokes.strokeCount, 1);
      expect(loaded.strokes.strokes.first.name, 'old');
      expect(loaded.fileName, 'Restored.feather',
          reason: 'undo does not restore the document file name');
    });

    test('parses legacy v1 documents without per-point UVs', () {
      const v1Json = '{"version":1,'
          '"fileName":"Legacy.feather",'
          '"texture":{"width":2048,"height":2048},'
          '"guideSurface":"Sphere",'
          '"brush":{"preset":"Basic Round","size":32.00,'
          '"opacity":1.000,"color":4278877482},'
          '"strokes":[{"id":1,"brushType":"basic","color":4278877482,'
          '"thickness":8.0,"points":[{"x":0.1,"y":0.2,"z":1.4,"p":0.5,'
          '"tx":0.0,"ty":0.0,"t":0.0}],"isVisible":true,"name":"legacy"}]}';
      final doc = FeatherProjectDocument.parse(v1Json);
      expect(doc.version, 1);
      expect(doc.strokes, hasLength(1));
      expect(doc.strokes.first.points.first.uv, isNull);
      expect(doc.strokes.first.points.first.position.z, closeTo(1.4, 1e-9));
    });

    test('rejects malformed payloads and future versions', () {
      expect(
        () => FeatherProjectDocument.parse('not json at all'),
        throwsFormatException,
      );
      expect(
        () => FeatherProjectDocument.parse('[1, 2, 3]'),
        throwsFormatException,
        reason: 'root must be a JSON object',
      );
      const future = '{"version":99,"fileName":"x.feather"}';
      expect(
        () => FeatherProjectDocument.parse(future),
        throwsFormatException,
      );
    });

    test('guideSurfaceTypeFromName accepts display and raw names', () {
      expect(guideSurfaceTypeFromName('Sphere'), GuideSurfaceType.sphere);
      expect(guideSurfaceTypeFromName('Cylinder'), GuideSurfaceType.cylinder);
      expect(guideSurfaceTypeFromName('Ring / Torus'), GuideSurfaceType.ring);
      expect(guideSurfaceTypeFromName('ring'), GuideSurfaceType.ring);
      expect(guideSurfaceTypeFromName('PLANE'), GuideSurfaceType.plane);
      expect(guideSurfaceTypeFromName('Unknown!'), GuideSurfaceType.sphere);
    });
  });

  group('FeatherProjectDocument camera pose (loop-18)', () {
    test('round-trips the camera pose through JSON', () {
      final state = EditorState(fileName: 'Cam.feather');
      state.camera
        ..yaw = 1.25
        ..pitch = -0.62
        ..distance = 9.75
        ..target = Vector3(0.3, -0.4, 0.55);
      state.camera.tick(10); // settle damping so current == target

      final doc = FeatherProjectDocument.fromEditor(state);
      expect(doc.hasCamera, isTrue);

      final parsed = FeatherProjectDocument.parse(doc.toJsonString());
      expect(parsed.hasCamera, isTrue);
      expect(parsed.cameraYaw, closeTo(1.25, 1e-6));
      expect(parsed.cameraPitch, closeTo(-0.62, 1e-6));
      expect(parsed.cameraDistance, closeTo(9.75, 1e-6));
      expect(parsed.cameraTargetX, closeTo(0.3, 1e-6));
      expect(parsed.cameraTargetY, closeTo(-0.4, 1e-6));
      expect(parsed.cameraTargetZ, closeTo(0.55, 1e-6));
    });

    test('applyTo restores the camera pose instantly', () {
      final state = EditorState(fileName: 'Src.feather');
      state.camera
        ..yaw = 0.8
        ..pitch = 0.45
        ..distance = 12.0
        ..target = Vector3(0.1, 0.2, -0.3);

      final doc = FeatherProjectDocument.fromEditor(state);

      final loaded = EditorState(fileName: 'Other.feather');
      loaded.camera
        ..yaw = -2.0
        ..pitch = -1.0
        ..distance = 3.0
        ..target = Vector3.zero();

      doc.applyTo(loaded);
      expect(loaded.camera.yaw, closeTo(0.8, 1e-6));
      expect(loaded.camera.pitch, closeTo(0.45, 1e-6));
      expect(loaded.camera.distance, closeTo(12.0, 1e-6));
      expect(loaded.camera.target.x, closeTo(0.1, 1e-6));
      expect(loaded.camera.target.y, closeTo(0.2, 1e-6));
      expect(loaded.camera.target.z, closeTo(-0.3, 1e-6));
      // snapTo must leave nothing for the damping animation to do.
      expect(loaded.camera.isAnimating, isFalse);
      // And the first rendered pose already matches the saved one.
      expect(loaded.camera.currentYaw, closeTo(0.8, 1e-6));
      expect(loaded.camera.currentDistance, closeTo(12.0, 1e-6));
    });

    test('documents without a camera block leave the camera untouched', () {
      const legacyJson = '{"version":2,'
          '"fileName":"NoCam.feather",'
          '"texture":{"width":2048,"height":2048},'
          '"guideSurface":"Sphere",'
          '"brush":{"preset":"Basic Round","size":32.00,'
          '"opacity":1.000,"color":4278877482,"mirrorX":false,'
          '"mirrorY":false,"mirrorZ":false},'
          '"strokes":{"strokes":[],"selectedIds":[],"nextId":1}}';

      final parsed = FeatherProjectDocument.parse(legacyJson);
      expect(parsed.hasCamera, isFalse);

      final loaded = EditorState(fileName: 'X.feather');
      loaded.camera
        ..yaw = -1.1
        ..pitch = 0.3
        ..distance = 5.5;

      parsed.applyTo(loaded);
      expect(loaded.camera.yaw, closeTo(-1.1, 1e-9));
      expect(loaded.camera.pitch, closeTo(0.3, 1e-9));
      expect(loaded.camera.distance, closeTo(5.5, 1e-9));
    });
  });
}
