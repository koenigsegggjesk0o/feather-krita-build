// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// mp4_exporter_test.dart — MP4 (H.264) export pipeline tests.
//
// Structure-level assertions always run. The external ffmpeg checks run
// only when ffprobe/ffmpeg exist in the environment (they auto-skip in
// CI sandboxes without ffmpeg — the sandbox loop machine has them).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/synthetic_dab.dart';
import 'package:feather_krita/io/h264_encoder.dart';
import 'package:feather_krita/io/mp4_exporter.dart';
import 'package:feather_krita/io/mp4_muxer.dart';
import 'package:feather_krita/models/stroke.dart';

Stroke _stroke(int id, double x0, double y0, double x1, double y1,
    {int color = 0xFFCC1A1A, BrushType type = BrushType.basic}) {
  final points = <StrokePoint>[];
  for (var i = 0; i <= 16; i++) {
    final t = i / 16;
    points.add(StrokePoint(
      position: Vector3(0, 0, 0),
      pressure: 0.4 + 0.5 * math.sin(t * math.pi).abs(),
      uv: Vector2(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t),
    ));
  }
  return Stroke(
      id: id, color: color, thickness: 50, brushType: type, points: points);
}


Uint8List _diagonalGradient(int w, int h) {
  final f = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = 128 + ((40 * (x + y)) ~/ (w + h));
      final i = (y * w + x) * 4;
      f[i] = v;
      f[i + 1] = v;
      f[i + 2] = v;
      f[i + 3] = 0xFF;
    }
  }
  return f;
}

Uint8List _encodeSampleVideo(int frames) {
  return Mp4Exporter(
    width: 128,
    height: 128,
    frameCount: frames,
    fps: 20,
  ).export(
    strokes: [
      _stroke(1, 0.15, 0.2, 0.85, 0.4),
      _stroke(2, 0.7, 0.6, 0.25, 0.8, color: 0xFF1A4DE6),
      _stroke(3, 0.5, 0.2, 0.45, 0.6,
          color: 0xFFE6E6E6, type: BrushType.eraser),
    ],
    dabFor: (stroke, pressure, sizePx) =>
        syntheticDab(sizePx * pressure, stroke.color),
    brushSizePx: 50,
    brushOpacity: 0.9,
    sourceTextureSize: 2048,
  );
}

int _boxEnd(Uint8List d, int start, int end) {
  // Returns offset after the box starting at [start].
  final size = (d[start] << 24) | (d[start + 1] << 16) |
      (d[start + 2] << 8) | d[start + 3];
  return start + size;
}

