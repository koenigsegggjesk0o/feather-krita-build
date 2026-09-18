// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// h264_encoder.dart — Pure-Dart H.264 Baseline IDR-frame encoder.
//
// Every macroblock is coded as one of
//
//   - I_16x16 flat   (V/H/DC prediction, zero residuals — 3..6 bits),
//   - I_16x16 resid. (V/H/DC prediction + CAVLC-coded transform
//     residuals for luma DC, 15 luma AC blocks, chroma DC 2x2 and
//     4 chroma AC blocks per plane), or
//   - I_PCM          (lossless sample copy — 384 bytes at 4:2:0),
//
// chosen per macroblock by reconstruction error and bit cost.
//
// The residual pipeline mirrors FFmpeg's decoder arithmetic exactly
// (the decoder this encoder is verified against):
//
//   dequant:  stored = (level * qmul + 32) >> 6
//             with qmul = kDequant4Init[qp%6][class] * 16 << (qp~/6 + 2)
//             and class = (col&1) + (row&1)  (ff_h264_dequant4_coeff_init)
//   luma DC:  blockDC = (H' * d * H'^T) * qmulDC + 128 >> 8
//   chromaDC: blockDC = (H2 * d * H2^T) * qmulC >> 7
//   idct:     block[0] += 32; two-pass butterfly (>>1 on odd rows/cols),
//             dst = clip(pred + (z >> 6)); DC-only blocks use the
//             fast path dst = clip(pred + (block[0] + 32) >> 6).
//
// The forward transform is the exact rational inverse of that idct:
// W = 64 * P^-1 * R * P^-T with P the butterfly matrix and
// 20*P^-1 = [[5,5,5,5],[8,4,-4,-8],[5,-5,-5,5],[4,-8,8,-4]], so
// T = 25/4 * W and levels are round(256*T / (25*qmul)).
//
// Because the encoder reproduces the decoder's fixed-point pipeline
// bit for bit, the decoded output equals the encoder's reconstruction
// by construction; ffmpeg round-trips verify this empirically.
//
// CAVLC tables live in h264_cavlc_tables.dart (transcribed from
// FFmpeg h264_cavlc.c). Level coding implements the full suffixLength
// state machine including the first-level -2 adjustment when
// TrailingOnes < 3 and the p=14/15 escape codes.

import 'dart:math' as math;
import 'dart:typed_data';

import 'h264_cavlc_tables.dart';

/// LSB-first accumulator? No — MSB-first bit writer as required by
/// H.264 NAL syntax.
class BitWriter {
  final BytesBuilder _bytes = BytesBuilder();
  int _acc = 0;
  int _n = 0;

  int get bitLength => _bytes.length * 8 + _n;

  /// Writes [n] bits of [v], most-significant first.
  void u(int n, int v) {
    assert(n >= 0 && v >= 0 && (n == 0 || v < (1 << n)), 'u($n, $v)');
    for (var i = n - 1; i >= 0; i--) {
      _put1((v >> i) & 1);
    }
  }

  void u1(int b) => _put1(b & 1);

  /// Unsigned Exp-Golomb (ue).
  void ue(int v) {
    assert(v >= 0);
    final code = v + 1;
    final len = _bitLen(code);
    u(len - 1, 0); // leading zeros
    u(len, code);
  }

  /// Signed Exp-Golomb (se).
  void se(int v) {
    final mapped = v > 0 ? 2 * v - 1 : -2 * v;
    ue(mapped);
  }

  /// Unary code: [v] zeros followed by a '1'.
  void unary(int v) {
    for (var i = 0; i < v; i++) {
      _put1(0);
    }
    _put1(1);
  }

  /// Aligns to the next byte boundary with zero bits.
  void byteAlign() {
    while (_n != 0) {
      _put1(0);
    }
  }

  /// Appends the rbsp_trailing_bits() stop bit + alignment.
  void rbspTrailing() {
    _put1(1);
    byteAlign();
  }

  Uint8List takeBytes() {
    assert(_n == 0, 'unterminated byte; call byteAlign()/rbspTrailing()');
    return _bytes.toBytes();
  }

  void _put1(int b) {
    _acc = (_acc << 1) | (b & 1);
    _n++;
    if (_n == 8) {
      _bytes.addByte(_acc & 0xff);
      _acc = 0;
      _n = 0;
    }
  }

  static int _bitLen(int v) {
    var len = 0;
    while (v > 0) {
      len++;
      v >>= 1;
    }
    return len;
  }
}

/// RBSP → EBSP emulation-prevention: after two consecutive zero bytes,
/// any byte <= 3 gets a 0x03 stuffed after the zero pair.
Uint8List rbspToEbsp(Uint8List rbsp) {
  final out = BytesBuilder();
  var zeros = 0;
  for (final b in rbsp) {
    if (zeros >= 2 && b <= 3) {
      out.addByte(3);
      zeros = 0;
    }
    out.addByte(b);
    zeros = b == 0 ? zeros + 1 : 0;
  }
  return out.toBytes();
}

/// Symmetric integer rounding of [numerator]/[den] (den > 0).
int _symRound(int numerator, int den) {
  if (numerator >= 0) {
    return (numerator + den ~/ 2) ~/ den;
  }
  return -((-numerator + den ~/ 2) ~/ den);
}

/// 20 * P^-1 for the ffmpeg idct butterfly P (exact rational inverse).
const List<List<int>> _invP20 = <List<int>>[
  <int>[5, 5, 5, 5],
  <int>[8, 4, -4, -8],
  <int>[5, -5, -5, 5],
  <int>[4, -8, 8, -4],
];

/// H' — the I_16x16 luma-DC Hadamard (symmetric, H'*H'^T = 4 I).
const List<List<int>> _hadamard4 = <List<int>>[
  <int>[1, 1, 1, 1],
  <int>[1, 1, -1, -1],
  <int>[1, -1, -1, 1],
  <int>[1, -1, 1, -1],
];

/// H.264 Baseline, IDR-only, I_16x16 (flat / CAVLC residual) + I_PCM
/// macroblock encoder.
class H264IdrEncoder {
  H264IdrEncoder({
    required this.width,
    required this.height,
    this.fps = 20,
    this.flatThreshold = 6,
    this.qp = 26,
    this.enableResiduals = false,
    int? residualMaxErr,
  })  : assert(width > 0 && height > 0),
        assert(qp >= 12 && qp <= 42),
        residualMaxErr = residualMaxErr ?? 6 + (qp >> 1),
        mbWidth = (width + 15) >> 4,
        mbHeight = (height + 15) >> 4 {
    _y = Uint8List(mbWidth * 16 * mbHeight * 16);
    _cb = Uint8List(mbWidth * 8 * mbHeight * 8);
    _cr = Uint8List(mbWidth * 8 * mbHeight * 8);
    _yRec = Uint8List.fromList(_y);
    _cbRec = Uint8List.fromList(_cb);
    _crRec = Uint8List.fromList(_cr);
    _chromaQp = kChromaQpTable[qp];
  }

  final int width;
  final int height;
  final double fps;

  /// Max per-sample error tolerated for a predicted (flat) macroblock.
  /// Larger values shrink the file; 6 is visually lossless for painting
  /// content after the limited-range round-trip.
  final int flatThreshold;

  /// Quantization parameter (12..42). Lower = better quality + bigger
  /// files. 26 is a good default for painting content.
  final int qp;

