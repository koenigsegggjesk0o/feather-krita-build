// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// mp4_cases.dart — Targeted encoder test cases (dart run).

import 'dart:io';
import 'dart:typed_data';

import 'package:feather_krita/io/h264_encoder.dart';
import 'package:feather_krita/io/mp4_muxer.dart';

Uint8List flatFrame(int w, int h, int v) {
  final f = Uint8List(w * h * 4);
  for (var i = 0; i < f.length; i += 4) {
    f[i] = v;
    f[i + 1] = v;
    f[i + 2] = v;
    f[i + 3] = 0xFF;
  }
  return f;
}

void writeCase(String name, H264IdrEncoder enc, Uint8List frame) {
  enc.loadRgba(frame);
  final nal = enc.encodeIdr();
  final mp4 = Mp4Muxer(
    width: enc.width,
    height: enc.height,
    fps: 20,
    sps: enc.buildSps(),
    pps: enc.buildPps(),
    samples: [nal],
  ).mux();
  final dir = Directory('scripts/out');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('scripts/out/case_$name.mp4').writeAsBytesSync(mp4);
  print('case_$name: flat=${enc.lastFlatMacroblocks} pcm=${enc.lastPcmMacroblocks}');
}

void main(List<String> args) {
  final size = args.isNotEmpty ? int.parse(args[0]) : 48;
  // Case 1: mid-gray — every macroblock should be flat/DC, no PCM.
  writeCase(
      'gray', H264IdrEncoder(width: size, height: size, fps: 20),
      flatFrame(size, size, 128));
  // Case 2: black — MB(0,0) forced to PCM (DC ref unavailable = 128).
  writeCase(
      'black', H264IdrEncoder(width: size, height: size, fps: 20),
      flatFrame(size, size, 0));
}
