// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// cavlc_literal.dart — a byte-faithful translation of FFmpeg's
// decode_residual() CAVLC path (including the cavlc_level_tab 8-bit
// window fast path), used to adjudicate when the simple parser and the
// encoder disagree about the bitstream semantics.

import 'dart:io';
import 'dart:typed_data';

import 'package:feather_krita/io/h264_cavlc_tables.dart';


class BitReader {
  BitReader(this.bytes);
  final Uint8List bytes;
  int pos = 0;
  int read1() {
    final bit = (bytes[pos >> 3] >> (7 - (pos & 7))) & 1;
    pos++;
    return bit;
  }

  int readBits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | read1();
    }
    return v;
  }

  int ue() {
    var zeros = 0;
    while (read1() == 0) {
      zeros++;
    }
    return (1 << zeros) - 1 + (zeros == 0 ? 0 : readBits(zeros));
  }

  int se() {
    final k = ue();
    return k.isOdd ? (k + 1) ~/ 2 : -(k ~/ 2);
  }
}

// cavlc_level_tab[suffix][window8] = (levelCode, length) exactly as
// init_cavlc_level_tab builds it.
final List<List<List<int>>> levelTab = List.generate(7, (s) {
  final tab = List.generate(1 << 8, (_) => [0, 0]);
  for (var i = 0; i < 256; i++) {
    // av_log2(2*i): position of the highest set bit of 2*i (0 for 2i=0).
    final twoI = 2 * i;
    final log2twoI = twoI == 0 ? 0 : 31 - _clz(twoI);
    final prefix = 8 - log2twoI;
    if (prefix + 1 + s <= 8) {
      final log2i = i == 0 ? 0 : 31 - _clz(i);
      var lc = (prefix << s) + (i >> (log2i - s)) - (1 << s);
      final mask = -(lc & 1);
      lc = (((2 + lc) >> 1) ^ mask) - mask;
      tab[i][0] = lc;
      tab[i][1] = prefix + 1 + s;
    } else if (prefix + 1 <= 8) {
      tab[i][0] = prefix + 100;
      tab[i][1] = prefix + 1;
    } else {
      tab[i][0] = 8 + 100;
      tab[i][1] = 8;
    }
  }
  return tab;
});

int _clz(int x) {
  var n = 0;
  for (var b = 31; b >= 0; b--) {
    if (x & (1 << b) != 0) break;
    n++;
  }
  return n;
}

Map<String, int> vlcMap(List<int> lens, List<int> bits) {
  final m = <String, int>{};
  for (var k = 0; k < lens.length; k++) {
    if (lens[k] == 0) continue;
    m[bits[k].toRadixString(2).padLeft(lens[k], '0')] = k;
  }
  return m;
}

int readVlc(BitReader r, Map<String, int> m, String what) {
  var code = '';
  for (var i = 0; i < 33; i++) {
    code += r.read1().toString();
    final s = m[code];
    if (s != null) return s;
  }
  throw StateError('invalid VLC for $what: $code');
}

late List<Map<String, int>> ctMaps;
late Map<String, int> chromaDcCtMap;
late List<Map<String, int>> tzMaps;
late List<Map<String, int>> chDcTzMaps;
late List<Map<String, int>> runMaps;
late Map<String, int> run7Map;

void initMaps() {
  ctMaps = [
    for (final band in [0, 1, 2, 3])
      vlcMap(kCoeffTokenLen[band], kCoeffTokenBits[band]),
  ];
  chromaDcCtMap = vlcMap(kChromaDcCoeffTokenLen, kChromaDcCoeffTokenBits);
  tzMaps = [
    for (var tc = 1; tc <= 15; tc++)
      vlcMap(kTotalZerosLen[tc - 1], kTotalZerosBits[tc - 1]),
  ];
  chDcTzMaps = [
    for (var tc = 1; tc <= 3; tc++)
      vlcMap(kChromaDcTotalZerosLen[tc - 1], kChromaDcTotalZerosBits[tc - 1]),
  ];
  runMaps = [
    for (var z = 0; z < 6; z++) vlcMap(kRunLen[z], kRunBits[z]),
  ];
  run7Map = vlcMap(kRunLen[6], kRunBits[6]);
}