  /// Max per-sample reconstruction error tolerated for a residual
  /// macroblock before falling back to I_PCM.
  final int residualMaxErr;

  /// When false the encoder emits only flat I_16x16 + I_PCM macroblocks
  /// (the v0.12-validated behavior). The CAVLC residual path passes an
  /// internal round-trip and single-MB ffmpeg checks, but still desyncs
  /// ffmpeg on some multi-macroblock content; enable only for testing.
  final bool enableResiduals;

  final int mbWidth;
  final int mbHeight;

  late final int _chromaQp;

  late final Uint8List _y;
  late final Uint8List _cb;
  late final Uint8List _cr;
  // Reconstruction buffers (decoder's view) used as prediction reference.
  late final Uint8List _yRec;
  late final Uint8List _cbRec;
  late final Uint8List _crRec;

  int get codedWidth => mbWidth * 16;
  int get codedHeight => mbHeight * 16;

  /// Statistics from the last encoded frame.
  int lastPcmMacroblocks = 0;
  int lastFlatMacroblocks = 0;
  int lastResidualMacroblocks = 0;

  // Per-MB scratch. _tY holds T = 25/4 * W per 4x4 block (16 blocks),
  // _levY the quantized AC levels (DC slot 0 unused for I_16x16).
  late final Int32List _predY = Int32List(256);
  late final Int32List _predC = Int32List(64);
  late final Int32List _tY = Int32List(256);
  late final Int32List _levY = Int32List(256);
  late final Int32List _tCb = Int32List(64);
  late final Int32List _tCr = Int32List(64);
  late final Int32List _levCb = Int32List(64);
  late final Int32List _levCr = Int32List(64);
  late final Int32List _dcLevels = Int32List(16);
  late final Int32List _chDcLevels = Int32List(8); // Cb then Cr
  // Pending per-MB reconstruction (blitted into the *_Rec buffers only
  // after the residual path wins the mode decision).
  late final Int32List _recY = Int32List(256);
  late final Int32List _recCb = Int32List(64);
  late final Int32List _recCr = Int32List(64);
  late final Int32List _stored = Int32List(16);
  // Pending nnz record (24 bytes) committed after the mode decision.
  late final Uint8List _nnzPending = Uint8List(24);

  // Non-zero-count state mirroring the decoder's non_zero_count arrays:
  // per MB 24 bytes = 16 luma (raster 4x4) + 4 Cb + 4 Cr (raster 2x2).
  // PCM macroblocks store 16 everywhere; unavailable neighbours are 64.
  late final Uint8List _nnz = Uint8List(mbWidth * mbHeight * 24);

  /// Marks which macroblocks were coded as PCM. Reset every frame.
  late final List<bool> _mbIsPcm =
      List<bool>.filled(mbWidth * mbHeight, false);

  /// Linear index of the MB currently being encoded (for intra-MB nC
  /// lookups) — the decoder derives nC from blocks parsed within the
  /// same MB, so intra-MB neighbours must read the pending record.
  int _curMb = -1;

  /// Debug: when non-null, receives one line per CAVLC block written
  /// (block kind, tc, t1, levels) plus macroblock headers.
  static void Function(String line)? debugTrace;

  void _trace(String line) {
    if (debugTrace != null) debugTrace!(line);
  }

  // ---------------------------------------------------------------------
  // Parameter sets
  // ---------------------------------------------------------------------

  /// SPS NAL (EBSP, no start code).
  Uint8List buildSps() {
    final b = BitWriter();
    // NAL header: forbidden_zero(1)=0, nal_ref_idc(2)=3, nal_unit_type(5)=7
    b.u(1, 0);
    b.u(2, 3);
    b.u(5, 7);
    b.u(8, 66); // profile_idc: baseline
    b.u(8, 0xC0); // constraint_set0/1 flags
    b.u(8, 30); // level_idc 3.0
    b.ue(0); // seq_parameter_set_id
    b.ue(0); // log2_max_frame_num_minus4 → 4 bits
    b.ue(2); // pic_order_cnt_type = 2 (no POC syntax, IDR-only)
    b.ue(1); // max_num_ref_frames
    b.u(1, 0); // gaps_in_frame_num_value_allowed_flag
    b.ue(mbWidth - 1); // pic_width_in_mbs_minus1
    b.ue(mbHeight - 1); // pic_height_in_map_units_minus1
    b.u(1, 1); // frame_mbs_only_flag
    b.u(1, 1); // direct_8x8_inference_flag
    final cropX = codedWidth - width;
    final cropY = codedHeight - height;
    if (cropX > 0 || cropY > 0) {
      b.u(1, 1); // frame_cropping_flag
      // 4:2:0: horizontal crop units = 2 px, vertical = 2 px.
      b.ue(cropX ~/ 2); // left
      b.ue(cropX ~/ 2); // right
      b.ue(cropY ~/ 2); // top
      b.ue(cropY ~/ 2); // bottom
    } else {
      b.u(1, 0);
    }
    // VUI: only the timing info so players infer the frame rate.
    b.u(1, 0); // aspect_ratio_info_present_flag
    b.u(1, 0); // overscan_info_present_flag
    b.u(1, 0); // video_signal_type_present_flag
    b.u(1, 0); // chroma_loc_info_present_flag
    b.u(1, 1); // timing_info_present_flag
    final numUnits = 1000;
    final timeScale = (2 * fps * numUnits).round();
    b.u(32, numUnits);
    b.u(32, timeScale);
    b.u(1, 1); // fixed_frame_rate_flag
    b.u(1, 0); // nal_hrd_parameters_present_flag
    b.u(1, 0); // vcl_hrd_parameters_present_flag
    b.u(1, 0); // pic_struct_present_flag
    b.u(1, 0); // bitstream_restriction_flag
    b.rbspTrailing();
    return rbspToEbsp(b.takeBytes());
  }

  /// PPS NAL (EBSP, no start code).
  Uint8List buildPps() {
    final b = BitWriter();
    b.u(1, 0);
    b.u(2, 3);
    b.u(5, 8); // PPS
    b.ue(0); // pic_parameter_set_id
    b.ue(0); // seq_parameter_set_id
    b.u(1, 0); // entropy_coding_mode_flag: CAVLC
    b.u(1, 0); // bottom_field_pic_order_in_frame_present_flag
    b.ue(0); // num_slice_groups_minus1
    b.ue(0); // num_ref_idx_l0_default_active_minus1
    b.ue(0); // num_ref_idx_l1_default_active_minus1
    b.u(1, 0); // weighted_pred_flag
    b.u(2, 0); // weighted_bipred_idc
    b.se(qp - 26); // pic_init_qp_minus26
    b.se(0); // pic_init_qs_minus26
    b.se(0); // chroma_qp_index_offset
    b.u(1, 1); // deblocking_filter_control_present_flag
    b.u(1, 0); // constrained_intra_pred_flag
    b.u(1, 0); // redundant_pic_cnt_present_flag
    b.rbspTrailing();
    return rbspToEbsp(b.takeBytes());
  }

  // ---------------------------------------------------------------------
  // Frame encoding
  // ---------------------------------------------------------------------

