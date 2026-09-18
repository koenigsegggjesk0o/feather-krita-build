// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// cavlc_bisect.dart — single/two-MB controlled frames to bisect the
// ffmpeg decode failure: DC-only, luma AC, chroma residual, etc.

import 'dart:io';
import 'dart:typed_data';

import 'package:feather_krita/io/h264_encoder.dart';

Uint8List gray(int w, int h, int v) {
  final f = Uint8List(w * h * 4);
  for (var i = 0; i < f.length; i += 4) {
    f[i] = v;
    f[i + 1] = v;
    f[i + 2] = v;
    f[i + 3] = 0xFF;
  }
  return f;
}

/// Adds a luminance-only offset with a horizontal ramp.
Uint8List lumaRamp(int w, int h, int base, int amp) {
  final f = gray(w, h, base);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = (amp * x) ~/ w;
      final i = (y * w + x) * 4;
      final v = (base + d).clamp(0, 255);
      f[i] = v;
      f[i + 1] = v;
      f[i + 2] = v;
    }
  }
  return f;
}

/// Adds a red tint ramp (moves luma AND chroma).
Uint8List chromaRamp(int w, int h, int base, int amp) {
  final f = gray(w, h, base);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = (amp * x) ~/ w;
      final i = (y * w + x) * 4;
      f[i] = (base + d).clamp(0, 255);
      f[i + 1] = base;
      f[i + 2] = base;
    }
  }
  return f;
}

Uint8List pureChromaRamp(int w, int h, int base, int amp) {
  final f = gray(w, h, base);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = (amp * x) ~/ w;
      final i = (y * w + x) * 4;
      f[i] = (base + d).clamp(0, 255);      // R up
      f[i + 1] = (base - d).clamp(0, 255);  // G down
      f[i + 2] = (base - d ~/ 2).clamp(0, 255); // B down half
    }
  }
  return f;
}

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

void writeCase(String name, H264IdrEncoder enc, Uint8List frame) {
  enc.loadRgba(frame);
  H264IdrEncoder.debugTrace = (line) => print('  T $line');
  final nal = enc.encodeIdr();
  H264IdrEncoder.debugTrace = null;
  final dir = Directory('scripts/out');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final out = BytesBuilder();
  out.add([0, 0, 0, 1]);
  out.add(enc.buildSps());
  out.add([0, 0, 0, 1]);
  out.add(enc.buildPps());
  out.add([0, 0, 0, 1]);
  out.add(nal);
  File('scripts/out/bisect_$name.h264').writeAsBytesSync(out.toBytes());
  print(
      '$name: flat=${enc.lastFlatMacroblocks} resid=${enc.lastResidualMacroblocks} pcm=${enc.lastPcmMacroblocks}');
}

void main() {
  // V1: single MB, uniform offset -> luma DC only, no AC, no chroma.
  writeCase('v1_dconly', H264IdrEncoder(width: 16, height: 16, fps: 20),
      gray(16, 16, 140));
  // V2: single MB, luma ramp -> luma DC + AC.
  writeCase('v2_lumaac', H264IdrEncoder(width: 16, height: 16, fps: 20),
      lumaRamp(16, 16, 128, 60));
  // V3: single MB, chroma ramp -> chroma DC/AC too.
  writeCase('v3_chroma', H264IdrEncoder(width: 16, height: 16, fps: 20),
      chromaRamp(16, 16, 128, 80));
  // V4: two MBs, luma ramp across both.
  writeCase('v4_twomb', H264IdrEncoder(width: 32, height: 16, fps: 20),
      lumaRamp(32, 16, 128, 90));
  // V5: strong ramp (forces bigger levels / escapes).
  writeCase('v5_strong', H264IdrEncoder(width: 16, height: 16, fps: 20),
      lumaRamp(16, 16, 60, 160));
  // V6: mild chroma ramp (small chroma levels, no escapes).
  writeCase('v6_mildchroma', H264IdrEncoder(width: 16, height: 16, fps: 20),
      chromaRamp(16, 16, 128, 12));
  // V7: strong chroma ramp at high QP (chroma quantizes to ~0).
  writeCase('v7_highqp', H264IdrEncoder(width: 16, height: 16, fps: 20, qp: 40),
      chromaRamp(16, 16, 128, 80));
  for (final amp in [20, 30, 40, 50, 60, 80]) {
    writeCase('a$amp', H264IdrEncoder(width: 16, height: 16, fps: 20),
        chromaRamp(16, 16, 128, amp));
  }
  // V10: 16x16 diagonal gradient (single MB, tc>10 -> suffix_length=1
  // first-level path).
  writeCase('v10_diag', H264IdrEncoder(width: 16, height: 16, fps: 20),
      gradientFrame(16, 16));
  // V11: same but 32x32 (4 MBs, the known-failing gradient geometry).
  writeCase('v11_diag32', H264IdrEncoder(width: 32, height: 32, fps: 20),
      gradientFrame(32, 32));
  for (final qp in [20, 26, 32, 38]) {
    writeCase('q$qp', H264IdrEncoder(width: 32, height: 32, fps: 20, qp: qp),
        gradientFrame(32, 32));
  }
  for (final amp in [10, 20, 30, 40]) {
    writeCase('g$amp', H264IdrEncoder(width: 32, height: 32, fps: 20),
        gradientFrame(32, 32, amp: amp));
  }
  // Pure chroma variation with FLAT luma: set r=128+d, g=b=128-d/2 so
  // luma 66r+129g+25b stays ~constant while chroma varies.
  writeCase('v8_purechroma', H264IdrEncoder(width: 16, height: 16, fps: 20),
      pureChromaRamp(16, 16, 128, 80));
  writeCase('v9_purechroma_mild', H264IdrEncoder(width: 16, height: 16, fps: 20),
      pureChromaRamp(16, 16, 128, 40));
}
