// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// h264_encoder.dart — Pure-Dart H.264 Baseline IDR-frame encoder.
//
// A deliberately conservative encoder that trades compression ratio for
// bitstream correctness: every macroblock is coded either as
//
//   - I_16x16 (Vertical / Horizontal / DC prediction, zero residuals,
//     i.e. a flat predicted block — 3..6 bits total), or
//   - I_PCM (lossless sample copy — 384 bytes at 4:2:0),
//
// chosen per macroblock by comparing the predicted reconstruction
// against the source. Because flat blocks need no residual syntax and
// PCM blocks bypass CAVLC entirely, the encoder depends on only two
// coeff_token codewords (the all-zero tokens for nC<2 and nC>=8), both
// of which are insensitive to the single-neighbour nC rule — the classic
// hand-written-encoder pitfall.
//
// The output is a stream of IDR NAL units (EBSP, no start codes) plus
// SPS/PPS builders, ready to feed [Mp4Muxer]. Verified against ffmpeg:
// every produced file must decode with pixel-identical (for PCM regions)
// or near-identical (prediction regions) content.

import 'dart:math' as math;
import 'dart:typed_data';

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

/// H.264 Baseline, IDR-only, I_16x16 + I_PCM macroblock encoder.
class H264IdrEncoder {
  H264IdrEncoder({
    required this.width,
    required this.height,
    this.fps = 20,
    this.flatThreshold = 6,
  })  : assert(width > 0 && height > 0),
        mbWidth = (width + 15) >> 4,
        mbHeight = (height + 15) >> 4 {
    _y = Uint8List(mbWidth * 16 * mbHeight * 16);
    _cb = Uint8List(mbWidth * 8 * mbHeight * 8);
    _cr = Uint8List(mbWidth * 8 * mbHeight * 8);
    _yRec = Uint8List.fromList(_y);
    _cbRec = Uint8List.fromList(_cb);
    _crRec = Uint8List.fromList(_cr);
  }

  final int width;
  final int height;
  final double fps;

  /// Max per-sample error tolerated for a predicted (flat) macroblock.
  /// Larger values shrink the file; 6 is visually lossless for painting
  /// content after the limited-range round-trip.
  final int flatThreshold;

  final int mbWidth;
  final int mbHeight;

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
    b.se(0); // pic_init_qp_minus26 → QP 26
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
    b.se(0); // slice_qp_delta (QP = 26)
    b.ue(1); // disable_deblocking_filter_idc = 1 (filter disabled)

    lastPcmMacroblocks = 0;
    lastFlatMacroblocks = 0;
    _mbIsPcm.fillRange(0, _mbIsPcm.length, false);
    for (var mbY = 0; mbY < mbHeight; mbY++) {
      for (var mbX = 0; mbX < mbWidth; mbX++) {
        _encodeMacroblock(b, mbX, mbY);
      }
    }
    b.rbspTrailing();
    return rbspToEbsp(b.takeBytes());
  }

  // Per-macroblock prediction candidates: 0 = vertical, 1 = horizontal,
  // 2 = DC. mb_type = 1 + mode + 4*cbpChroma + (cbpLuma15 ? 1 : 0).
  // Chroma mode is an INDEPENDENT syntax element (intra_chroma_pred_mode
  // ue(v)) written for I_16x16 as well, with its own numbering:
  // 0=DC, 1=Horizontal, 2=Vertical.
  void _encodeMacroblock(BitWriter b, int mbX, int mbY) {
    final canV = mbY > 0;
    final canH = mbX > 0;

    // Luma mode choice.
    var bestMode = 2;
    var bestErrY = _lumaError(mbX, mbY, 2);
    if (canV) {
      final e = _lumaError(mbX, mbY, 0);
      if (e < bestErrY) {
        bestErrY = e;
        bestMode = 0;
      }
    }
    if (canH) {
      final e = _lumaError(mbX, mbY, 1);
      if (e < bestErrY) {
        bestErrY = e;
        bestMode = 1;
      }
    }

    // Chroma mode choice (independent syntax element).
    var bestCMode = 2;
    var bestErrC = _chromaError(mbX, mbY, 2);
    if (canV) {
      final e = _chromaError(mbX, mbY, 0);
      if (e < bestErrC) {
        bestErrC = e;
        bestCMode = 0;
      }
    }
    if (canH) {
      final e = _chromaError(mbX, mbY, 1);
      if (e < bestErrC) {
        bestErrC = e;
        bestCMode = 1;
      }
    }

    if (bestErrY <= flatThreshold && bestErrC <= flatThreshold) {
      // I_16x16, zero residuals. Cross-checked against x264's
      // cavlc_mb_header_i (fix table is identity over V=0,H=1,DC=2,P=3):
      // mb_type = 1 + predMode + 4*cbpChroma + 12*(cbpLuma==15).
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
      // Luma DC block: coded with 0 coefficients. nC depends only on
      // whether neighbours are PCM (16) or flat (0): two buckets only.
      final nC = _nCBucket(mbX, mbY);
      if (nC == 0) {
        // coeff_token (total=0, t1=0), nC < 2 → '1'.
        b.u(1, 1);
      } else {
        // nC >= 8 → fixed 6-bit code '000011'.
        b.u(6, 3);
      }
      _mbIsPcm[mbY * mbWidth + mbX] = false;
      lastFlatMacroblocks++;
      // Reconstruction = predicted values for the whole 16x16 / 8x8s.
      _applyFlatReconstruction(mbX, mbY, bestMode, bestCMode);
    } else {
      // I_PCM: mb_type 25, byte-align, raw samples.
      b.ue(25);
      _mbIsPcm[mbY * mbWidth + mbX] = true;
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
      lastPcmMacroblocks++;
    }
  }

  /// Max per-sample luma error under luma prediction [mode].
  int _lumaError(int mbX, int mbY, int mode) {
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

  /// Max per-sample chroma error under chroma prediction [mode].
  int _chromaError(int mbX, int mbY, int mode) {
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

  /// nC bucket for the all-zero luma-DC block of a flat macroblock,
  /// mirroring ffmpeg's pred_non_zero_count exactly:
  ///   i = nA + nB; if (i < 64) i = (i + 1) >> 1; nC = i & 31;
  /// with neighbour values flat=0, PCM=16, unavailable=0x40 (64).
  /// - all flat/unavailable combos → nC = 0 → band 0 ('1')
  ///   (0+0, 0+64, 64+64 all &31 to 0),
  /// - any PCM neighbour → nC = 8/16 → band 3 ('000011').
  int _nCBucket(int mbX, int mbY) {
    final pcmL = mbX > 0 && _mbIsPcm[mbY * mbWidth + mbX - 1];
    final pcmT = mbY > 0 && _mbIsPcm[(mbY - 1) * mbWidth + mbX];
    return (pcmL || pcmT) ? 1 : 0;
  }

  /// Marks which macroblocks were coded as PCM (for nC derivation of
  /// neighbouring flat blocks). Reset at the start of every frame.
  late final List<bool> _mbIsPcm =
      List<bool>.filled(mbWidth * mbHeight, false);

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
