// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// h264_cavlc_tables.dart — CAVLC + quantization tables for the pure-Dart
// H.264 encoder, transcribed from FFmpeg's libavcodec/h264_cavlc.c and
// h264_ps.c (the decoder this encoder is verified against), so the
// encoder and the reference decoder share bit-identical tables.
//
// Table layouts mirror the ffmpeg arrays:
//  - coeffToken:   [nC band 0..3][(totalCoeff*4 + trailingOnes)] -> (len,bits)
//    band = nC<2?0 : nC<4?1 : nC<8?2 : 3  (ffmpeg coeff_token_table_index).
//  - chroma DC 2x2 coeff_token: ONE fixed table (no nC dependence),
//    indexed [totalCoeff*4 + trailingOnes] (max 4 coefficients).
//  - totalZeros:   [totalCoeff-1][totalZeros] (4x4 blocks, 16 or 15 slots).
//  - chromaDcTotalZeros: [totalCoeff-1][totalZeros] (2x2 block).
//  - runBefore:    [min(zerosLeft,7)-1][run] (row 6 holds the >=7 escapes).
//  - dequant4Init: ff_h264_dequant4_coeff_init[qp%6][class] with
//    class = (col&1) + (row&1)  (0 = even/even, 1 = mixed, 2 = odd/odd);
//    qmul = dequant4Init * 16 << (qp~/6 + 2)  (default scaling matrix 16).
//  - chromaQpTable: luma QP -> chroma QP for 8-bit 4:2:0.

/// 4x4 zigzag scan: zigzag position -> raster index (row*4+col).
const List<int> h264ZigzagScan = <int>[
  0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 10, 7, 13, 11, 14, 15,
];

/// coeff_token code lengths, [band][totalCoeff*4 + trailingOnes].
const List<List<int>> kCoeffTokenLen = <List<int>>[
  <int>[
    1, 0, 0, 0,
    6, 2, 0, 0, 8, 6, 3, 0, 9, 8, 7, 5, 10, 9, 8, 6,
    11, 10, 9, 7, 13, 11, 10, 8, 13, 13, 11, 9, 13, 13, 13, 10,
    14, 14, 13, 11, 14, 14, 14, 13, 15, 15, 14, 14, 15, 15, 15, 14,
    16, 15, 15, 15, 16, 16, 16, 15, 16, 16, 16, 16, 16, 16, 16, 16,
  ],
  <int>[
    2, 0, 0, 0,
    6, 2, 0, 0, 6, 5, 3, 0, 7, 6, 6, 4, 8, 6, 6, 4,
    8, 7, 7, 5, 9, 8, 8, 6, 11, 9, 9, 6, 11, 11, 11, 7,
    12, 11, 11, 9, 12, 12, 12, 11, 12, 12, 12, 11, 13, 13, 13, 12,
    13, 13, 13, 13, 13, 14, 13, 13, 14, 14, 14, 13, 14, 14, 14, 14,
  ],
  <int>[
    4, 0, 0, 0,
    6, 4, 0, 0, 6, 5, 4, 0, 6, 5, 5, 4, 7, 5, 5, 4,
    7, 5, 5, 4, 7, 6, 6, 4, 7, 6, 6, 4, 8, 7, 7, 5,
    8, 8, 7, 6, 9, 8, 8, 7, 9, 9, 8, 8, 9, 9, 9, 8,
    10, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  ],
  <int>[
    6, 0, 0, 0,
    6, 6, 0, 0, 6, 6, 6, 0, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  ],
];

/// coeff_token code words (bit values), same layout as [kCoeffTokenLen].
const List<List<int>> kCoeffTokenBits = <List<int>>[
  <int>[
    1, 0, 0, 0,
    5, 1, 0, 0, 7, 4, 1, 0, 7, 6, 5, 3, 7, 6, 5, 3,
    7, 6, 5, 4, 15, 6, 5, 4, 11, 14, 5, 4, 8, 10, 13, 4,
    15, 14, 9, 4, 11, 10, 13, 12, 15, 14, 9, 12, 11, 10, 13, 8,
    15, 1, 9, 12, 11, 14, 13, 8, 7, 10, 9, 12, 4, 6, 5, 8,
  ],
  <int>[
    3, 0, 0, 0,
    11, 2, 0, 0, 7, 7, 3, 0, 7, 10, 9, 5, 7, 6, 5, 4,
    4, 6, 5, 6, 7, 6, 5, 8, 15, 6, 5, 4, 11, 14, 13, 4,
    15, 10, 9, 4, 11, 14, 13, 12, 8, 10, 9, 8, 15, 14, 13, 12,
    11, 10, 9, 12, 7, 11, 6, 8, 9, 8, 10, 1, 7, 6, 5, 4,
  ],
  <int>[
    15, 0, 0, 0,
    15, 14, 0, 0, 11, 15, 13, 0, 8, 12, 14, 12, 15, 10, 11, 11,
    11, 8, 9, 10, 9, 14, 13, 9, 8, 10, 9, 8, 15, 14, 13, 13,
    11, 14, 10, 12, 15, 10, 13, 12, 11, 14, 9, 12, 8, 10, 13, 8,
    13, 7, 9, 12, 9, 12, 11, 10, 5, 8, 7, 6, 1, 4, 3, 2,
  ],
  <int>[
    3, 0, 0, 0,
    0, 1, 0, 0, 4, 5, 6, 0, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  ],
];

/// Chroma DC 2x2 coeff_token: fixed table (ffmpeg chroma_dc_coeff_token),
/// index [totalCoeff*4 + trailingOnes], totalCoeff 0..4.
const List<int> kChromaDcCoeffTokenLen = <int>[
  2, 0, 0, 0,
  6, 1, 0, 0,
  6, 6, 3, 0,
  6, 7, 7, 6,
  6, 8, 8, 7,
];

