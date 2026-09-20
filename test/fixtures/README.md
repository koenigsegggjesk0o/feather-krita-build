Real Krita brush preset fixtures (roadmap (f) — paintop-settings-level
preset loading).

Provenance:
  Both files are UNMODIFIED stock presets from the Krita project
  (github.com/KDE/krita, branch master, krita/data/paintoppresets/):
    stock_basic_5_size.kpp   <- "b)_Basic-5_Size_default.kpp" (22572 bytes)
    stock_eraser_circle.kpp  <- "a)_Eraser_Circle.kpp"       (24264 bytes)
  Downloaded 2026-09-20. License: GPL-2.0-or-later (same as this project).

Format (why these are valuable test fixtures):
  Krita's stock presets are NOT zip archives — they are legacy PNG preset
  containers: a 200x200 PNG thumbnail whose preset XML lives in a
  compressed zTXt chunk keyed "preset" (format version "2.2" in the tEXt
  chunk). The XML root is <Preset name="..." paintopid="..."> with every
  paintop setting as a flat <param name="..." type="string"> entry
  (CDATA values), including:
    Krita/opacity        master opacity, 0-100 scale
    Krita/erase          eraser checkbox
    EraserMode           eraser checkbox (paintop settings)
    CompositeOp          "erase" marks eraser presets (stock eraser uses
                         this form), "normal" otherwise
    brush_definition     the <Brush> tip definition (CDATA) with the
                         <MaskGenerator diameter hfade vfade .../> attrs
    SizeValue/SoftnessValue/...  sensor bases (NOT user-facing values)

Expected paintop-settings values (asserted by the smokes):
  stock_basic_5_size : size=40 (MaskGenerator diameter), opacity=1.0
                       (Krita/opacity=100), spacing=0.1 (Brush spacing),
                       hardness=0.0 (hfade=1), eraser=false
  stock_eraser_circle: size=50, opacity=1.0, spacing=0.1, hardness=0.13
                       (hfade=0.87), eraser=true via CompositeOp=erase

Consumers:
  - native/krita_bridge/smoke_test_real.cpp (CI engine jobs, argv)
  - tool/ffi_real_smoke.dart (CI app jobs, test/fixtures default)
  - test/preset_library_test.dart (Dart model PNG-container parsing)
