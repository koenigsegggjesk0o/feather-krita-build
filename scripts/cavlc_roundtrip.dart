// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// cavlc_roundtrip.dart — mini CAVLC decoder that mirrors ffmpeg's
// decode_residual; parses the encoder's slice NAL and cross-checks the
// parsed blocks against the encoder's own debug trace.

import 'dart:io';
import 'dart:typed_data';

import 'package:feather_krita/io/h264_cavlc_tables.dart';
import 'package:feather_krita/io/h264_encoder.dart';

import 'cavlc_debug.dart';
import 'cavlc_bisect.dart' as bisect;

class BitReader {
  BitReader(this.bytes);
  final Uint8List bytes;
  int pos = 0; // bit position

  int read1() {
    final byte = bytes[pos >> 3];
    final bit = (byte >> (7 - (pos & 7))) & 1;
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
    if (s != null) {
      if (verbose) print('      vlc $what: $code -> $s');
      return s;
    }
  }
  throw StateError('invalid VLC for $what: $code');
}

bool verbose = false;

late Map<String, Map<String, int>> ctMaps;
late Map<String, int> chromaDcCtMap;
late List<Map<String, int>> tzMaps;
late List<Map<String, int>> chDcTzMaps;
late List<Map<String, int>> runMaps;
late Map<String, int> run7Map;

