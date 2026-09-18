// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// mp4_muxer.dart — Minimal ISO-BMFF (MP4) writer for H.264 video tracks.
//
// Produces a fully standards-shaped MP4: ftyp + mdat + moov, with a
// single avc1 video track described through avcC (AVCC extradata, 4-byte
// NAL length prefixes). Output plays in ffmpeg/ffprobe, Chrome, VLC and
// Windows Media Player.
//
// Constraints by design (v1):
//   - one video track, no audio, no B-frames (IDR-only streams),
//   - one sample per chunk (stsc with a single entry),
//   - 32-bit chunk offsets (stco) — clips are far below 4 GB,
//   - fixed timescale of 90000 with per-sample deltas that distribute
//     the rounding remainder so the total duration is exact.

import 'dart:typed_data';

/// MP4 muxer for an AVC (H.264) elementary stream given as AVCC samples.
class Mp4Muxer {
  Mp4Muxer({
    required this.width,
    required this.height,
    required this.fps,
    required this.sps,
    required this.pps,
    required this.samples,
  });

  /// Display width/height in pixels (the coded picture size).
  final int width;
  final int height;

  /// Playback frame rate (> 0).
  final double fps;

  /// SPS NAL payload in EBSP form, without start code or length prefix.
  final Uint8List sps;

  /// PPS NAL payload in EBSP form, without start code or length prefix.
  final Uint8List pps;

  /// One entry per frame: the IDR NAL in EBSP form (no start code). Each
  /// is wrapped as a 4-byte-length-prefixed AVCC sample by [mux].
  final List<Uint8List> samples;

  static const int _timescale = 90000;
  static const int _movieTimescale = 1000;

  /// Builds the complete MP4 file.
  Uint8List mux() {
    assert(samples.isNotEmpty, 'mp4 muxer needs at least one sample');
    assert(fps > 0);

    // ---- Per-sample timing -------------------------------------------
    // Distribute the frame-duration rounding remainder over the first
    // samples so that sampleCount * avgDelta == totalDuration exactly.
    final count = samples.length;
    final exactDelta = _timescale / fps;
    final baseDelta = exactDelta.floor();
    final deltas = List<int>.filled(count, baseDelta > 0 ? baseDelta : 1);
    // Total track duration in timescale ticks, distributed so that the
    // rounding remainder lands on the earliest samples (keeps duration
    // exact and per-frame deltas nearly identical).
    final totalTicks = (_timescale * count / fps).round();
    var remainder = totalTicks - deltas[0] * count;
    for (var i = 0; remainder > 0 && i < count; i++, remainder--) {
      deltas[i] += 1;
    }
    final trackDuration =
        deltas.fold<int>(0, (sum, d) => sum + d); // in _timescale units
    final movieDurationMs =
        (trackDuration * _movieTimescale / _timescale).round();

    // ---- mdat layout ---------------------------------------------------
    // ftyp (fixed size) precedes mdat; compute the exact mdat payload
    // start, then place each AVCC sample sequentially.
    final avccSamples = <Uint8List>[
      for (final nal in samples) _avccWrap(nal),
    ];

    final ftypSize = _ftyp().length;
    final mdatHeaderSize = 8;
    var chunkOffset = ftypSize + mdatHeaderSize;
    final offsets = <int>[];
    for (final s in avccSamples) {
      offsets.add(chunkOffset);
      chunkOffset += s.length;
    }

    // ---- Assemble ------------------------------------------------------
    final bytes = BytesBuilder(copy: false);
    bytes.add(_ftyp());
    final mdat = BytesBuilder(copy: false);
    for (final s in avccSamples) {
      mdat.add(s);
    }
    bytes.add(_box('mdat', mdat));
    bytes.add(_moov(
      trackDuration: trackDuration,
      movieDurationMs: movieDurationMs,
      deltas: deltas,
      offsets: offsets,
      sampleSizes: [for (final s in avccSamples) s.length],
    ));
    return bytes.toBytes();
  }

  // ---------------------------------------------------------------------
  // Boxes
  // ---------------------------------------------------------------------

  Uint8List _avccWrap(Uint8List nal) {
    final b = BytesBuilder();
    final len = nal.length;
    b.addByte((len >> 24) & 0xff);
    b.addByte((len >> 16) & 0xff);
    b.addByte((len >> 8) & 0xff);
    b.addByte(len & 0xff);
    b.add(nal);
    return b.toBytes();
  }

  Uint8List _ftyp() {
    final b = BytesBuilder();
    b.add(_fourcc('isom'));
    b.add(_u32(0x200)); // minor version
    b.add(_fourcc('isom'));
    b.add(_fourcc('iso2'));
    b.add(_fourcc('avc1'));
    b.add(_fourcc('mp41'));
    return _box('ftyp', b);
  }

  Uint8List _moov({
    required int trackDuration,
    required int movieDurationMs,
    required List<int> deltas,
    required List<int> offsets,
    required List<int> sampleSizes,
  }) {
    final b = BytesBuilder();
    b.add(_mvhd(movieDurationMs));
    b.add(_trak(trackDuration, deltas, offsets, sampleSizes));
    return _box('moov', b);
  }

