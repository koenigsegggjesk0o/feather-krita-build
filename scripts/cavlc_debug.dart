// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// cavlc_debug.dart — minimal controlled repro for CAVLC debugging.
// Encodes small frames with known content, writes .h264 annex-B files
// plus MP4s into scripts/out/ for ffmpeg analysis.

import 'dart:io';
import 'dart:typed_data';

import 'package:feather_krita/io/h264_encoder.dart';
import 'package:feather_krita/io/mp4_muxer.dart';

Uint8List gradientFrame(int w, int h, {int base = 128, int amp = 40}) {
  final f = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = (base + (amp * (x + y)) ~/ (w + h)).clamp(0, 255);
      final i = (y * w + x) * 4;
      f[i] = v;
      f[i + 1] = v;
      f[i + 2] = v;
      f[i + 3] = 0xFF;
    }
  }
  return f;
}

Uint8List spotFrame(int w, int h) {
  // Uniform background with one bright square inside the first MB.
  final f = Uint8List(w * h * 4);
  for (var i = 0; i < f.length; i += 4) {
    f[i] = 128;
    f[i + 1] = 128;
    f[i + 2] = 128;
    f[i + 3] = 0xFF;
  }
  for (var y = 4; y < 12; y++) {
    for (var x = 4; x < 12; x++) {
      final i = (y * w + x) * 4;
      f[i] = 250;
      f[i + 1] = 60;
      f[i + 2] = 40;
      f[i + 3] = 0xFF;
    }
  }
  return f;
}

void writeCase(String name, H264IdrEncoder enc, Uint8List frame) {
  enc.loadRgba(frame);
  final nal = enc.encodeIdr();
  final dir = Directory('scripts/out');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  // Annex-B: SPS + PPS + IDR with start codes.
  final out = BytesBuilder();
  out.add([0, 0, 0, 1]);
  out.add(enc.buildSps());
  out.add([0, 0, 0, 1]);
  out.add(enc.buildPps());
  out.add([0, 0, 0, 1]);
  out.add(nal);
  File('scripts/out/case_$name.h264').writeAsBytesSync(out.toBytes());
  final mp4 = Mp4Muxer(
    width: enc.width,
    height: enc.height,
    fps: 20,
    sps: enc.buildSps(),
    pps: enc.buildPps(),
    samples: [nal],
  ).mux();
  File('scripts/out/case_$name.mp4').writeAsBytesSync(mp4);
  print(
      'case_$name: flat=${enc.lastFlatMacroblocks} resid=${enc.lastResidualMacroblocks} pcm=${enc.lastPcmMacroblocks} nalBytes=${nal.length}');
}

void main(List<String> args) {
  final size = args.isNotEmpty ? int.parse(args[0]) : 32;
  writeCase(
      'gray',
      H264IdrEncoder(width: size, height: size, fps: 20),
      gradientFrame(size, size, amp: 0));
  writeCase(
      'gradient',
      H264IdrEncoder(width: size, height: size, fps: 20),
      gradientFrame(size, size));
  writeCase(
      'spot',
      H264IdrEncoder(width: size, height: size, fps: 20),
      spotFrame(size, size));
}
