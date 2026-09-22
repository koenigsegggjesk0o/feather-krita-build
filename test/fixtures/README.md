Real Krita brush preset fixtures (roadmap (f) — paintop-settings-level
preset loading; stroke-session gates — Feather-3D phase F1).

Provenance:
  All four files are UNMODIFIED stock presets from the Krita project
  (github.com/KDE/krita, branch master):
    stock_basic_5_size.kpp      <- "b)_Basic-5_Size_default.kpp"  (22572 bytes)
                                   from krita/data/paintoppresets/
    stock_eraser_circle.kpp     <- "a)_Eraser_Circle.kpp"         (24264 bytes)
                                   from krita/data/paintoppresets/
    stock_spray_pointillism.kpp <- "v)_Texture_Pointillism.kpp"   (48139 bytes)
                                   from krita/data/bundles/
                                   Krita_4_Default_Resources.bundle
                                   (paintoppresets/ entry, extracted
                                   byte-identical)
    stock_smear_blender.kpp     <- "k)_Blender_Smear.kpp"         (18863 bytes)
                                   from krita/data/bundles/
                                   Krita_4_Default_Resources.bundle
                                   (paintoppresets/ entry, extracted
                                   byte-identical)
  Downloaded 2026-09-20 (first two) and 2026-09-23 (spray/smear).
  License: GPL-2.0-or-later (same as this project).

Format (why these are valuable test fixtures):
  Krita's stock presets are NOT zip archives — they are legacy PNG preset
  containers: a 200x200 PNG thumbnail whose preset XML lives in a
  compressed zTXt chunk keyed "preset" (format version "2.2" in the tEXt
  chunk; the spray preset stores it uncompressed in a tEXt chunk — both
  are valid PNG text-chunk encodings the engine's own loader reads). The
  XML root is <Preset name="..." paintopid="..."> with every
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
  stock_spray_pointillism: paintopid="spraybrush" (stroke-session gate b:
                       the SPRAY engine must dispatch through
                       krita_stroke_begin and produce pixels different
                       from the paintbrush preset through the same ABI)
  stock_smear_blender: paintopid="colorsmudge", SmudgeRateValue=0.7
                       (stroke-session gate c: the colorsmudge engine
                       must modify a pre-uploaded texture — the
                       KisPaintDevice writeBytes/readBytes round-trip)

Consumers:
  - native/krita_bridge/smoke_test_real.cpp (CI engine jobs, argv)
  - tool/ffi_real_smoke.dart (CI app jobs, test/fixtures default —
    references the two paintbrush fixtures by name; the extra files are
    inert for it)
  - test/preset_library_test.dart (Dart model PNG-container parsing)
