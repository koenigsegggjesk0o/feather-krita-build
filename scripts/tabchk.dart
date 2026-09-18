import 'package:feather_krita/io/h264_cavlc_tables.dart';
void main() {
  for (var band = 0; band < 4; band++) {
    for (var k = 0; k < 68; k++) {
      final len = kCoeffTokenLen[band][k];
      if (len == 0) continue;
      final code = kCoeffTokenBits[band][k].toRadixString(2).padLeft(len, '0');
      if (code == '0000000010') {
        print('band $band idx $k -> tc=${k >> 2} t1=${k & 3} (len=$len bits=${kCoeffTokenBits[band][k]})');
      }
    }
  }
  // also check prefix-free property per band
  for (var band = 0; band < 4; band++) {
    final codes = <String>[];
    for (var k = 0; k < 68; k++) {
      final len = kCoeffTokenLen[band][k];
      if (len == 0) continue;
      codes.add(kCoeffTokenBits[band][k].toRadixString(2).padLeft(len, '0'));
    }
    for (var i = 0; i < codes.length; i++) {
      for (var j = 0; j < codes.length; j++) {
        if (i != j && codes[j].startsWith(codes[i])) {
          print('band $band: code[$i]=${codes[i]} is prefix of code[$j]=${codes[j]}');
        }
      }
    }
  }
  print('done');
}