  Uint8List _mvhd(int durationMs) {
    final b = BytesBuilder();
    b.addByte(0); // version
    b.add(_u24(0)); // flags
    b.add(_u32(0)); // creation time
    b.add(_u32(0)); // modification time
    b.add(_u32(_movieTimescale));
    b.add(_u32(durationMs));
    b.add(_u32(0x00010000)); // rate 1.0
    b.add(_u16(0x0100)); // volume 1.0
    b.add(_u16(0)); // reserved
    b.add(_u32(0)); // reserved
    b.add(_u32(0)); // reserved
    // unity matrix
    b.add(_u32(0x00010000));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0x00010000));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0x40000000));
    // pre_defined (6 x u32)
    for (var i = 0; i < 6; i++) {
      b.add(_u32(0));
    }
    b.add(_u32(2)); // next_track_id
    return _fullBox('mvhd', b);
  }

  Uint8List _trak(
      int trackDuration, List<int> deltas, List<int> offsets,
      List<int> sampleSizes) {
    final b = BytesBuilder();
    b.add(_tkhd());
    b.add(_mdia(trackDuration, deltas, offsets, sampleSizes));
    return _box('trak', b);
  }

  Uint8List _tkhd() {
    final b = BytesBuilder();
    b.addByte(0); // version
    b.add(_u24(3)); // flags: enabled + in_movie
    b.add(_u32(0)); // creation
    b.add(_u32(0)); // modification
    b.add(_u32(1)); // track_id
    b.add(_u32(0)); // reserved
    b.add(_u32(0)); // duration (movie timescale; 0 is tolerated)
    b.add(_u32(0)); // reserved
    b.add(_u32(0)); // reserved
    b.add(_u16(0)); // layer
    b.add(_u16(0)); // alternate_group
    b.add(_u16(0)); // volume (video track)
    b.add(_u16(0)); // reserved
    // unity matrix
    b.add(_u32(0x00010000));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0x00010000));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_u32(0x40000000));
    b.add(_u32(width << 16)); // width 16.16
    b.add(_u32(height << 16)); // height 16.16
    return _fullBox('tkhd', b);
  }

  Uint8List _mdia(int trackDuration, List<int> deltas, List<int> offsets,
      List<int> sampleSizes) {
    final b = BytesBuilder();
    b.add(_mdhd(trackDuration));
    b.add(_hdlr());
    b.add(_minf(deltas, offsets, sampleSizes));
    return _box('mdia', b);
  }

  Uint8List _mdhd(int trackDuration) {
    final b = BytesBuilder();
    b.addByte(0);
    b.add(_u24(0));
    b.add(_u32(0)); // creation
    b.add(_u32(0)); // modification
    b.add(_u32(_timescale));
    b.add(_u32(trackDuration));
    b.add(_u16(0x55C4)); // language 'und' (ISO-639-2 packed)
    b.add(_u16(0)); // pre_defined
    return _fullBox('mdhd', b);
  }

  Uint8List _hdlr() {
    final b = BytesBuilder();
    b.addByte(0);
    b.add(_u24(0));
    b.add(_u32(0)); // pre_defined
    b.add(_fourcc('vide'));
    b.add(_u32(0)); // reserved
    b.add(_u32(0));
    b.add(_u32(0));
    b.add(_ascii('VideoHandler'));
    b.addByte(0); // null-terminated name
    return _fullBox('hdlr', b);
  }

  Uint8List _minf(List<int> deltas, List<int> offsets, List<int> sampleSizes) {
    final b = BytesBuilder();
    b.add(_vmhd());
    b.add(_dinf());
    b.add(_stbl(deltas, offsets, sampleSizes));
    return _box('minf', b);
  }

  Uint8List _vmhd() {
    final b = BytesBuilder();
    b.addByte(0);
    b.add(_u24(1)); // flags
    b.add(_u16(0)); // graphicsmode: copy
    b.add(_u16(0)); // opcolor r
    b.add(_u16(0)); // opcolor g
    b.add(_u16(0)); // opcolor b
    return _fullBox('vmhd', b);
  }

  Uint8List _dinf() {
    final url = BytesBuilder();
    url.addByte(0);
    url.add(_u24(1)); // flags: self-contained
    final drefBody = BytesBuilder();
    drefBody.addByte(0); // version
    drefBody.add(_u24(0)); // flags
    drefBody.add(_u32(1)); // entry_count
    drefBody.add(_fullBox('url ', url));
    final drefBox = _box('dref', drefBody);
    final dinfBody = BytesBuilder();
    dinfBody.add(drefBox);
    return _box('dinf', dinfBody);
  }

  Uint8List _stbl(List<int> deltas, List<int> offsets, List<int> sampleSizes) {
    final b = BytesBuilder();
    b.add(_stsd());
    b.add(_stts(deltas));
    b.add(_stsc());
    b.add(_stsz(sampleSizes));
    b.add(_stco(offsets));
    return _box('stbl', b);
  }

  Uint8List _stsd() {
    final b = BytesBuilder();
    b.addByte(0); // version
    b.add(_u24(0)); // flags
    b.add(_u32(1)); // entry_count
    b.add(_avc1());
    return _fullBox('stsd', b);
  }

  Uint8List _avc1() {
    final b = BytesBuilder();
    b.add(List<int>.filled(6, 0)); // reserved
    b.add(_u16(1)); // data_reference_index
    b.add(_u16(0)); // pre_defined
    b.add(_u16(0)); // reserved
    b.add(List<int>.filled(12, 0)); // pre_defined/reserved
    b.add(_u16(width));
    b.add(_u16(height));
    b.add(_u32(0x00480000)); // horiz dpi 72
    b.add(_u32(0x00480000)); // vert dpi 72
    b.add(_u32(0)); // reserved
    b.add(_u16(1)); // frame count per sample
    b.add(List<int>.filled(32, 0)); // compressorname
    b.add(_u16(0x0018)); // depth
    b.add(_u16(0xFFFF)); // pre_defined (-1)
    b.add(_avcC());
    return _box('avc1', b);
  }

  Uint8List _avcC() {
    final b = BytesBuilder();
    b.addByte(1); // configurationVersion
    b.addByte(_profileByte(sps)); // AVCProfileIndication
    b.addByte(_compatByte(sps)); // profile_compatibility
    b.addByte(_levelByte(sps)); // AVCLevelIndication
    b.addByte(0xFF); // reserved 111111 + lengthSizeMinusOne=3
    b.addByte(0xE1); // reserved 111 + numSPS=1
    b.add(_u16(sps.length));
    b.add(sps);
    b.addByte(1); // numPPS=1
    b.add(_u16(pps.length));
    b.add(pps);
    return _box('avcC', b);
  }

  /// Extracts the profile_idc byte from an SPS: after the 1-byte
  /// nal_ref_idc/nal_unit_type header, profile_idc is the first byte.
  static int _profileByte(Uint8List sps) =>
      sps.length > 1 ? sps[1] : 66;

  static int _compatByte(Uint8List sps) =>
      sps.length > 2 ? sps[2] : 0;

  static int _levelByte(Uint8List sps) =>
      sps.length > 3 ? sps[3] : 30;

  Uint8List _stts(List<int> deltas) {
    final b = BytesBuilder();
    b.addByte(0); // version
    b.add(_u24(0)); // flags
    // Coalesce identical deltas into runs.
    final runs = <List<int>>[]; // [count, delta]
    for (final d in deltas) {
      if (runs.isNotEmpty && runs.last[1] == d) {
        runs.last[0] += 1;
      } else {
        runs.add([1, d]);
      }
    }
    b.add(_u32(runs.length));
    for (final r in runs) {
      b.add(_u32(r[0]));
      b.add(_u32(r[1]));
    }
    return _fullBox('stts', b);
  }

  Uint8List _stsc() {
    final b = BytesBuilder();
    b.addByte(0); // version
    b.add(_u24(0)); // flags
    b.add(_u32(1)); // entry_count
    b.add(_u32(1)); // first_chunk
    b.add(_u32(1)); // samples_per_chunk
    b.add(_u32(1)); // sample_description_index
    return _fullBox('stsc', b);
  }

  Uint8List _stsz(List<int> sampleSizes) {
    final b = BytesBuilder();
    b.addByte(0); // version
    b.add(_u24(0)); // flags
    b.add(_u32(0)); // sample_size (0 = per-sample table)
    b.add(_u32(sampleSizes.length));
    for (final s in sampleSizes) {
      b.add(_u32(s));
    }
    return _fullBox('stsz', b);
  }

  Uint8List _stco(List<int> offsets) {
    final b = BytesBuilder();
    b.addByte(0); // version
    b.add(_u24(0)); // flags
    b.add(_u32(offsets.length));
    for (final o in offsets) {
      b.add(_u32(o));
    }
    return _fullBox('stco', b);
  }

  // ---------------------------------------------------------------------
  // Box helpers
  // ---------------------------------------------------------------------

  static Uint8List _box(String type, BytesBuilder payload) {
    final body = payload.toBytes();
    final b = BytesBuilder();
    b.add(_u32(body.length + 8));
    b.add(_fourcc(type));
    b.add(body);
    return b.toBytes();
  }

  static Uint8List _boxData(String type, Uint8List payload) {
    final b = BytesBuilder();
    b.add(_u32(payload.length + 8));
    b.add(_fourcc(type));
    b.add(payload);
    return b.toBytes();
  }

  static Uint8List _fullBox(String type, BytesBuilder payload) =>
      _box(type, payload); // version/flags are inside the payload

  static Uint8List _u32(int v) => Uint8List.fromList([
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);

  static Uint8List _u24(int v) => Uint8List.fromList([
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);

  static Uint8List _u16(int v) =>
      Uint8List.fromList([(v >> 8) & 0xff, v & 0xff]);

  static Uint8List _fourcc(String s) {
    assert(s.length == 4);
    return Uint8List.fromList(s.codeUnits);
  }

  static Uint8List _ascii(String s) =>
      Uint8List.fromList(s.codeUnits);
}