/// Literal translation of FFmpeg's level parsing inside decode_residual.
/// Returns the levels in decode order (highest zigzag first).
List<int> parseLevels(BitReader r, int tc, int t1, int maxCoeff) {
  final levels = List<int>.filled(16, 0);
  var i = 0;
  // show 3 bits for trailing ones signs (ffmpeg: i=show_bits(3))
  final sb = t1 > 0 ? r.readBits(t1) : 0;
  for (var k = 0; k < t1; k++) {
    final bit = (sb >> (t1 - 1 - k)) & 1;
    levels[k] = bit == 1 ? -1 : 1;
  }
  if (t1 < tc) {
    var suffixLength = ((tc > 10) && (t1 < 3)) ? 1 : 0;
    // --- first coefficient ---
    {
      final bitsi = r.readBits(8);
      var levelCode = levelTab[suffixLength][bitsi][0];
      r.pos -= 8 - levelTab[suffixLength][bitsi][1];
      if (levelCode >= 100) {
        var prefix = levelCode - 100;
        if (prefix == 8) {
          // get_level_prefix counts zeros up to (and consuming) the '1'.
          var extra = 0;
          while (r.read1() == 0) {
            extra++;
          }
          prefix += extra;
        }
        // first coefficient rules
        if (prefix < 14) {
          levelCode = suffixLength != 0 ? (prefix << 1) + r.readBits(1) : prefix;
        } else if (prefix == 14) {
          levelCode = suffixLength != 0 ? (prefix << 1) + r.readBits(1) : prefix + r.readBits(4);
        } else {
          levelCode = 30;
          if (prefix >= 16) {
            levelCode += (1 << (prefix - 3)) - 4096;
          }
          levelCode += r.readBits(prefix - 3);
        }
        if (t1 < 3) levelCode += 2;
        suffixLength = 2;
        final mask = -(levelCode & 1);
        levels[t1] = (((2 + levelCode) >> 1) ^ mask) - mask;
        i = t1 + 1;
      } else {
        levelCode += ((levelCode >> 31) | 1) & (t1 < 3 ? -1 : 0);
        levels[t1] = levelCode;
        suffixLength = 1 + (((levelCode + 3) & 0xFFFFFFFF) > 6 ? 1 : 0);
        i = t1 + 1;
      }
    }
    // --- remaining coefficients ---
    const suffixLimit = [0, 3, 6, 12, 24, 48, 1 << 30];
    for (; i < tc; i++) {
      final bitsi = r.readBits(8);
      var levelCode = levelTab[suffixLength][bitsi][0];
      r.pos -= 8 - levelTab[suffixLength][bitsi][1];
      if (levelCode >= 100) {
        var prefix = levelCode - 100;
        if (prefix == 8) {
          var extra = 0;
          while (r.read1() == 0) {
            extra++;
          }
          prefix += extra;
        }
        if (prefix < 15) {
          levelCode = (prefix << suffixLength) + r.readBits(suffixLength);
        } else {
          levelCode = 15 << suffixLength;
          if (prefix >= 16) {
            levelCode += (1 << (prefix - 3)) - 4096;
          }
          levelCode += r.readBits(prefix - 3);
        }
        final mask = -(levelCode & 1);
        levelCode = (((2 + levelCode) >> 1) ^ mask) - mask;
      }
      levels[i] = levelCode;
      // C unsigned wrap: (limit + level) > 2*limit as uint32 — wraps for
      // negative level beyond -limit; equivalent to |level| > limit.
      final lv = levels[i];
      final wrapped = lv >= 0
          ? suffixLimit[suffixLength] + lv > 2 * suffixLimit[suffixLength]
          : (suffixLimit[suffixLength] + lv) < 0;
      if (wrapped && suffixLength < 6) {
        suffixLength++;
      }
    }
  }
  return levels;
}

