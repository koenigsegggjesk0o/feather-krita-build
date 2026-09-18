import 'dart:typed_data';
Uint8List gray(int w, int h, int v) {
  final f = Uint8List(w * h * 4);
  for (var i = 0; i < f.length; i += 4) {
    f[i] = v; f[i + 1] = v; f[i + 2] = v; f[i + 3] = 0xFF;
  }
  return f;
}
void main() {
  final w = 16, h = 16, base = 128, amp = 60;
  final f = gray(w, h, base);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = (amp * x) ~/ w;
      final i = (y * w + x) * 4;
      final v = (base + d).clamp(0, 255);
      f[i] = v; f[i + 1] = v; f[i + 2] = v;
    }
  }
  // chroma box average at (cx=1, cy=0)
  var rSum = 0, gSum = 0, bSum = 0;
  for (var dy = 0; dy < 2; dy++) {
    for (var dx = 0; dx < 2; dx++) {
      final i = ((0 * 2 + dy) * w + (1 * 2 + dx)) * 4;
      rSum += f[i]; gSum += f[i + 1]; bSum += f[i + 2];
    }
  }
  final r = rSum >> 2, g = gSum >> 2, b = bSum >> 2;
  print('r=$r g=$g b=$b');
  final u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
  final v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
  print('u=$u v=$v');
}