  /// Converts an RGBA frame (4 bytes/px, R first) to internal YUV 4:2:0
  /// (BT.601, limited range) with edge padding to macroblock multiples.
  void loadRgba(Uint8List rgba, {int? stride}) {
    final s = stride ?? width * 4;
    // Luma
    for (var y = 0; y < height; y++) {
      final row = y * codedWidth;
      final srcRow = y * s;
      for (var x = 0; x < width; x++) {
        final i = srcRow + x * 4;
        final r = rgba[i], g = rgba[i + 1], bl = rgba[i + 2];
        _y[row + x] =
            ((66 * r + 129 * g + 25 * bl + 128) >> 8) + 16;
      }
      // Pad right edge with the last column.
      for (var x = width; x < codedWidth; x++) {
        _y[row + x] = _y[row + width - 1];
      }
    }
    for (var y = height; y < codedHeight; y++) {
      _y.setRange(y * codedWidth, (y + 1) * codedWidth,
          _y.sublist((height - 1) * codedWidth, height * codedWidth));
    }
    // Chroma: 2x2 box average.
    final ch = (height + 1) >> 1, cw = (width + 1) >> 1;
    for (var cy = 0; cy < ch; cy++) {
      for (var cx = 0; cx < cw; cx++) {
        var rSum = 0, gSum = 0, bSum = 0;
        for (var dy = 0; dy < 2; dy++) {
          final yy = math.min(cy * 2 + dy, height - 1);
          for (var dx = 0; dx < 2; dx++) {
            final xx = math.min(cx * 2 + dx, width - 1);
            final i = yy * s + xx * 4;
            rSum += rgba[i];
            gSum += rgba[i + 1];
            bSum += rgba[i + 2];
          }
        }
        final r = rSum >> 2, g = gSum >> 2, bl = bSum >> 2;
        final u = ((-38 * r - 74 * g + 112 * bl + 128) >> 8) + 128;
        final v = ((112 * r - 94 * g - 18 * bl + 128) >> 8) + 128;
        final idx = cy * (mbWidth * 8) + cx;
        _cb[idx] = u.clamp(0, 255);
        _cr[idx] = v.clamp(0, 255);
      }
      // Pad right chroma edge.
      for (var cx = cw; cx < mbWidth * 8; cx++) {
        _cb[cy * (mbWidth * 8) + cx] =
            _cb[cy * (mbWidth * 8) + cw - 1];
        _cr[cy * (mbWidth * 8) + cx] =
            _cr[cy * (mbWidth * 8) + cw - 1];
      }
    }
    for (var cy = ch; cy < mbHeight * 8; cy++) {
      final rowLen = mbWidth * 8;
      _cb.setRange(cy * rowLen, (cy + 1) * rowLen,
          _cb.sublist((ch - 1) * rowLen, ch * rowLen));
      _cr.setRange(cy * rowLen, (cy + 1) * rowLen,
          _cr.sublist((ch - 1) * rowLen, ch * rowLen));
    }
    _yRec.setAll(0, _y);
    _cbRec.setAll(0, _cb);
    _crRec.setAll(0, _cr);
  }

  /// Encodes the loaded frame as one IDR NAL (EBSP, no start code).
  Uint8List encodeIdr() {
    final b = BitWriter();
    b.u(1, 0);
    b.u(2, 3);
    b.u(5, 5); // IDR slice
    b.ue(0); // first_mb_in_slice
    b.ue(7); // slice_type: I (all slices)
    b.ue(0); // pic_parameter_set_id
    b.u(4, 0); // frame_num
    b.ue(0); // idr_pic_id
    // pic_order_cnt_type == 2 → no POC syntax elements.
    // dec_ref_pic_marking (IDR):
    b.u(1, 0); // no_output_of_prior_pics_flag
    b.u(1, 0); // long_term_reference_flag
    b.se(0); // slice_qp_delta (QP comes from pic_init_qp in the PPS)
    b.ue(1); // disable_deblocking_filter_idc = 1 (filter disabled)

    lastPcmMacroblocks = 0;
    lastFlatMacroblocks = 0;
    lastResidualMacroblocks = 0;
    _mbIsPcm.fillRange(0, _mbIsPcm.length, false);
    _nnz.fillRange(0, _nnz.length, 0);
    for (var mbY = 0; mbY < mbHeight; mbY++) {
      for (var mbX = 0; mbX < mbWidth; mbX++) {
        _encodeMacroblock(b, mbX, mbY);
      }
    }
    b.rbspTrailing();
    return rbspToEbsp(b.takeBytes());
  }

  // ---------------------------------------------------------------------
  // Macroblock encoding
  // ---------------------------------------------------------------------

  // Per-macroblock prediction candidates: 0 = vertical, 1 = horizontal,
  // 2 = DC. mb_type = 1 + mode + 12*cbpChroma + 4*(cbpLuma==15).
  // Chroma mode is an INDEPENDENT syntax element (intra_chroma_pred_mode
  // ue(v)) written for I_16x16 as well, with its own numbering:
  // 0=DC, 1=Horizontal, 2=Vertical.
  void _encodeMacroblock(BitWriter b, int mbX, int mbY) {
    _curMb = mbY * mbWidth + mbX;
    _nnzPending.fillRange(0, 24, 0);
    final canV = mbY > 0;
    final canH = mbX > 0;

    // Luma mode choice by residual SSD against the source.
    var bestMode = 2;
    var bestSsdY = _lumaSsd(mbX, mbY, 2);
    if (canV) {
      final e = _lumaSsd(mbX, mbY, 0);
      if (e < bestSsdY) {
        bestSsdY = e;
        bestMode = 0;
      }
    }
    if (canH) {
      final e = _lumaSsd(mbX, mbY, 1);
      if (e < bestSsdY) {
        bestSsdY = e;
        bestMode = 1;
      }
    }

    // Chroma mode choice (independent syntax element).
    var bestCMode = 2;
    var bestSsdC = _chromaSsd(mbX, mbY, 2);
    if (canV) {
      final e = _chromaSsd(mbX, mbY, 0);
      if (e < bestSsdC) {
        bestSsdC = e;
        bestCMode = 0;
      }
    }
    if (canH) {
      final e = _chromaSsd(mbX, mbY, 1);
      if (e < bestSsdC) {
        bestSsdC = e;
        bestCMode = 1;
      }
    }

    final maxErrY = _lumaMaxErr(mbX, mbY, bestMode);
    final maxErrC = _chromaMaxErr(mbX, mbY, bestCMode);
    final isFlat = maxErrY <= flatThreshold && maxErrC <= flatThreshold;

    // Residuals disabled: the v0.12-validated flat + I_PCM behavior.
    if (!enableResiduals) {
      if (isFlat) {
        _writeFlatHeader(b, bestMode, bestCMode);
        _setNnzFlat(mbX, mbY);
        _mbIsPcm[mbY * mbWidth + mbX] = false;
        lastFlatMacroblocks++;
        _applyFlatReconstruction(mbX, mbY, bestMode, bestCMode);
      } else {
        _writePcm(b, mbX, mbY);
        _mbIsPcm[mbY * mbWidth + mbX] = true;
        _setNnzPcm(mbX, mbY);
        _restoreRecFromSource(mbX, mbY);
        lastPcmMacroblocks++;
      }
      return;
    }

    if (isFlat) {
      _writeFlatHeader(b, bestMode, bestCMode);
      _setNnzFlat(mbX, mbY);
      _mbIsPcm[mbY * mbWidth + mbX] = false;
      lastFlatMacroblocks++;
      _applyFlatReconstruction(mbX, mbY, bestMode, bestCMode);
      return;
    }

    // Residual attempt: transform + quantize with the chosen modes.
    final ok = _prepareResidual(mbX, mbY, bestMode, bestCMode);
    var usePcm = !ok;
    var residualBits = 0;
    if (ok) {
      final scratch = BitWriter();
      // The scratch pass must stay silent: the real write below traces.
      final savedTrace = debugTrace;
      debugTrace = null;
      residualBits =
          _writeResidualMacroblock(scratch, mbX, mbY, bestMode, bestCMode);
      debugTrace = savedTrace;
      usePcm = residualBits >= 3072; // I_PCM payload costs 3072 bits
    }

    if (usePcm) {
      _writePcm(b, mbX, mbY);
      _mbIsPcm[mbY * mbWidth + mbX] = true;
      _setNnzPcm(mbX, mbY);
      // Decoder PCM output = the raw padded samples.
      _restoreRecFromSource(mbX, mbY);
      lastPcmMacroblocks++;
      return;
    }

    _writeResidualMacroblock(b, mbX, mbY, bestMode, bestCMode);
    _mbIsPcm[mbY * mbWidth + mbX] = false;
    _commitResidualReconstruction(mbX, mbY);
    lastResidualMacroblocks++;
  }