void main(List<String> args) {
  initMaps();
  final name = args.isNotEmpty ? args[0] : 'v3_chroma';
  final bytes = File('scripts/out/bisect_$name.h264').readAsBytesSync();
  // find the third start code (the IDR NAL)
  final nalStarts = <int>[];
  for (var i = 0; i < bytes.length - 3; i++) {
    if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1) {
      nalStarts.add(i + 3);
    }
  }
  final nalStart = nalStarts[2];
  final rbsp = <int>[];
  var zeros = 0;
  for (var i = nalStart; i < bytes.length; i++) {
    final b = bytes[i];
    if (zeros >= 2 && b == 3) {
      zeros = 0;
      continue;
    }
    rbsp.add(b);
    zeros = b == 0 ? zeros + 1 : 0;
  }
  final r = BitReader(Uint8List.fromList(rbsp));
  r.readBits(8);
  r.ue(); // first_mb
  r.ue(); // slice_type
  r.ue(); // pps
  r.readBits(4);
  r.ue(); // idr
  r.readBits(2);
  r.se();
  r.ue(); // deblocking

  final size = args.length > 1 ? int.parse(args[1]) : 16;
  final mbW = (size + 15) ~/ 16, mbH = (size + 15) ~/ 16;
  final nnz = List<int>.filled(mbW * mbH * 24, 0);
  int blockNnz(int mbX, int mbY, int base, int grid, int gr, int gc) {
    final self = (mbY * mbW + mbX) * 24;
    int nA, nB;
    if (gc > 0) {
      nA = nnz[self + base + gr * grid + gc - 1];
    } else if (mbX > 0) {
      nA = nnz[(mbY * mbW + mbX - 1) * 24 + base + gr * grid + grid - 1];
    } else {
      nA = 64;
    }
    if (gr > 0) {
      nB = nnz[self + base + (gr - 1) * grid + gc];
    } else if (mbY > 0) {
      nB = nnz[((mbY - 1) * mbW + mbX) * 24 + base + (grid - 1) * grid + gc];
    } else {
      nB = 64;
    }
    var i = nA + nB;
    if (i < 64) i = (i + 1) >> 1;
    return i & 31;
  }

  final dump = StringBuffer();
  for (var i = 0; i < 72; i++) {
    dump.write((rbsp[i >> 3] >> (7 - (i & 7))) & 1);
    if (i % 8 == 7) dump.write(' ');
  }
  print('first 72 bits: $dump (header ends at bit 28)');
  final mbType = r.ue();
  print('mb_type=$mbType (bit after mbtype=${r.pos})');
  final cbpC = (((mbType - 1) % 12) ~/ 4);
  final cbpL = ((mbType - 1) ~/ 12) == 1;
  r.ue(); // chroma pred
  r.se(); // qp delta

  for (var mbY = 0; mbY < mbH; mbY++) {
  for (var mbX = 0; mbX < mbW; mbX++) {
  final self = (mbY * mbW + mbX) * 24;
  // luma DC
  final nCdc = blockNnz(mbX, mbY, 0, 4, 0, 0);
  final ct = readVlc(r, ctMaps[nCdc >= 8 ? 3 : (nCdc >= 4 ? 2 : nCdc ~/ 2)],
      'coeff_token');
  var tc = ct >> 2, t1 = ct & 3;
  var levels = parseLevels(r, tc, t1, 16);
  var tz = tc < 16 ? readVlc(r, tzMaps[tc - 1], 'tz') : 0;
  var dcRuns = <int>[];
  var zl = tz;
  for (var k = 1; k < tc; k++) {
    if (zl > 0) {
      final row = zl < 7 ? zl - 1 : 6;
      final run = readVlc(r, row < 6 ? runMaps[row] : run7Map, 'dc run');
      dcRuns.add(run);
      zl -= run;
    } else {
      dcRuns.add(0);
    }
  }
  print('MB $mbX,$mbY L-DC: nC=$nCdc tc=$tc t1=$t1 tz=$tz runs=$dcRuns levels=$levels end=${r.pos}');
  // place and store nnz for the DC block? (not needed for nC)
  // luma AC
  if (cbpL) {
    for (var blk = 0; blk < 16; blk++) {
      final startB = r.pos;
      final nC = blockNnz(mbX, mbY, 0, 4, blk ~/ 4, blk % 4);
      final ct2 = readVlc(
          r, ctMaps[nC >= 8 ? 3 : (nC >= 4 ? 2 : nC ~/ 2)], 'coeff_token');
      tc = ct2 >> 2;
      t1 = ct2 & 3;
      levels = parseLevels(r, tc, t1, 15);
      tz = tc < 15 ? readVlc(r, tzMaps[tc - 1], 'tz') : 0;
      final runs = <int>[];
      var zerosLeft = tz;
      for (var k = 1; k < tc; k++) {
        if (zerosLeft > 0) {
          final row = zerosLeft < 7 ? zerosLeft - 1 : 6;
          final run =
              readVlc(r, row < 6 ? runMaps[row] : run7Map, 'run');
          runs.add(run);
          zerosLeft -= run;
        } else {
          runs.add(0);
        }
      }
      if (tc > 0) {
        print('L$blk: nC=$nC tc=$tc t1=$t1 tz=$tz runs=$runs start=$startB end=${r.pos} '
            'levels=${levels.take(tc).toList()}');
      }
      nnz[self + blk] = tc;
    }
  }
  if (cbpC >= 1) {
    for (var plane = 0; plane < 2; plane++) {
      final ct2 = readVlc(r, chromaDcCtMap, 'chroma coeff_token');
      tc = ct2 >> 2;
      t1 = ct2 & 3;
      levels = parseLevels(r, tc, t1, 4);
      tz = tc < 4 ? readVlc(r, chDcTzMaps[tc - 1], 'chroma tz') : 0;
      print('${plane == 0 ? 'Cb' : 'Cr'}DC: tc=$tc t1=$t1 tz=$tz '
          'levels=${levels.take(tc).toList()}');
    }
  }
  if (cbpC >= 2) {
    for (var plane = 0; plane < 2; plane++) {
      for (var blk = 0; blk < 4; blk++) {
        final nC = blockNnz(mbX, mbY, 16 + plane * 4, 2, blk ~/ 2, blk % 2);
        final ct2 = readVlc(
            r, ctMaps[nC >= 8 ? 3 : (nC >= 4 ? 2 : nC ~/ 2)], 'coeff_token');
        tc = ct2 >> 2;
        t1 = ct2 & 3;
        levels = parseLevels(r, tc, t1, 15);
        tz = tc < 15 ? readVlc(r, tzMaps[tc - 1], 'tz') : 0;
        final runs = <int>[];
        var zerosLeft = tz;
        for (var k = 1; k < tc; k++) {
          if (zerosLeft > 0) {
            final row = zerosLeft < 7 ? zerosLeft - 1 : 6;
            final run =
                readVlc(r, row < 6 ? runMaps[row] : run7Map, 'run');
            runs.add(run);
            zerosLeft -= run;
          } else {
            runs.add(0);
          }
        }
        if (tc > 0) {
          print('${plane == 0 ? 'Cb' : 'Cr'}$blk: nC=$nC tc=$tc t1=$t1 '
              'tz=$tz runs=$runs levels=${levels.take(tc).toList()}');
        }
        nnz[self + 16 + plane * 4 + blk] = tc;
      }
    }
  }
  }
  }
  print('literal parse done at bit ${r.pos} of ${rbsp.length * 8}');
}
