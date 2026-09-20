# Bundled brush presets (assets/brushes/)

This folder ships real brush presets with the app so the preset browser
offers usable brushes out of the box (no Krita install required).

## Real Krita stock presets (unmodified)

Downloaded from `github.com/KDE/krita` (mirror of invent.kde.org),
branch master, via `scripts/fetch_stock_presets.py` (2026-09-20).
The GitHub mirror carries the repo under a mixed layout: `plugins/*` at
the root, `data/*` under `krita/`. License: **GPL-2.0-or-later** (same
as this project). All files are legacy PNG preset containers: a 200x200
PNG thumbnail whose preset XML lives in a compressed zTXt chunk keyed
"preset" — the PNG doubles as the preset thumbnail in the browser.

| Asset file                    | Source path in KDE/krita                                  |
|-------------------------------|-----------------------------------------------------------|
| krita_paintbrush.kpp          | plugins/paintops/defaultpresets/paintbrush.kpp            |
| krita_eraser.kpp              | plugins/paintops/defaultpresets/eraser.kpp                |
| krita_roundmarker.kpp         | plugins/paintops/defaultpresets/roundmarker.kpp           |
| krita_spraybrush.kpp          | plugins/paintops/defaultpresets/spraybrush.kpp            |
| krita_smudge.kpp              | plugins/paintops/defaultpresets/smudge.kpp                |
| krita_colorsmudge.kpp         | plugins/paintops/defaultpresets/colorsmudge.kpp           |
| krita_sketchbrush.kpp         | plugins/paintops/defaultpresets/sketchbrush.kpp           |
| krita_curvebrush.kpp          | plugins/paintops/defaultpresets/curvebrush.kpp            |
| krita_particlebrush.kpp       | plugins/paintops/defaultpresets/particlebrush.kpp         |
| krita_deformbrush.kpp         | plugins/paintops/defaultpresets/deformbrush.kpp           |
| krita_hairybrush.kpp          | plugins/paintops/defaultpresets/hairybrush.kpp            |
| krita_waterc_round_grain.kpp  | krita/data/paintoppresets/j)_WaterC_Basic_Round-Grain.kpp |
| krita_waterc_round_fringe.kpp | krita/data/paintoppresets/j)_WaterC_Basic_Round-Fringe_02.kpp |
| krita_waterc_spread.kpp       | krita/data/paintoppresets/j)_WaterC_Spread.kpp            |
| stock_basic_5_size.kpp        | krita/data/paintoppresets/b)_Basic-5_Size_default.kpp     |
| stock_eraser_circle.kpp       | krita/data/paintoppresets/a)_Eraser_Circle.kpp            |

(`stock_basic_5_size.kpp` / `stock_eraser_circle.kpp` are the same
unmodified files as `test/fixtures/stock_*.kpp` — kept there as CI
fixtures for the native + Dart FFI preset gates.)

## Synthetic presets

`basic_soft_round.kpp`, `ink_fineliner.kpp`, `airbrush_soft.kpp`,
`test_soft.kpp` are tiny hand-written XML presets created for this app
(used by tests and as minimal fallbacks).
