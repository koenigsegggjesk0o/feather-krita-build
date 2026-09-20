// probe_paintop_id.dart — 5-loop-41 local functional probe:
// the tracked portable bridge only parses ZIP/raw-XML containers (PNG
// zTXt containers are the real engine's path), so this probe feeds raw
// XML presets and asserts the declared family comes through the ABI.
import 'dart:io';

import 'package:feather_krita/ffi/krita_bindings.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('paintop_probe');
  var fail = false;
  try {
    // Case 1: stock-style root <Preset paintopid="...">
    final a = File('${dir.path}${Platform.pathSeparator}a.kpp');
    a.writeAsStringSync('<?xml version="1.0"?>\n'
        '<Preset name="probe_a" paintopid="spraybrush">\n'
        '  <param name="brush_spacing" value="0.1"/>\n'
        '</Preset>\n');
    // Case 2: legacy/synthetic root <Paintop id="...">
    final b = File('${dir.path}${Platform.pathSeparator}b.kpp');
    b.writeAsStringSync('<?xml version="1.0"?>\n'
        '<Paintop id="paintbrush" name="probe_b">\n'
        '  <param id="brush_spacing" value="0.2"/>\n'
        '</Paintop>\n');
    // Case 3: no declared family -> empty.
    final c = File('${dir.path}${Platform.pathSeparator}c.kpp');
    c.writeAsStringSync('<?xml version="1.0"?>\n'
        '<Paintop name="probe_c">\n'
        '  <param id="brush_spacing" value="0.3"/>\n'
        '</Paintop>\n');

    final cases = {'a.kpp': 'spraybrush', 'b.kpp': 'paintbrush', 'c.kpp': ''};
    for (final e in cases.entries) {
      final eng = KritaBrushEngine();
      final rc = eng.loadPreset('${dir.path}${Platform.pathSeparator}${e.key}');
      final pid = eng.currentPaintopId;
      stdout.writeln('${e.key}: rc=$rc paintop="$pid" (expect "${e.value}")');
      if (!rc || pid != e.value) fail = true;
      eng.dispose();
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
  exit(fail ? 1 : 0);
}