  /// Writes the header + zero-coefficient luma DC block of a flat
  /// I_16x16 macroblock (mb_type 1..3, chroma pred mode, mb_qp_delta).
  void _writeFlatHeader(BitWriter b, int bestMode, int bestCMode) {
    // mb_type = 1 + predMode + 12*cbpChroma + 4*(cbpLuma==15).
    final mbType = switch (bestMode) {
      0 => 1, // Vertical
      1 => 2, // Horizontal
      _ => 3, // DC
    };
    b.ue(mbType);
    // intra_chroma_pred_mode: present for I_16x16 too (and I_4x4).
    b.ue(switch (bestCMode) {
      2 => 0, // DC
      1 => 1, // Horizontal
      _ => 2, // Vertical
    });
    b.se(0); // mb_qp_delta (always present for Intra_16x16)
    // Luma DC block: coded with 0 coefficients.
    _writeCavlcBlock(
      b,
      _zeroLevels16,
      16,
      nC: _blockNnz(_curMb % mbWidth, _curMb ~/ mbWidth, 0, 4, 0, 0),
      kind: 'L-DC',
    );
  }

  static final Int32List _zeroLevels16 = Int32List(16);

  void _writePcm(BitWriter b, int mbX, int mbY) {
    b.ue(25); // I_PCM: mb_type 25, byte-align, raw samples.
    b.byteAlign();
    final bx = mbX * 16, by = mbY * 16;
    for (var y = 0; y < 16; y++) {
      final row = (by + y) * codedWidth;
      for (var x = 0; x < 16; x++) {
        b.u(8, _y[row + bx + x]);
      }
    }
    final cw = mbWidth * 8;
    final cx0 = mbX * 8, cy0 = mbY * 8;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        b.u(8, _cb[(cy0 + y) * cw + cx0 + x]);
      }
    }
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        b.u(8, _cr[(cy0 + y) * cw + cx0 + x]);
      }
    }
  }

  void _restoreRecFromSource(int mbX, int mbY) {
    final bx = mbX * 16, by = mbY * 16;
    for (var y = 0; y < 16; y++) {
      final row = (by + y) * codedWidth + bx;
      _yRec.setRange(row, row + 16, _y.sublist(row, row + 16));
    }
    final cw = mbWidth * 8;
    final cx0 = mbX * 8, cy0 = mbY * 8;
    for (var y = 0; y < 8; y++) {
      final row = (cy0 + y) * cw + cx0;
      _cbRec.setRange(row, row + 8, _cb.sublist(row, row + 8));
      _crRec.setRange(row, row + 8, _cr.sublist(row, row + 8));
    }
  }

  /// Writes mb_layer for an I_16x16 residual macroblock from the
  /// precomputed levels. Returns the number of bits written.
  int _writeResidualMacroblock(
      BitWriter b, int mbX, int mbY, int mode, int cMode) {
    final start = b.bitLength;
    // cbp flags from the quantized levels.
    var cbpLuma = false;
    for (var k = 0; k < 256; k++) {
      final pos = k & 15;
      if (pos != 0 && _levY[k] != 0) {
        cbpLuma = true;
        break;
      }
    }
    var anyDc = false, anyAc = false;
    for (var plane = 0; plane < 2; plane++) {
      for (var k = 0; k < 4; k++) {
        if (_chDcLevels[plane * 4 + k] != 0) {
          anyDc = true;
        }
      }
      final lev = plane == 0 ? _levCb : _levCr;
      for (var blk = 0; blk < 4; blk++) {
        for (var pos = 1; pos < 16; pos++) {
          if (lev[blk * 16 + pos] != 0) {
            anyAc = true;
          }
        }
      }
    }
    final cbpC = anyAc ? 2 : (anyDc ? 1 : 0);

    // mb_type = 1 + pred + 4*cbpChroma + 12*cbpLuma, per ffmpeg's
    // ff_h264_i_mb_type_info (entries 1-24; 25 is I_PCM):
    //   1-4:   cbpChroma 0, cbpLuma 0   (V,H,DC cycle)
    //   5-8:   cbpChroma 1 (DC only)
    //   9-12:  cbpChroma 2 (DC + AC)
    //   13-16: cbpLuma 15, cbpChroma 0 ... 21-24: cbpLuma 15, cbpChroma 2
    final mbType = 1 + mode + 4 * cbpC + (cbpLuma ? 12 : 0);
    assert(mbType >= 1 && mbType <= 24);
    _trace('MB $mbX,$mbY type=$mbType cmode=$cMode cbpC=$cbpC cbpL=$cbpLuma '
        'chDc=${_chDcLevels.toList()} cbAC=${_levCb.take(4).toList()}/${_levCb[16]}/${_levCr[16]}');
    b.ue(mbType);
    b.ue(switch (cMode) {
      2 => 0, // DC
      1 => 1, // Horizontal
      _ => 2, // Vertical
    });
    b.se(0); // mb_qp_delta

    // Luma DC block (always coded for I_16x16). Levels in zigzag order.
    final dcZig = Int32List(16);
    for (var k = 0; k < 16; k++) {
      dcZig[k] = _dcLevels[h264ZigzagScan[k]];
    }
    _writeCavlcBlock(b, dcZig, 16, nC: _blockNnz(mbX, mbY, 0, 4, 0, 0),
        kind: 'L-DC');

    // 15 luma AC blocks (raster order), zigzag positions 1..15.
    if (cbpLuma) {
      for (var blk = 0; blk < 16; blk++) {
        final zig = Int32List(15);
        for (var k = 0; k < 15; k++) {
          zig[k] = _levY[blk * 16 + h264ZigzagScan[k + 1]];
        }
        final r = blk ~/ 4, c = blk % 4;
        _writeCavlcBlock(
          b,
          zig,
          15,
          nC: _blockNnz(mbX, mbY, 0, 4, r, c),
          kind: 'L$blk',
        );
      }
    }

    // Chroma residual order mirrors ffmpeg's decode_mb_cavlc exactly:
    // chroma DC for BOTH planes first, then the 4+4 chroma AC blocks.
    if (cbpC >= 1) {
      for (var plane = 0; plane < 2; plane++) {
        // Chroma DC 2x2: fixed coeff_token table (no nC dependence).
        final zig = Int32List(4);
        for (var k = 0; k < 4; k++) {
          zig[k] = _chDcLevels[plane * 4 + k];
        }
        _writeCavlcBlock(b, zig, 4, chromaDc: true, nC: 0,
            kind: plane == 0 ? 'CbDC' : 'CrDC');
      }
    }
    if (cbpC >= 2) {
      for (var plane = 0; plane < 2; plane++) {
        final lev = plane == 0 ? _levCb : _levCr;
        for (var blk = 0; blk < 4; blk++) {
          final zig = Int32List(15);
          for (var k = 0; k < 15; k++) {
            zig[k] = lev[blk * 16 + h264ZigzagScan[k + 1]];
          }
          final r = blk ~/ 2, c = blk % 2;
          _writeCavlcBlock(
            b,
            zig,
            15,
            nC: _blockNnz(mbX, mbY, 16 + plane * 4, 2, r, c),
            kind: '${plane == 0 ? 'Cb' : 'Cr'}$blk',
          );
        }
      }
    }
    return b.bitLength - start;
  }

  /// Transform + quantize the current MB with the chosen prediction
  /// modes; fills the level arrays and the pending reconstruction
  /// buffers. Returns false when a level exceeds the CAVLC-safe range
  /// or the reconstruction error is too large (caller uses I_PCM).
  bool _prepareResidual(int mbX, int mbY, int mode, int cMode) {
    final bx = mbX * 16, by = mbY * 16;
    // Luma prediction for the whole MB.
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        _predY[y * 16 + x] = _lumaPredPx(mbX, mbY, mode, x, y);
      }
    }
    for (var blk = 0; blk < 16; blk++) {
      final r0 = (blk ~/ 4) * 4, c0 = (blk % 4) * 4;
      _forwardTransform(
        _tY,
        blk * 16,
        (x, y) => _y[(by + r0 + y) * codedWidth + bx + c0 + x],
        (x, y) => _predY[(r0 + y) * 16 + c0 + x],
      );
      if (!_quantizeBlock(_tY, blk * 16, _levY, blk * 16, qp)) {
        return false;
      }
    }
    if (!_lumaDcLevels()) {
      return false;
    }
    if (!_reconstructLumaPending(mbX, mbY)) {
      return false;
    }
    // Chroma planes.
    final cw = mbWidth * 8;
    final cx0 = mbX * 8, cy0 = mbY * 8;
    for (final plane in const <int>[0, 1]) {
      final src = plane == 0 ? _cb : _cr;
      final rec = plane == 0 ? _cbRec : _crRec;
      final t = plane == 0 ? _tCb : _tCr;
      final lev = plane == 0 ? _levCb : _levCr;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          _predC[y * 8 + x] =
              _chromaPredPx(rec, cw, mbX, mbY, cMode, x, y);
        }
      }
      for (var blk = 0; blk < 4; blk++) {
        final r0 = (blk ~/ 2) * 4, c0 = (blk % 2) * 4;
        _forwardTransform(
          t,
          blk * 16,
          (x, y) => src[(cy0 + r0 + y) * cw + cx0 + c0 + x],
          (x, y) => _predC[(r0 + y) * 8 + c0 + x],
        );
        if (!_quantizeBlock(t, blk * 16, lev, blk * 16, _chromaQp)) {
          return false;
        }
      }
      if (!_chromaDcLevels(plane)) {
        return false;
      }
    }
    // Pending chroma reconstruction + error (pure scratch fill).
    _reconstructChromaPending(mbX, mbY);
    if (_pendingErrY > residualMaxErr || _pendingErrC > residualMaxErr) {
      return false;
    }
    return true;
  }

  /// Forward transform of one 4x4 block whose residual is
  /// src(x,y) - pred(x,y): T = M * R * M^T with M = 20*P^-1, so the
  /// target stored coefficients are W = 4*T/25.
  void _forwardTransform(Int32List t, int off, int Function(int, int) src,
      int Function(int, int) pred) {
    final r = Int32List(16);
    final tmp = Int32List(16);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        r[y * 4 + x] = src(x, y) - pred(x, y);
      }
    }
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        var sum = 0;
        for (var k = 0; k < 4; k++) {
          sum += _invP20[y][k] * r[k * 4 + x];
        }
        tmp[y * 4 + x] = sum;
      }
    }
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        var sum = 0;
        for (var k = 0; k < 4; k++) {
          sum += tmp[y * 4 + k] * _invP20[x][k];
        }
        t[off + y * 4 + x] = sum;
      }
    }
  }

  /// Quantizes the AC positions of the block at [tOff] into [lev],
  /// enforcing the CAVLC-safe level cap. DC slot stays 0.
  bool _quantizeBlock(
      Int32List t, int tOff, Int32List lev, int levOff, int q) {
    for (var pos = 1; pos < 16; pos++) {
      final level = _symRound(256 * t[tOff + pos], 25 * dequant4Mul(q, pos));
      if (level.abs() > 2000) {
        return false;
      }
      lev[levOff + pos] = level;
    }
    lev[levOff] = 0;
    return true;
  }

  int _pendingErrY = 0;
  int _pendingErrC = 0;

  /// Luma DC levels from the 16 block-DC targets: the exact inverse of
  /// the decoder's H' Hadamard + dequant chain,
  /// d = round(H' * (1024*T00) * H' / (400 * qmul0)).
  bool _lumaDcLevels() {
    final tmp = Int32List(16);
    final u = Int32List(16);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        var sum = 0;
        for (var k = 0; k < 4; k++) {
          sum += _hadamard4[r][k] * _tY[(k * 4 + c) * 16];
        }
        tmp[r * 4 + c] = sum;
      }
    }
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        var sum = 0;
        for (var k = 0; k < 4; k++) {
          sum += tmp[r * 4 + k] * _hadamard4[c][k];
        }
        u[r * 4 + c] = sum;
      }
    }
    final q0 = dequant4Mul(qp, 0);
    for (var i = 0; i < 16; i++) {
      final d = _symRound(128 * u[i], 50 * q0);
      if (d.abs() > 2000) {
        return false;
      }
      _dcLevels[i] = d;
    }
    return true;
  }

  /// Chroma DC levels for [plane] (0=Cb, 1=Cr): the exact inverse of
  /// the decoder's H2 2x2 Hadamard + dequant chain,
  /// d = round(H2 * (128*T00) * H2 / (25 * qmulC)).
  bool _chromaDcLevels(int plane) {
    final t = plane == 0 ? _tCb : _tCr;
    // Block-DC targets: block (r,c) at t[blk*16] with blk = r*2+c.
    final m00 = t[0], m01 = t[16], m10 = t[32], m11 = t[48];
    // H2 * M with H2 = [[1,1],[1,-1]] (H2 is symmetric; H2*M then *H2):
    // v = H2 * M * H2^T.
    final a = m00 + m10, b = m01 + m11, c = m00 - m10, d = m01 - m11;
    final v0 = a + b, v1 = a - b, v2 = c + d, v3 = c - d;
    final q = dequant4Mul(_chromaQp, 0);
    final vals = <int>[v0, v1, v2, v3];
    for (var i = 0; i < 4; i++) {
      final d2 = _symRound(128 * vals[i], 25 * q);
      if (d2.abs() > 2000) {
        return false;
      }
      _chDcLevels[plane * 4 + i] = d2;
    }
    return true;
  }

  /// Computes the pending luma reconstruction (decoder-mirrored) into
  /// _recY, the pending nnz record, and the error vs the source.
  /// Returns false if a DC level chain overflowed (never expected).
  bool _reconstructLumaPending(int mbX, int mbY) {
    final q0 = dequant4Mul(qp, 0);
    // Stored DC per block: (H' * d * H'^T) * qmul0 + 128 >> 8, where d
    // are the decoded DC levels placed in raster order.
    final storedDc = Int32List(16);
    {
      final tmp = Int32List(16);
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          var sum = 0;
          for (var k = 0; k < 4; k++) {
            sum += _hadamard4[r][k] * _dcLevels[k * 4 + c];
          }
          tmp[r * 4 + c] = sum;
        }
      }
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          var sum = 0;
          for (var k = 0; k < 4; k++) {
            sum += tmp[r * 4 + k] * _hadamard4[c][k];
          }
          storedDc[r * 4 + c] = (sum * q0 + 128) >> 8;
        }
      }
    }
    final bx = mbX * 16, by = mbY * 16;
    var maxErr = 0;
    final nnzBase = 0;
    for (var blk = 0; blk < 16; blk++) {
      final r0 = (blk ~/ 4) * 4, c0 = (blk % 4) * 4;
      var hasAc = false;
      for (var pos = 1; pos < 16; pos++) {
        if (_levY[blk * 16 + pos] != 0) {
          hasAc = true;
          break;
        }
      }
      final dcStored = storedDc[blk];
      _stored[0] = dcStored;
      for (var pos = 1; pos < 16; pos++) {
        _stored[pos] =
            (_levY[blk * 16 + pos] * dequant4Mul(qp, pos) + 32) >> 6;
      }
      var nnz = 0;
      for (var pos = 1; pos < 16; pos++) {
        if (_levY[blk * 16 + pos] != 0) nnz++;
      }
      _nnzPending[nnzBase + blk] = nnz;
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final pred = _predY[(r0 + y) * 16 + c0 + x];
          var delta = 0;
          if (hasAc) {
            delta = _idct4x4Sample(y, x);
          } else if (dcStored != 0) {
            delta = (dcStored + 32) >> 6;
          }
          final rec = (pred + delta).clamp(0, 255);
          _recY[(r0 + y) * 16 + c0 + x] = rec;
          final srcPx = _y[(by + r0 + y) * codedWidth + bx + c0 + x];
          final err = (rec - srcPx).abs();
          if (err > maxErr) maxErr = err;
        }
      }
    }
    _pendingErrY = maxErr;
    return true;
  }

  /// One output sample of the ffmpeg 4x4 idct from _stored, mirroring
  /// ff_h264_idct_add (block[0] += 1<<5 pre-add included).
  int _idct4x4Sample(int oy, int ox) {
    final blk = Int32List(16);
    blk.setAll(0, _stored);
    blk[0] += 1 << 5;
    final t = Int32List(16);
    // Pass 1: mix along rows within each column i (block[i + 4*j]).
    for (var i = 0; i < 4; i++) {
      final z0 = blk[i + 4 * 0] + blk[i + 4 * 2];
      final z1 = blk[i + 4 * 0] - blk[i + 4 * 2];
      final z2 = (blk[i + 4 * 1] >> 1) - blk[i + 4 * 3];
      final z3 = blk[i + 4 * 1] + (blk[i + 4 * 3] >> 1);
      t[i + 4 * 0] = z0 + z3;
      t[i + 4 * 1] = z1 + z2;
      t[i + 4 * 2] = z1 - z2;
      t[i + 4 * 3] = z0 - z3;
    }
    // Pass 2: mix along columns within each row i (block[0 + 4*i] ...).
    final out = Int32List(16);
    for (var i = 0; i < 4; i++) {
      final z0 = t[0 + 4 * i] + t[2 + 4 * i];
      final z1 = t[0 + 4 * i] - t[2 + 4 * i];
      final z2 = (t[1 + 4 * i] >> 1) - t[3 + 4 * i];
      final z3 = t[1 + 4 * i] + (t[3 + 4 * i] >> 1);
      out[0 + 4 * i] = z0 + z3;
      out[1 + 4 * i] = z1 + z2;
      out[2 + 4 * i] = z1 - z2;
      out[3 + 4 * i] = z0 - z3;
    }
    // Sample (row oy, col ox) = out[ox + 4*oy] >> 6.
    return out[ox + 4 * oy] >> 6;
  }

  /// Computes the pending chroma reconstruction into _recCb/_recCr and
  /// the error vs the sources.
  void _reconstructChromaPending(int mbX, int mbY) {
    final q = _chromaQp;
    var maxErr = 0;
    for (var plane = 0; plane < 2; plane++) {
      final lev = plane == 0 ? _levCb : _levCr;
      final src = plane == 0 ? _cb : _cr;
      final recBuf = plane == 0 ? _recCb : _recCr;
      // Chroma DC 2x2 stored values (decoder's chroma_dc_dequant_idct),
      // only when the DC block has a nonzero coefficient count.
      var dcAny = false;
      for (var k = 0; k < 4; k++) {
        if (_chDcLevels[plane * 4 + k] != 0) {
          dcAny = true;
          break;
        }
      }
      final storedDc = Int32List(4);
      if (dcAny) {
        final a = _chDcLevels[plane * 4 + 0];
        final b = _chDcLevels[plane * 4 + 1];
        final c = _chDcLevels[plane * 4 + 2];
        final d = _chDcLevels[plane * 4 + 3];
        final qm = dequant4Mul(q, 0);
        final e = a - b;
        final a2 = a + b;
        final b2 = c - d;
        final c2 = c + d;
        storedDc[0] = ((a2 + c2) * qm) >> 7;
        storedDc[1] = ((e + b2) * qm) >> 7;
        storedDc[2] = ((a2 - c2) * qm) >> 7;
        storedDc[3] = ((e - b2) * qm) >> 7;
      }
      final nnzBase = 16 + plane * 4;
      for (var blk = 0; blk < 4; blk++) {
        final r0 = (blk ~/ 2) * 4, c0 = (blk % 2) * 4;
        var hasAc = false;
        for (var pos = 1; pos < 16; pos++) {
          if (lev[blk * 16 + pos] != 0) {
            hasAc = true;
            break;
          }
        }
        final dcStored = dcAny ? storedDc[blk] : 0;
        _stored[0] = dcStored;
        for (var pos = 1; pos < 16; pos++) {
          _stored[pos] =
              (lev[blk * 16 + pos] * dequant4Mul(q, pos) + 32) >> 6;
        }
        var nnz = 0;
        for (var pos = 1; pos < 16; pos++) {
          if (lev[blk * 16 + pos] != 0) nnz++;
        }
        _nnzPending[nnzBase + blk] = nnz;
        final cx0 = mbX * 8, cy0 = mbY * 8;
      for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final pred = _predC[(r0 + y) * 8 + c0 + x];
            var delta = 0;
            if (hasAc) {
              delta = _idct4x4Sample(y, x);
            } else if (dcStored != 0) {
              delta = (dcStored + 32) >> 6;
            }
            final v = (pred + delta).clamp(0, 255);
            recBuf[(r0 + y) * 8 + c0 + x] = v;
            final srcPx =
                src[(cy0 + r0 + y) * (mbWidth * 8) + cx0 + c0 + x];
            final err = (v - srcPx).abs();
            if (err > maxErr) maxErr = err;
          }
        }
      }
    }
    _pendingErrC = maxErr;
  }

  /// Blits the pending reconstruction into the *_Rec buffers (both were
  /// filled during prepare) and commits the pending nnz record.
  void _commitResidualReconstruction(int mbX, int mbY) {
    final bx = mbX * 16, by = mbY * 16;
    for (var y = 0; y < 16; y++) {
      final row = (by + y) * codedWidth + bx;
      for (var x = 0; x < 16; x++) {
        _yRec[row + x] = _recY[y * 16 + x];
      }
    }
    final cw = mbWidth * 8;
    final cx0 = mbX * 8, cy0 = mbY * 8;
    for (var y = 0; y < 8; y++) {
      final row = (cy0 + y) * cw + cx0;
      for (var x = 0; x < 8; x++) {
        _cbRec[row + x] = _recCb[y * 8 + x];
        _crRec[row + x] = _recCr[y * 8 + x];
      }
    }
    final base = (mbY * mbWidth + mbX) * 24;
    _nnz.setRange(base, base + 24, _nnzPending);
  }

  // ---------------------------------------------------------------------
  // CAVLC block writer
  // ---------------------------------------------------------------------

  /// Encodes one residual block. [zigLevels] holds the coefficient at
  /// each coded position in zigzag order (dense; for AC blocks index 0
  /// is zigzag position 1). [maxCoeff] is the block size (16 = luma DC,
  /// 15 = AC, 4 = chroma DC). [chromaDc] selects the fixed chroma DC
  /// coeff_token table; otherwise the table is picked by [nC].
  void _writeCavlcBlock(
    BitWriter b,
    Int32List zigLevels,
    int maxCoeff, {
    bool chromaDc = false,
    required int nC,
    String kind = 'blk',
  }) {
    // Nonzero positions in decode order (highest zigzag first).
    final nzPos = <int>[];
    for (var p = maxCoeff - 1; p >= 0; p--) {
      if (zigLevels[p] != 0) nzPos.add(p);
    }
    final tc = nzPos.length;
    // Trailing ones: the first coefficients in decode order while ±1.
    var t1 = 0;
    while (t1 < tc && t1 < 3 && zigLevels[nzPos[t1]].abs() == 1) {
      t1++;
    }

    // coeff_token.
    if (chromaDc) {
      b.u(kChromaDcCoeffTokenLen[tc * 4 + t1],
          kChromaDcCoeffTokenBits[tc * 4 + t1]);
    } else {
      final band = coeffTokenBand(nC);
      b.u(kCoeffTokenLen[band][tc * 4 + t1],
          kCoeffTokenBits[band][tc * 4 + t1]);
    }
    if (tc == 0) {
      _trace('$kind: tc=0 nC=$nC');
      return;
    }

    // Trailing-one sign bits, decode order.
    for (var k = 0; k < t1; k++) {
      b.u1(zigLevels[nzPos[k]] < 0 ? 1 : 0);
    }

    // Remaining levels, decode order (highest position first).
    if (t1 < tc) {
      final suffixLimit = const <int>[0, 3, 6, 12, 24, 48, 1 << 30];
      var suffix = (tc > 10 && t1 < 3) ? 1 : 0;
      for (var k = t1; k < tc; k++) {
        final coef = zigLevels[nzPos[k]];
        final mag = coef.abs();
        var v = coef > 0 ? 2 * mag - 2 : 2 * mag - 1;
        if (k == t1) {
          if (t1 < 3) {
            v -= 2;
          }
          assert(v >= 0, 'first non-T1 level must not be ±1 when T1s < 3');
          // First-level rules (suffix 0 or 1).
          if (suffix == 0) {
            if (v <= 13) {
              b.unary(v);
            } else if (v <= 29) {
              b.unary(14);
              b.u(4, v - 14);
            } else if (v <= 4125) {
              b.unary(15);
              b.u(12, v - 30);
            } else {
              b.unary(16);
              b.u(13, v - 4126);
            }
          } else {
            if (v <= 27) {
              b.unary(v >> 1);
              b.u1(v & 1);
            } else if (v <= 29) {
              b.unary(14);
              b.u1(v - 28);
            } else if (v <= 4125) {
              b.unary(15);
              b.u(12, v - 30);
            } else {
              b.unary(16);
              b.u(13, v - 4126);
            }
          }
          suffix = mag > 3 ? 2 : 1;
        } else {
          // Loop levels: keep the current suffix (which is 1 after a
          // small first level, 2 after a large one) — the decoder only
          // grows it via the suffix_limit rule below.
          if (v < (15 << suffix)) {
            b.unary(v >> suffix);
            b.u(suffix, v & ((1 << suffix) - 1));
          } else {
            assert(v < (15 << suffix) + 4096, 'level escape overflow');
            b.unary(15);
            b.u(12, v - (15 << suffix));
          }
          if (mag > suffixLimit[suffix] && suffix < 6) {
            suffix++;
          }
        }
      }
    }

    // total_zeros (not coded when the block is full): the highest
    // nonzero dense position minus the coefficients below it.
    final dTop = nzPos[0];
    final tz = dTop - (tc - 1);
    assert(tz >= 0);
    if (tc < maxCoeff) {
      if (chromaDc) {
        b.u(kChromaDcTotalZerosLen[tc - 1][tz],
            kChromaDcTotalZerosBits[tc - 1][tz]);
      } else {
        b.u(kTotalZerosLen[tc - 1][tz], kTotalZerosBits[tc - 1][tz]);
      }
    }

    // run_before for coefficients 1..tc-1 (decode order), while
    // zerosLeft > 0; the rest are implicit adjacent zeros.
    var zerosLeft = tz;
    for (var k = 1; k < tc; k++) {
      final run = nzPos[k - 1] - nzPos[k] - 1;
      if (zerosLeft > 0) {
        final row = (zerosLeft < 7) ? zerosLeft - 1 : 6;
        b.u(kRunLen[row][run], kRunBits[row][run]);
        zerosLeft -= run;
      } else {
        assert(run == 0, 'runs must be 0 once zeros are exhausted');
      }
    }
    _trace(
        '$kind: tc=$tc t1=$t1 nC=$nC tz=$tz endBit=${b.bitLength} '
        'pos=${nzPos.reversed.toList()} '
        'levels=${[for (final p in nzPos.reversed) zigLevels[p]]}');
  }

  // ---------------------------------------------------------------------
  // nC state
  // ---------------------------------------------------------------------

  /// Neighbour-derived nC for the block at grid (r,c) of plane record
  /// [base] (0 = luma 4x4 grid, 16/20 = chroma 2x2 grid) — mirrors
  /// ffmpeg's pred_non_zero_count including the 0x40 unavailable rule.
  /// (r,c) = (0,0) with the luma base yields the luma-DC block nC.
  int _blockNnz(int mbX, int mbY, int base, int grid, int r, int c) {
    final mbIdx = mbY * mbWidth + mbX;
    // Intra-MB neighbours read the pending record (the decoder derives
    // them from blocks parsed within this same MB).
    final own = mbIdx == _curMb;
    int recIdx(int idx) => own ? _nnzPending[idx] : _nnz[mbIdx * 24 + idx];
    int nA;
    if (c > 0) {
      nA = recIdx(base + r * grid + c - 1);
    } else if (mbX > 0) {
      nA = _nnz[(mbY * mbWidth + mbX - 1) * 24 + base + r * grid + grid - 1];
    } else {
      nA = 64;
    }
    int nB;
    if (r > 0) {
      nB = recIdx(base + (r - 1) * grid + c);
    } else if (mbY > 0) {
      nB = _nnz[
          ((mbY - 1) * mbWidth + mbX) * 24 + base + (grid - 1) * grid + c];
    } else {
      nB = 64;
    }
    var i = nA + nB;
    if (i < 64) i = (i + 1) >> 1;
    return i & 31;
  }

  void _setNnzFlat(int mbX, int mbY) {
    final base = (mbY * mbWidth + mbX) * 24;
    _nnz.fillRange(base, base + 24, 0);
  }

  void _setNnzPcm(int mbX, int mbY) {
    final base = (mbY * mbWidth + mbX) * 24;
    _nnz.fillRange(base, base + 24, 16);
  }

  // ---------------------------------------------------------------------
  // Prediction + mode metrics
  // ---------------------------------------------------------------------

  /// SSD of the luma residual under prediction [mode].
  int _lumaSsd(int mbX, int mbY, int mode) {
    final bx = mbX * 16, by = mbY * 16;
    var ssd = 0;
    for (var y = 0; y < 16; y++) {
      final row = (by + y) * codedWidth + bx;
      for (var x = 0; x < 16; x++) {
        final d = _y[row + x] - _lumaPredPx(mbX, mbY, mode, x, y);
        ssd += d * d;
      }
    }
    return ssd;
  }

  /// SSD of the chroma residual (both planes) under prediction [mode].
  int _chromaSsd(int mbX, int mbY, int mode) {
    final cw = mbWidth * 8;
    final cx0 = mbX * 8, cy0 = mbY * 8;
    var ssd = 0;
    for (final plane in [_cb, _cr]) {
      for (var y = 0; y < 8; y++) {
        final row = (cy0 + y) * cw + cx0;
        for (var x = 0; x < 8; x++) {
          final d = plane[row + x] -
              _chromaPredPx(plane, cw, mbX, mbY, mode, x, y);
          ssd += d * d;
        }
      }
    }
    return ssd;
  }

  /// Max per-sample luma error under prediction [mode].
  int _lumaMaxErr(int mbX, int mbY, int mode) {
    final bx = mbX * 16, by = mbY * 16;
    var maxErr = 0;
    for (var y = 0; y < 16; y++) {
      final row = (by + y) * codedWidth + bx;
      for (var x = 0; x < 16; x++) {
        final d = (_y[row + x] - _lumaPredPx(mbX, mbY, mode, x, y)).abs();
        if (d > maxErr) maxErr = d;
      }
    }
    return maxErr;
  }

  /// Max per-sample chroma error under prediction [mode].
  int _chromaMaxErr(int mbX, int mbY, int mode) {
    final cw = mbWidth * 8;
    final cx0 = mbX * 8, cy0 = mbY * 8;
    var maxErr = 0;
    for (var y = 0; y < 8; y++) {
      final row = (cy0 + y) * cw + cx0;
      for (var x = 0; x < 8; x++) {
        final dcb = (_cb[row + x] -
                _chromaPredPx(_cbRec, cw, mbX, mbY, mode, x, y))
            .abs();
        final dcr = (_cr[row + x] -
                _chromaPredPx(_crRec, cw, mbX, mbY, mode, x, y))
            .abs();
        if (dcb > maxErr) maxErr = dcb;
        if (dcr > maxErr) maxErr = dcr;
      }
    }
    return maxErr;
  }

  /// Luma prediction for the pixel at ([localX], [localY]) inside the
  /// macroblock, from reconstruction reference samples (H.264 8.3.3).
  int _lumaPredPx(int mbX, int mbY, int mode, int localX, int localY) {
    final canV = mbY > 0, canH = mbX > 0;
    if (mode == 0 && canV) {
      // Vertical: copy the bottom row of the macroblock above.
      return _yRec[(mbY * 16 - 1) * codedWidth + mbX * 16 + localX];
    }
    if (mode == 1 && canH) {
      // Horizontal: copy the right column of the macroblock to the left.
      return _yRec[(mbY * 16 + localY) * codedWidth + mbX * 16 - 1];
    }
    if (mode == 2) {
      // DC: constant — 4 samples from above + 4 from the left.
      var sum = 0, cnt = 0;
      if (canV) {
        final row = (mbY * 16 - 1) * codedWidth + mbX * 16 + 12;
        for (var i = 0; i < 4; i++) {
          sum += _yRec[row + i];
          cnt++;
        }
      }
      if (canH) {
        final col = (mbY * 16 + 12) * codedWidth + mbX * 16 - 1;
        for (var i = 0; i < 4; i++) {
          sum += _yRec[col + i * codedWidth];
          cnt++;
        }
      }
      if (cnt == 0) return 128;
      return (sum + (cnt >> 1)) ~/ cnt;
    }
    // Requested mode unavailable → fall back to DC.
    return _lumaPredPx(mbX, mbY, 2, localX, localY);
  }

  /// Chroma prediction (8x8) using the same directional mapping.
  int _chromaPredPx(Uint8List plane, int cw, int mbX, int mbY, int mode,
      int localX, int localY) {
    final canV = mbY > 0, canH = mbX > 0;
    final cx0 = mbX * 8, cy0 = mbY * 8;
    if (mode == 0 && canV) {
      return plane[(cy0 - 1) * cw + cx0 + localX];
    }
    if (mode == 1 && canH) {
      return plane[(cy0 + localY) * cw + cx0 - 1];
    }
    if (mode == 2) {
      // DC for an 8x8 block: mean of available adjacent samples
      // (top row 8 + left column 8, clipped to availability).
      var sum = 0, cnt = 0;
      if (canV) {
        for (var i = 0; i < 8; i++) {
          sum += plane[(cy0 - 1) * cw + cx0 + i];
          cnt++;
        }
      }
      if (canH) {
        for (var i = 0; i < 8; i++) {
          sum += plane[(cy0 + i) * cw + cx0 - 1];
          cnt++;
        }
      }
      if (cnt == 0) return 128;
      return (sum + (cnt >> 1)) ~/ cnt;
    }
    return _chromaPredPx(plane, cw, mbX, mbY, 2, localX, localY);
  }

  void _applyFlatReconstruction(int mbX, int mbY, int mode, int cMode) {
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        _yRec[(mbY * 16 + y) * codedWidth + mbX * 16 + x] =
            _lumaPredPx(mbX, mbY, mode, x, y);
      }
    }
    final cw = mbWidth * 8;
    for (final plane in [_cbRec, _crRec]) {
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          plane[(mbY * 8 + y) * cw + mbX * 8 + x] =
              _chromaPredPx(plane, cw, mbX, mbY, cMode, x, y);
        }
      }
    }
  }
}