const List<int> kChromaDcCoeffTokenBits = <int>[
  1, 0, 0, 0,
  7, 1, 0, 0,
  4, 6, 1, 0,
  3, 3, 2, 5,
  2, 3, 2, 0,
];

/// total_zeros for 4x4 blocks: [totalCoeff-1][totalZeros] lengths.
const List<List<int>> kTotalZerosLen = <List<int>>[
  <int>[1, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9],
  <int>[3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6],
  <int>[4, 3, 3, 3, 4, 4, 3, 3, 4, 5, 5, 6, 5, 6],
  <int>[5, 3, 4, 4, 3, 3, 3, 4, 3, 4, 5, 5, 5],
  <int>[4, 4, 4, 3, 3, 3, 3, 3, 4, 5, 4, 5],
  <int>[6, 5, 3, 3, 3, 3, 3, 3, 4, 3, 6],
  <int>[6, 5, 3, 3, 3, 2, 3, 4, 3, 6],
  <int>[6, 4, 5, 3, 2, 2, 3, 3, 6],
  <int>[6, 6, 4, 2, 2, 3, 2, 5],
  <int>[5, 5, 3, 2, 2, 2, 4],
  <int>[4, 4, 3, 3, 1, 3],
  <int>[4, 4, 2, 1, 3],
  <int>[3, 3, 1, 2],
  <int>[2, 2, 1],
  <int>[1, 1],
];

/// total_zeros code words, same layout as [kTotalZerosLen].
const List<List<int>> kTotalZerosBits = <List<int>>[
  <int>[1, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 1],
  <int>[7, 6, 5, 4, 3, 5, 4, 3, 2, 3, 2, 3, 2, 1, 0],
  <int>[5, 7, 6, 5, 4, 3, 4, 3, 2, 3, 2, 1, 1, 0],
  <int>[3, 7, 5, 4, 6, 5, 4, 3, 3, 2, 2, 1, 0],
  <int>[5, 4, 3, 7, 6, 5, 4, 3, 2, 1, 1, 0],
  <int>[1, 1, 7, 6, 5, 4, 3, 2, 1, 1, 0],
  <int>[1, 1, 5, 4, 3, 3, 2, 1, 1, 0],
  <int>[1, 1, 1, 3, 3, 2, 2, 1, 0],
  <int>[1, 0, 1, 3, 2, 1, 1, 1],
  <int>[1, 0, 1, 3, 2, 1, 1],
  <int>[0, 1, 1, 2, 1, 3],
  <int>[0, 1, 1, 1, 1],
  <int>[0, 1, 1, 1],
  <int>[0, 1, 1],
  <int>[0, 1],
];

/// total_zeros for the chroma DC 2x2 block: [totalCoeff-1][totalZeros].
const List<List<int>> kChromaDcTotalZerosLen = <List<int>>[
  <int>[1, 2, 3, 3],
  <int>[1, 2, 2, 0],
  <int>[1, 1, 0, 0],
];

const List<List<int>> kChromaDcTotalZerosBits = <List<int>>[
  <int>[1, 1, 1, 0],
  <int>[1, 1, 0, 0],
  <int>[1, 0, 0, 0],
];

/// run_before lengths: [min(zerosLeft,7)-1][run]. Row 6 (zerosLeft >= 7)
/// carries the escape codes for run >= 7 ((run-4) zeros then a '1').
const List<List<int>> kRunLen = <List<int>>[
  <int>[1, 1],
  <int>[1, 2, 2],
  <int>[2, 2, 2, 2],
  <int>[2, 2, 2, 3, 3],
  <int>[2, 2, 3, 3, 3, 3],
  <int>[2, 3, 3, 3, 3, 3, 3],
  <int>[3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11],
];

const List<List<int>> kRunBits = <List<int>>[
  <int>[1, 0],
  <int>[1, 1, 0],
  <int>[3, 2, 1, 0],
  <int>[3, 2, 1, 1, 0],
  <int>[3, 2, 3, 2, 1, 0],
  <int>[3, 0, 1, 3, 2, 5, 4],
  <int>[7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1],
];

/// ff_h264_dequant4_coeff_init[qp % 6][class]: class 0 = even/even,
/// 1 = mixed parity, 2 = odd/odd. qmul = value * 16 << (qp ~/ 6 + 2).
const List<List<int>> kDequant4Init = <List<int>>[
  <int>[10, 13, 16],
  <int>[11, 14, 18],
  <int>[13, 16, 20],
  <int>[14, 18, 23],
  <int>[16, 20, 25],
  <int>[18, 23, 29],
];

/// Luma QP (0..51) -> chroma QP for 8-bit 4:2:0, chroma_qp_index_offset 0
/// (ffmpeg CHROMA_QP_TABLE_END(8)).
const List<int> kChromaQpTable = <int>[
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
  29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37,
  38, 38, 38, 39, 39, 39, 39,
];

/// nC -> coeff_token table band (ffmpeg coeff_token_table_index[17]).
int coeffTokenBand(int nC) {
  if (nC >= 8) return 3;
  return const <int>[0, 0, 1, 1, 2, 2, 2, 2][nC];
}

/// Dequantization multiplier for raster position [pos] (row*4+col) at
/// luma/chroma QP [qp], default scaling matrix (all 16).
/// Mirrors ffmpeg init_dequant4_coeff_table: init[qp%6][(pos&1)+((pos>>2)&1)]
/// * scaling_matrix4 (16) << (qp/6 + 2).
int dequant4Mul(int qp, int pos) {
  final cls = (pos & 1) + ((pos >> 2) & 1);
  return kDequant4Init[qp % 6][cls] * 16 << (qp ~/ 6 + 2);
}
