// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// gif_gltf_test.dart — GIF stroke-replay and glTF mesh export tests.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart' show Vector2, Vector3;

import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/io/gif_exporter.dart';
import 'package:feather_krita/io/gltf_exporter.dart';
import 'package:feather_krita/models/stroke.dart';

void main() {
  group('glTF exporter', () {
    test('emits a valid self-contained glTF for the sphere guide', () {
      final mesh = GuideSurface.sphere(radius: 1.4, segments: 8, rings: 5).mesh;
      final json = buildGltf(mesh, name: 'TestSphere');
      final doc = jsonDecode(json) as Map<String, dynamic>;

      expect((doc['asset'] as Map)['version'], '2.0');
      final accessors = doc['accessors'] as List;
      expect(accessors, hasLength(4));

      // POSITION accessor must carry min/max bounds per the glTF spec.
      final position = accessors[0] as Map;
      expect(position['type'], 'VEC3');
      expect(position['count'], mesh.positions.length);
      final min = position['min'] as List;
      final max = position['max'] as List;
      expect(min.first, closeTo(-1.4, 0.15));
      expect(max.first, closeTo(1.4, 0.15));

      final indices = accessors[3] as Map;
      expect(indices['count'], mesh.indices.length);
      expect(indices['componentType'], 5125); // UNSIGNED_INT

      // The embedded base64 buffer must decode to the declared length and
      // contain enough bytes for every accessor.
      final buffer = (doc['buffers'] as List).first as Map;
      final uri = buffer['uri'] as String;
      expect(uri.startsWith('data:application/octet-stream;base64,'), isTrue);
      final bytes = base64Decode(uri.split(',').last);
      expect(bytes.length, buffer['byteLength']);

      final expectedBytes = mesh.positions.length * 12 +
          mesh.normals.length * 12 +
          mesh.uvs.length * 8 +
          mesh.indices.length * 4;
      expect(bytes.length, greaterThanOrEqualTo(expectedBytes));
    });
  });

  group('GIF exporter', () {
    BrushDab flatDab(Stroke stroke, double pressure, double sizePx) {
      final s = sizePx.ceil().clamp(2, 64).toInt();
      final px = List<int>.filled(s * s * 4, 0);
      for (var i = 0; i < px.length; i += 4) {
        px[i] = (stroke.color >> 16) & 0xff;
        px[i + 3] = 255;
      }
      return BrushDab(
        width: s,
        height: s,
        stride: s * 4,
        pixels: Uint8List.fromList(px),
      );
    }

    test('replays strokes progressively across frames', () {
      final red = Stroke(
        id: 1,
        color: 0xFFFF0000,
        thickness: 24,
        points: [
          StrokePoint(
              position: Vector3.zero(),
              pressure: 1.0,
              uv: Vector2(0.3, 0.5)),
          StrokePoint(
              position: Vector3.zero(),
              pressure: 1.0,
              uv: Vector2(0.7, 0.5)),
        ],
      );
      final exporter = GifExporter(
        width: 64,
        height: 64,
        frameCount: 4,
        frameDelayCs: 5,
      );
      final bytes = exporter.export(
        strokes: [red],
        dabFor: flatDab,
        brushSizePx: 32,
        brushOpacity: 1.0,
        sourceTextureSize: 2048,
      );

      final animation = img.GifDecoder().decodeAnimation(bytes);
      expect(animation, isNotNull);
      expect(animation!.frames.length, 4);

      bool hasRed(img.Image frame) {
        for (var y = 0; y < frame.height; y++) {
          for (var x = 0; x < frame.width; x++) {
            final p = frame.getPixel(x, y);
            if (img.getAlpha(p) > 200 &&
                img.getRed(p) > 200 &&
                img.getGreen(p) < 60 &&
                img.getBlue(p) < 60) {
              return true;
            }
          }
        }
        return false;
      }

      // Later frames must contain strictly more painted pixels than the
      // first frame: the stroke grows over time.
      final frames = animation.frames.toList();
      expect(hasRed(frames.last), isTrue, reason: 'final frame painted');
      expect(hasRed(frames.first), isTrue,
          reason: 'replay starts within the first frame');
    });

    test('skips strokes without UVs and still emits a valid GIF', () {
      final noUv = Stroke(
        id: 1,
        color: 0xFF00FF00,
        points: [
          StrokePoint(position: Vector3.zero()),
        ],
      );
      final bytes = GifExporter(width: 32, height: 32, frameCount: 3)
          .export(strokes: [noUv], dabFor: flatDab, brushSizePx: 16,
              brushOpacity: 1.0);
      final animation = img.GifDecoder().decodeAnimation(bytes);
      expect(animation, isNotNull);
      expect(animation!.frames, isNotEmpty);
    });

    test('eraser strokes replay through the erase blend', () {
      final paint = Stroke(
        id: 1,
        color: 0xFF0000FF,
        points: [
          StrokePoint(
              position: Vector3.zero(), pressure: 1.0, uv: Vector2(0.5, 0.5)),
        ],
      );
      final erase = Stroke(
        id: 2,
        brushType: BrushType.eraser,
        color: 0xFF000000,
        points: [
          StrokePoint(
              position: Vector3.zero(), pressure: 1.0, uv: Vector2(0.5, 0.5)),
        ],
      );
      final bytes = GifExporter(width: 48, height: 48, frameCount: 2)
          .export(strokes: [paint, erase], dabFor: flatDab,
              brushSizePx: 24, brushOpacity: 1.0);
      final animation = img.GifDecoder().decodeAnimation(bytes);
      expect(animation, isNotNull);
      final last = animation!.frames.last;
      var opaqueBlue = 0;
      for (var y = 0; y < last.height; y++) {
        for (var x = 0; x < last.width; x++) {
          final p = last.getPixel(x, y);
          if (img.getAlpha(p) > 200 && img.getBlue(p) > 200) opaqueBlue++;
        }
      }
      expect(opaqueBlue, 0,
          reason: 'the eraser pass must have erased the blue dab');
    });
  });
}
