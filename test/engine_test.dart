// Engine-level regression tests for the Feather-Krita 3D painting stack:
//   - TexturePainter: dab compositing (normal + erase), undo/redo
//   - StrokeManager: live mirror generation, undo/redo
//   - GuideSurface: sphere raycast (hit point / normal / UV / miss)
//   - PNG export round-trip via the image package
//
// The compositing tests use the REAL native bridge through the app's FFI
// wrapper, validating the engine path end-to-end.
import 'package:feather_krita/engine/camera_controller.dart';
import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/engine/stroke_manager.dart';
import 'package:feather_krita/engine/texture_painter.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/models/stroke.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart' hide Colors;

int pixelAlpha(TexturePainter tex, int x, int y) =>
    tex.pixels[y * tex.stride + x * 4 + 3];

int pixelChannel(TexturePainter tex, int x, int y, int ch) =>
    tex.pixels[y * tex.stride + x * 4 + ch];

void main() {
  group('TexturePainter compositing', () {
    test('composites a native red dab with normal blend', () {
      final engine = KritaBrushEngine();
      engine
        ..size = 32
        ..color = const BrushColor(255, 0, 0)
        ..opacity = 1.0;
      final dab = engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
      engine.dispose();

      final tex = TexturePainter(width: 64, height: 64);
      expect(tex.isEmpty, isTrue);
      final modified = tex.paintDab(dab, 0.5, 0.5);
      expect(modified, greaterThan(0));
      expect(pixelChannel(tex, 32, 32, 0), 255, reason: 'red at center');
      expect(pixelAlpha(tex, 32, 32), 255, reason: 'opaque at center');
      expect(pixelAlpha(tex, 0, 0), 0, reason: 'corner untouched');
    });

    test('erase blend removes painted pixels', () {
      final engine = KritaBrushEngine();
      engine..size = 32..opacity = 1.0;
      final dab = engine.generateDab(const BrushInput(x: 0, y: 0, pressure: 1.0));
      final eraser = engine.generateDab(BrushInput(
        x: 0,
        y: 0,
        pressure: 1.0,
        flags: BrushInputFlags(eraser: true),
      ));
      engine.dispose();

      final tex = TexturePainter(width: 64, height: 64)
        ..fill(200, 10, 10);
      expect(pixelAlpha(tex, 32, 32), 255);
      tex.paintDab(eraser, 0.5, 0.5, eraser: true);
      expect(pixelAlpha(tex, 32, 32), 0,
          reason: 'full-strength eraser must clear the center');
      // Unused normal dab must not have been required.
      expect(dab.isEmpty, isFalse);
    });

    test('undo/redo round-trips fills', () {
      final tex = TexturePainter(width: 16, height: 16)..fill(255, 0, 0);
      tex.fill(0, 0, 255);
      expect(pixelChannel(tex, 8, 8, 2), 255, reason: 'blue after 2nd fill');
      expect(tex.undo(), isTrue);
      expect(pixelChannel(tex, 8, 8, 0), 255, reason: 'red after undo');
      expect(tex.redo(), isTrue);
      expect(pixelChannel(tex, 8, 8, 2), 255, reason: 'blue after redo');
    });
  });

  group('StrokeManager mirror + history', () {
    test('live X mirror creates a mirrored copy of each stroke', () {
      final manager = StrokeManager();
      manager.setMirror(
        MirrorConfig(enabledX: true, origin: Vector3.zero()),
        recordUndo: false,
      );
      final original = Stroke(
        id: 7,
        color: 0xFFFF0000,
        thickness: 12,
        points: [
          StrokePoint(position: Vector3(1, 0.5, 0), pressure: 1),
          StrokePoint(position: Vector3(2, 0.25, 0), pressure: 0.8),
        ],
      );
      manager.addStroke(original);

      expect(manager.strokes.length, 2,
          reason: 'mirror must create one copy for the single enabled axis');
      final copy = manager.strokes.last;
      expect(copy.id, isNot(7));
      expect(copy.mirrorOfId, 7);
      // Local-space points stay untouched — the flip lives in the transform
      // matrix (local-to-world), so both copies share one local definition.
      expect(copy.points.first.position.x, closeTo(1, 1e-9));
      final world = copy.points.first.position.clone();
      copy.transform.transform3(world);
      expect(world.x, closeTo(-1, 1e-9),
          reason: 'world-space X negated by the mirror transform');
      expect(world.y, closeTo(0.5, 1e-9),
          reason: 'Y stays untouched on X mirror');
      expect(copy.thickness, 12);
    });

    test('undo reverts the stroke add', () {
      final manager = StrokeManager()
        ..setMirror(MirrorConfig(), recordUndo: false);
      manager.addStroke(Stroke(id: 1, points: [
        StrokePoint(position: Vector3.zero(), pressure: 1),
      ]));
      expect(manager.strokes.length, 1);
      expect(manager.canUndo, isTrue);
      expect(manager.undo(), isTrue);
      expect(manager.strokes.length, 0);
      expect(manager.redo(), isTrue);
      expect(manager.strokes.length, 1);
    });
  });

  group('GuideSurface raycast', () {
    test('ray toward sphere center hits the front surface', () {
      final sphere = GuideSurface.sphere(radius: 1.0, segments: 32, rings: 16);
      final ray = Ray.originDirection(Vector3(0, 0, 5), Vector3(0, 0, -1));
      final hit = sphere.raycast(ray);
      expect(hit, isNotNull);
      expect(hit!.distance, closeTo(4.0, 1e-3));
      expect(hit.point.x, closeTo(0, 1e-3));
      expect(hit.point.y, closeTo(0, 1e-3));
      expect(hit.point.z, closeTo(1, 1e-3));
      expect(hit.normal.z, greaterThan(0.99),
          reason: 'front-face normal points at the viewer');
      expect(hit.uv.x, inInclusiveRange(0, 1));
      expect(hit.uv.y, inInclusiveRange(0, 1));
    });

    test('ray pointing away from the sphere misses', () {
      final sphere = GuideSurface.sphere(radius: 1.0);
      final ray = Ray.originDirection(Vector3(0, 0, 5), Vector3(0, 0, 1));
      expect(sphere.raycast(ray), isNull);
    });
  });

  group('PNG export', () {
    test('texture pixels survive a PNG encode/decode round-trip', () {
      final tex = TexturePainter(width: 64, height: 64)..fill(255, 0, 0);
      final image = img.Image(tex.width, tex.height);
      for (var y = 0; y < tex.height; y++) {
        for (var x = 0; x < tex.width; x++) {
          final i = y * tex.stride + x * 4;
          // image 3.x packs pixels #AABBGGRR — R in the LOW byte (the same
          // layout the production exporters use; packing ARGB here would
          // swap red and blue in the exported file).
          final packed = (tex.pixels[i + 3] << 24) |
              (tex.pixels[i + 2] << 16) |
              (tex.pixels[i + 1] << 8) |
              tex.pixels[i];
          image.setPixel(x, y, packed);
        }
      }
      final png = img.encodePng(image);
      expect(png, isNotEmpty);

      final decoded = img.decodePng(png)!;
      final back = decoded.getPixel(10, 10);
      expect(img.getRed(back), 255, reason: 'red channel');
      expect(img.getGreen(back), 0, reason: 'green channel');
      expect(img.getBlue(back), 0, reason: 'blue channel');
      expect(img.getAlpha(back), 255, reason: 'alpha');
    });
  });

  group('CameraController damping', () {
    test('orbit damps gradually and settles', () {
      final camera = CameraController(yaw: 0.0, pitch: -0.4, distance: 6.0);
      camera.orbit(0.8, 0.0);

      // First tick must move the camera but NOT snap to the target.
      expect(camera.tick(1 / 60), isTrue, reason: 'damping in flight');
      expect(camera.tick(1 / 60), isTrue,
          reason: 'still converging after 2 frames');

      // Repeated small-dt ticks converge within a sane number of frames.
      var ticks = 2;
      while (camera.tick(1 / 60) && ticks < 600) {
        ticks++;
      }
      expect(ticks, lessThan(600),
          reason: 'damping must settle (it never did)');
    });

    test('tick treats non-positive dt as one frame', () {
      final camera = CameraController(yaw: 0.0, pitch: -0.4, distance: 6.0);
      camera.orbit(0.5, 0.0);
      expect(camera.tick(0), isTrue);
    });

    test('a settled camera reports no change', () {
      final camera = CameraController(yaw: 0.0, pitch: -0.4, distance: 6.0);
      expect(camera.tick(1 / 60), isFalse,
          reason: 'no pending target — must be idle (ticker muting relies '
              'on this signal)');
    });
  });
}