void initMaps() {
  ctMaps = <String, Map<String, int>>{
    for (final band in [0, 1, 2, 3])
      band.toString(): vlcMap(kCoeffTokenLen[band], kCoeffTokenBits[band]),
  };
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

/// Parsed block info for comparison with the encoder trace.
class ParsedBlock {
  ParsedBlock(this.tc, this.t1, this.tz, this.levels);
  final int tc;
  final int t1;
  final int tz;
  final List<int> levels; // dense zigzag order
}

ParsedBlock parseBlock(BitReader r, int maxCoeff, int band,
    {bool chromaDc = false}) {
  final ctMap = chromaDc ? chromaDcCtMap : ctMaps[band.toString()]!;
  final sym = readVlc(r, ctMap, 'coeff_token');
  final tc = sym >> 2, t1 = sym & 3;
  if (tc > maxCoeff) {
    throw StateError('tc=$tc > maxCoeff=$maxCoeff — bitstream desync');
  }
  if (tc == 0) return ParsedBlock(0, 0, 0, List.filled(maxCoeff, 0));
  final levels = List<int>.filled(maxCoeff, 0);
  final vals = <int>[];
  for (var k = 0; k < t1; k++) {
    vals.add(r.read1() == 1 ? -1 : 1);
  }
  if (t1 < tc) {
    final suffixLimit = const <int>[0, 3, 6, 12, 24, 48, 1 << 30];
    var suffix = (tc > 10 && t1 < 3) ? 1 : 0;
    for (var k = t1; k < tc; k++) {
      var p = 0;
      while (r.read1() == 0) {
        p++;
        if (p > 30) throw StateError('level prefix runaway');
      }
      if (verbose) print('      level k=$k p=$p suffix=$suffix');
      int lc;
      if (k == t1) {
        if (suffix == 0) {
          if (p < 14) {
            lc = p;
          } else if (p == 14) {
            lc = 14 + r.readBits(4);
          } else if (p == 15) {
            lc = 30 + r.readBits(12);
          } else {
            lc = 30 + ((1 << (p - 3)) - 4096) + r.readBits(p - 3);
          }
          if (t1 < 3) lc += 2;
        } else {
          if (p < 14) {
            lc = (p << 1) + r.readBits(1);
          } else if (p == 14) {
            lc = 28 + r.readBits(1);
          } else if (p == 15) {
            lc = 30 + r.readBits(12);
          } else {
            lc = 30 + ((1 << (p - 3)) - 4096) + r.readBits(p - 3);
          }
          if (t1 < 3) lc += 2;
        }
      } else {
        if (p < 15) {
          lc = (p << suffix) + (suffix > 0 ? r.readBits(suffix) : 0);
        } else {
          lc = (15 << suffix) + r.readBits(12);
        }
      }
      final level = lc.isEven ? (2 + lc) >> 1 : -((2 + lc) >> 1);
      if (verbose) print('      level k=$k lc=$lc -> $level');
      vals.add(level);
      if (k == t1) {
        suffix = level.abs() > 3 ? 2 : 1;
      } else if (level.abs() > suffixLimit[suffix] && suffix < 6) {
        suffix++;
      }
    }
  }
  var tz = 0;
  if (tc < maxCoeff) {
    tz = chromaDc
        ? readVlc(r, chDcTzMaps[tc - 1], 'chroma tz')
        : readVlc(r, tzMaps[tc - 1], 'tz');
    if (tz > maxCoeff - tc) {
      throw StateError('parsed tz=$tz too big for tc=$tc/$maxCoeff');
    }
  } else {
    tz = 0;
  }
  final runs = <int>[0];
  var zerosLeft = tz;
  for (var k = 1; k < tc; k++) {
    if (zerosLeft > 0) {
      final row = zerosLeft < 7 ? zerosLeft - 1 : 6;
      final run = readVlc(r, row < 6 ? runMaps[row] : run7Map, 'run');
      runs.add(run);
      zerosLeft -= run;
    } else {
      runs.add(0);
    }
  }
  var cur = tz + tc - 1;
  for (var k = 0; k < tc; k++) {
    levels[cur] = vals[k];
    if (k + 1 < tc) cur -= 1 + runs[k + 1];
  }
  return ParsedBlock(tc, t1, tz, levels);
}

/// Extracts the ordered block expectations from the encoder trace.
class TraceBlock {
  TraceBlock(this.kind, this.tc, this.t1, this.tz, this.levels, this.pos);
  final String kind;
  final int tc, t1, tz;
  final List<int> levels;
  final String pos; // ascending dense positions, from the encoder trace
}

List<Object> parseTrace(List<String> lines) {
  // Returns alternating MB headers (String) and TraceBlock entries.
  final out = <Object>[];
  final re = RegExp(
      r'^(.*?): tc=(\d+) t1=(\d+) nC=(\d+) tz=(\d+) endBit=(\d+) pos=\[([0-9, ]*)\] levels=\[(-?\d*(?:, -?\d*)*)\]$');
  final re0 = RegExp(r'^(.*?): tc=0 nC=(\d+)$');
  final reMb = RegExp(r'^MB (\d+),(\d+) type=(\d+)');
  for (final line in lines) {
    final mb = reMb.firstMatch(line);
    if (mb != null) {
      out.add('MB ${mb[1]},${mb[2]} type=${mb[3]}');
      continue;
    }
    final m0 = re0.firstMatch(line);
    if (m0 != null) {
      out.add(TraceBlock(m0[1]!, 0, 0, 0, [], ''));
      continue;
    }
    final m = re.firstMatch(line);
    if (m != null) {
      final levelsStr = m[8]!;
      final levels = levelsStr.isEmpty
          ? <int>[]
          : levelsStr.split(', ').map(int.parse).toList();
      out.add(TraceBlock(m[1]!, int.parse(m[2]!), int.parse(m[3]!),
          int.parse(m[5]!), levels, m[7]!));
      continue;
    }
    // skip lines that don't match (chroma plane headers etc.)
  }
  return out;
}

void main(List<String> args) {
  initMaps();
  final sizeArg = args.where((a) => int.tryParse(a) != null).toList();
  final size = sizeArg.isNotEmpty ? int.parse(sizeArg[0]) : 32;
  final enc = H264IdrEncoder(width: size, height: size, fps: 20);
  final trace = <String>[];
  H264IdrEncoder.debugTrace = trace.add;
  final useColor = args.contains('--color');
  enc.loadRgba(useColor
      ? bisect.chromaRamp(size, size, 128, 80)
      : gradientFrame(size, size));
  final nal = enc.encodeIdr();
  H264IdrEncoder.debugTrace = null;
  print('nal bytes=${nal.length}');
  File('scripts/out/trace.txt').writeAsStringSync(trace.join('\n'));
  File('scripts/out/rt_nal.bin').writeAsBytesSync(nal);
  final expected = parseTrace(trace);

  final rbsp = <int>[];
  var zeros = 0;
  for (final b in nal) {
    if (zeros >= 2 && b == 3) {
      zeros = 0;
      continue;
    }
    rbsp.add(b);
    zeros = b == 0 ? zeros + 1 : 0;
  }
  final r = BitReader(Uint8List.fromList(rbsp));
  r.readBits(8); // NAL header
  r.ue(); // first_mb_in_slice
  r.ue(); // slice_type
  r.ue(); // pps_id
  r.readBits(4); // frame_num
  r.ue(); // idr_pic_id
  r.readBits(2); // dec_ref_pic_marking
  r.se(); // slice_qp_delta
  r.ue(); // disable_deblocking_filter_idc

  // bit dump for manual inspection
  final dump = StringBuffer();
  for (var i = 0; i < 48; i++) {
    dump.write((rbsp[i >> 3] >> (7 - (i & 7))) & 1);
    if (i % 8 == 7) dump.write(' ');
  }
  print('first 48 bits: $dump');

  final mbW = (size + 15) >> 4, mbH = (size + 15) >> 4;
  final nnz = List<int>.filled(mbW * mbH * 24, 0);
  int blockNnz(int mbX, int mbY, int base, int grid, int gr, int gc) {
    int nA;
    if (gc > 0) {
      nA = nnz[(mbY * mbW + mbX) * 24 + base + gr * grid + gc - 1];
    } else if (mbX > 0) {
      nA = nnz[(mbY * mbW + mbX - 1) * 24 + base + gr * grid + grid - 1];
    } else {
      nA = 64;
    }
    int nB;
    if (gr > 0) {
      nB = nnz[(mbY * mbW + mbX) * 24 + base + (gr - 1) * grid + gc];
    } else if (mbY > 0) {
      nB = nnz[((mbY - 1) * mbW + mbX) * 24 + base + (grid - 1) * grid + gc];
    } else {
      nB = 64;
    }
    var i = nA + nB;
    if (i < 64) i = (i + 1) >> 1;
    return i & 31;
  }

  var expIdx = 0;
  var failures = 0;
  void check(String kind, ParsedBlock pb, [int? bitPos]) {
    if (verbose) print('  check $kind start=$bitPos end=${r.pos}');
    // find the next expected block with the same kind
    while (expIdx < expected.length &&
        expected[expIdx] is String) {
      expIdx++;
    }
    if (expIdx >= expected.length) {
      print('  NO EXPECTATION for $kind: parsed tc=${pb.tc} tz=${pb.tz}');
      failures++;
      return;
    }
    final exp = expected[expIdx++] as TraceBlock;
    final okTc = exp.tc == pb.tc;
    final okT1 = exp.t1 == pb.t1;
    final okTz = exp.tz == pb.tz;
    // Compare position-aware: expected levels sit at exp.pos ascending.
    final posList = exp.pos.isEmpty
        ? <int>[]
        : exp.pos.split(', ').map(int.parse).toList();
    var okLv = posList.length == exp.levels.length;
    if (okLv) {
      for (var i = 0; i < posList.length; i++) {
        if (pb.levels[posList[i]] != exp.levels[i]) {
          okLv = false;
        }
      }
    }
    if (!okTc || !okT1 || !okTz || !okLv) {
      failures++;
      print('  MISMATCH $kind: parsed(tc=${pb.tc},t1=${pb.t1},tz=${pb.tz},'
          'lv=${pb.levels}) expected(tc=${exp.tc},t1=${exp.t1},tz=${exp.tz},'
          'pos=$posList lv=${exp.levels})');
    }
  }

  var parsed = 0;
  verbose = args.contains('-v');
  final maxMbs = args.contains('-v') ? 1 : 1 << 30;
  for (var mbY = 0; mbY < mbH && failures == 0; mbY++) {
    for (var mbX = 0; mbX < mbW && failures == 0 && parsed < maxMbs; mbX++) {
      final mbStart = r.pos;
      final mbType = r.ue();
      if (verbose) print('MB $mbX,$mbY parsed type=$mbType start=$mbStart');
      if (mbType >= 25) {
        print('DESYNC at MB $mbX,$mbY: mb_type=$mbType');
        failures++;
        break;
      }
      final cbpC = (((mbType - 1) % 12) ~/ 4);
      final cbpL = ((mbType - 1) ~/ 12) == 1;
      r.ue(); // chroma pred mode
      r.se(); // mb_qp_delta
      final nCdc = blockNnz(mbX, mbY, 0, 4, 0, 0);
      if (verbose) print('  bits after header: pos=${r.pos}');
      {final startPos = r.pos;
      final pb = parseBlock(r, 16, coeffTokenBand(nCdc));
      if (verbose) print('  L-DC raw: tc=${pb.tc} t1=${pb.t1} start=$startPos end=${r.pos}');
      check('L-DC', pb, startPos);}
      if (cbpL) {
        for (var blk = 0; blk < 16; blk++) {
          final nC = blockNnz(mbX, mbY, 0, 4, blk ~/ 4, blk % 4);
          final pb = parseBlock(r, 15, coeffTokenBand(nC));
          check('L$blk', pb);
          nnz[(mbY * mbW + mbX) * 24 + blk] = pb.tc;
        }
      }
      if (cbpC >= 1) {
        for (var plane = 0; plane < 2; plane++) {
          check(plane == 0 ? 'CbDC' : 'CrDC',
              parseBlock(r, 4, 0, chromaDc: true));
        }
      }
      if (cbpC >= 2) {
        for (var plane = 0; plane < 2; plane++) {
          for (var blk = 0; blk < 4; blk++) {
            final nC =
                blockNnz(mbX, mbY, 16 + plane * 4, 2, blk ~/ 2, blk % 2);
            final pb = parseBlock(r, 15, coeffTokenBand(nC));
            check('${plane == 0 ? 'Cb' : 'Cr'}$blk', pb);
            nnz[(mbY * mbW + mbX) * 24 + 16 + plane * 4 + blk] = pb.tc;
          }
        }
      }
      parsed++;
    }
  }
  print(failures == 0
      ? 'ALL BLOCKS MATCH ($parsed MBs, bits consumed=${r.pos}/${rbsp.length * 8})'
      : 'FAILURES: $failures');
}
