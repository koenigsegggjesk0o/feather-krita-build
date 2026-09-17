// ffi_repro.dart — standalone repro for the gui_test isolate crash.
// Mimics the gui_test.dart sequence WITHOUT Flutter:
//   test1: mount (engine create; dispose at teardown)
//   test2: engine + tool switches (no paint)
//   test3: engine + drag painting (many dabs, default pressure)
//   test4: engine + drag + UNDO + REDO
// Run: cd /home/z/fkr-step1 && dart run scripts/ffi_repro.dart

import 'dart:math';

import 'package:feather_krita/ffi/krita_bindings.dart';

BrushInput inputAt(double x, double y, double pressure, double t) =>
    BrushInput(
      x: x,
      y: y,
      pressure: pressure,
      tiltX: 0,
      tiltY: 0,
      time: t,
      velocityX: 0,
      velocityY: 0,
    );

int stampCycle(KritaBrushEngine e, int n, double size, int seed) {
  // Mimic canvas spacing: step = size * spacing heuristic, dabs across a
  // sweep like the gui drag (8 move events → ~5-20 dabs).
  final rnd = Random(seed);
  var total = 0;
  for (var i = 0; i < n; i++) {
    final p = 0.5 + 0.5 * rnd.nextDouble();
    final dab = e.generateDab(inputAt(rnd.nextDouble() * 100,
        rnd.nextDouble() * 100, p, i * 0.016));
    total += dab.pixels.length;
    // Simulate TexturePainter.paintDab touching every source pixel once.
    var acc = 0;
    for (var j = 0; j < dab.pixels.length; j += 997) {
      acc += dab.pixels[j];
    }
    if (acc == -1) print('impossible');
  }
  return total;
}

void cycle(int id, {required bool paint}) {
  final e = KritaBrushEngine();
  e
    ..size = 24
    ..opacity = 1.0
    ..spacing = 0.1
    ..smudge = 0.0
    ..color = BrushColor.fromPacked(0xFF1A1A1A);
  var bytes = 0;
  if (paint) {
    bytes = stampCycle(e, 24, 24, id * 31 + 7);
  }
  e.dispose();
  print('cycle $id done (painted=$paint, dabBytes=$bytes)');
}

void main() {
  print('engine cycles starting...');
  // Tests 1-3 equivalents: create, use, destroy.
  cycle(1, paint: false);
  cycle(2, paint: false);
  cycle(3, paint: true);
  // Test 4 equivalent: paint + undo/redo-sized workloads.
  cycle(4, paint: true);
  // Extra churn beyond what the suite does, to shake out latent corruption.
  for (var i = 5; i <= 12; i++) {
    cycle(i, paint: true);
  }
  print('ALL CYCLES OK');
}
