// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// mb_trace.dart — Trace the first macroblocks' bitstream decisions.

import 'dart:typed_data';

import 'package:feather_krita/io/h264_encoder.dart';

void main() {
  final enc = H264IdrEncoder(width: 512, height: 512, fps: 20);
  // Flat dark frame (like export frame 0: black background).
  final rgba = Uint8List(512 * 512 * 4); // all zeros = black
  enc.loadRgba(rgba);

  final sps = enc.buildSps();
  final pps = enc.buildPps();
  print('SPS: ${sps.take(10).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
  print('PPS: ${pps.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

  final nal = enc.encodeIdr();
  print('IDR NAL: ${nal.length} bytes');
  print('first 24 bytes: ${nal.take(24).map((b) => b.toRadixString(2).padLeft(8, '0')).join(' ')}');
  print('flat=${enc.lastFlatMacroblocks} pcm=${enc.lastPcmMacroblocks}');
}
