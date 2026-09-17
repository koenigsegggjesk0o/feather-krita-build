// Probe: does the native bridge return a usable (non-transparent) eraser dab?
import 'package:feather_krita/ffi/krita_bindings.dart';

void dumpDab(String label, BrushDab dab) {
  final cx = dab.width ~/ 2;
  final cy = dab.height ~/ 2;
  final i = cy * dab.stride + cx * 4;
  final corner = dab.pixels[3]; // (0,0) alpha
  print('$label: ${dab.width}x${dab.height} '
      'center RGBA=(${dab.pixels[i]},${dab.pixels[i + 1]},'
      '${dab.pixels[i + 2]},${dab.pixels[i + 3]}) cornerA=$corner '
      'nonZeroPixels=${dab.pixels.where((p) => p != 0).length}');
}

void main() {
  final e = KritaBrushEngine();
  e
    ..size = 64
    ..color = const BrushColor(255, 0, 0)
    ..opacity = 1.0;

  dumpDab('normal  ', e.generateDab(BrushInput(x: 0, y: 0, pressure: 1.0)));
  dumpDab('eraser  ', e.generateDab(BrushInput(
      x: 0, y: 0, pressure: 1.0,
      flags: BrushInputFlags(eraser: true))));
  dumpDab('eraser@.5', e.generateDab(BrushInput(
      x: 0, y: 0, pressure: 0.5,
      flags: BrushInputFlags(eraser: true))));
  e.dispose();
}