int _findBox(Uint8List d, String type, int from, int to) {
  for (var i = from; i < to - 4; i++) {
    if (d[i + 4] == type.codeUnitAt(0) &&
        d[i + 5] == type.codeUnitAt(1) &&
        d[i + 6] == type.codeUnitAt(2) &&
        d[i + 7] == type.codeUnitAt(3)) {
      // Verify it is a box start: size preceding must be sane.
      final size = (d[i] << 24) | (d[i + 1] << 16) |
          (d[i + 2] << 8) | d[i + 3];
      if (size >= 8 && i >= 4) return i;
    }
  }
  return -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('H264IdrEncoder', () {
    test('produces flat macroblocks for a uniform frame', () {
      final enc = H264IdrEncoder(width: 64, height: 64, fps: 20);
      final rgba = Uint8List(64 * 64 * 4);
      enc.loadRgba(rgba);
      final nal = enc.encodeIdr();
      // Every block is flat EXCEPT MB(0,0): an all-zero frame is Y=16,
      // while the corner DC prediction with no reference samples is 128
      // (spec 8.3.3.2) → error > threshold → the corner goes I_PCM.
      expect(enc.lastFlatMacroblocks, 15);
      expect(enc.lastPcmMacroblocks, 1);
      // NAL type 5: header byte 0x65.
      expect(nal[0], 0x65);
      expect(nal.length, greaterThan(4));
    });

    test('uses PCM macroblocks for noisy regions', () {
      final enc = H264IdrEncoder(width: 64, height: 64, fps: 20);
      final rng = math.Random(7);
      final rgba = Uint8List(64 * 64 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = rng.nextInt(256);
        rgba[i + 1] = rng.nextInt(256);
        rgba[i + 2] = rng.nextInt(256);
        rgba[i + 3] = 255;
      }
      enc.loadRgba(rgba);
      enc.encodeIdr();
      // Nearly every macroblock must exceed the flat threshold.
      expect(enc.lastPcmMacroblocks, greaterThan(10));
    });

    test('builds SPS/PPS with baseline profile', () {
      final enc = H264IdrEncoder(width: 512, height: 300, fps: 20);
      final sps = enc.buildSps();
      final pps = enc.buildPps();
      expect(sps[0], 0x67); // SPS NAL header
      expect(sps[1], 66); // baseline profile
      expect(pps[0], 0x68);
      // 512x300 pads to 512x304 (19 MB rows); crop removes 4 rows of
      // pixels = 2 chroma crop units bottom.
      expect(enc.mbWidth, 32);
      expect(enc.mbHeight, 19);
      expect(enc.codedHeight, 304);
    });
  });

  group('Mp4Muxer', () {
    test('emits ftyp/mdat/moov with avc1 sample description', () {
      final enc = H264IdrEncoder(width: 64, height: 64, fps: 20);
      final rgba = Uint8List(64 * 64 * 4);
      enc.loadRgba(rgba);
      final nal = enc.encodeIdr();
      final mp4 = Mp4Muxer(
        width: 64,
        height: 64,
        fps: 20,
        sps: enc.buildSps(),
        pps: enc.buildPps(),
        samples: [nal, nal],
      ).mux();

      expect(mp4.length, greaterThan(16));
      // ftyp at offset 0.
      expect(String.fromCharCodes(mp4.sublist(4, 8)), 'ftyp');
      final ftypEnd = (mp4[0] << 24) | (mp4[1] << 16) |
          (mp4[2] << 8) | mp4[3];
      final mdatAt = _findBox(mp4, 'mdat', ftypEnd, mp4.length);
      expect(mdatAt, greaterThan(0));
      final moovAt = _findBox(mp4, 'moov', mdatAt + 8, mp4.length);
      expect(moovAt, greaterThan(0));
      // moov contains mvhd/trak/avc1/avcC.
      final moovSize = (mp4[moovAt] << 24) | (mp4[moovAt + 1] << 16) |
          (mp4[moovAt + 2] << 8) | mp4[moovAt + 3];
      final moovEnd = moovAt + moovSize;
      expect(_findBox(mp4, 'mvhd', moovAt, moovEnd), greaterThan(0));
      expect(_findBox(mp4, 'trak', moovAt, moovEnd), greaterThan(0));
      expect(_findBox(mp4, 'avcC', moovAt, mp4.length), greaterThan(0));
      // stsz sample count == 2 (12 bytes into the stsz payload).
      final stsz = _findBox(mp4, 'stsz', moovAt, mp4.length);
      expect(stsz, greaterThan(0));
      final sampleCount = (mp4[stsz + 16] << 24) | (mp4[stsz + 17] << 16) |
          (mp4[stsz + 18] << 8) | mp4[stsz + 19];
      expect(sampleCount, 2);
    });
  });

  group('Mp4Exporter', () {
    test('produces a structurally valid MP4 for stroke replay', () {
      final bytes = _encodeSampleVideo(6);
      expect(bytes.length, greaterThan(1000));
      expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');
      // Full box traversal: sum of top-level sizes == file size.
      var off = 0;
      var boxes = 0;
      while (off < bytes.length) {
        final size = (bytes[off] << 24) | (bytes[off + 1] << 16) |
            (bytes[off + 2] << 8) | bytes[off + 3];
        expect(size, greaterThanOrEqualTo(8), reason: 'box at $off');
        off += size;
        boxes++;
      }
      expect(off, bytes.length);
      expect(boxes, 3); // ftyp + mdat + moov
    });

    test('scales frame count with quality-style frame parameter', () {
      final small = _encodeSampleVideo(4);
      final big = _encodeSampleVideo(10);
      // More frames → strictly larger mdat (each frame is an IDR).
      int mdatSize(Uint8List d) {
        final i = _findBox(d, 'mdat', 0, d.length);
        return (d[i] << 24) | (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3];
      }

      expect(mdatSize(big), greaterThan(mdatSize(small)));
    });
  });


      test('CAVLC residual path is gated off by default', () {
        // A diagonal gradient cannot be flat-coded: with the default
        // flags every macroblock must fall back to I_PCM.
        final enc = H264IdrEncoder(width: 16, height: 16);
        enc.loadRgba(_diagonalGradient(16, 16));
        enc.encodeIdr();
        expect(enc.lastResidualMacroblocks, 0);
        expect(enc.lastPcmMacroblocks + enc.lastFlatMacroblocks, 1);
      });

      test('CAVLC residual path engages when explicitly enabled', () {
        final enc =
            H264IdrEncoder(width: 16, height: 16, enableResiduals: true);
        enc.loadRgba(_diagonalGradient(16, 16));
        enc.encodeIdr();
        expect(enc.lastResidualMacroblocks, 1);
      });
  group('external ffmpeg verification', () {
    final hasFfmpeg = () {
      try {
        final r = Process.runSync('ffprobe', ['-version']);
        return r.exitCode == 0;
      } catch (_) {
        return false;
      }
    }();

    test('ffmpeg decodes the stream without errors', () {
      if (!hasFfmpeg) {
        // Sandboxes without ffmpeg: structure tests above already cover
        // the pipeline; skip external validation.
        return;
      }
      final tmp = Directory.systemTemp.createTempSync('fkr_mp4');
      final path = '${tmp.path}/out.mp4';
      File(path).writeAsBytesSync(_encodeSampleVideo(6));
      addTearDown(() => tmp.deleteSync(recursive: true));

      final probe = Process.runSync('ffprobe', [
        '-v', 'error',
        '-show_entries', 'stream=codec_name,width,height,nb_frames',
        '-of', 'csv=p=0', path,
      ]);
      expect(probe.exitCode, 0, reason: probe.stderr);
      expect(probe.stdout, contains('h264'));
      expect(probe.stdout, contains('128'));
      expect(probe.stdout, contains('6'));

      final decode = Process.runSync('ffmpeg', [
        '-v', 'error', '-i', path, '-f', 'null', '-',
      ]);
      expect(decode.stderr, isEmpty, reason: 'decode errors: ${decode.stderr}');
    });
  });
}
