// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// smoke_test_real.cpp — CI smoke test for the REAL Krita bridge.
//
// Links against libkrita_bridge_real.so + the real libkrita* libraries and
// verifies end-to-end dab generation through unmodified Krita v6.0.4 code:
//   - engine init (KoColorSpaceRegistry + KisAutoBrush construction)
//   - hard / soft dab generation (KisBrush::mask path)
//   - exact color passthrough (straight-alpha RGBA output)
//   - pressure->alpha and pressure->size ABI scaling
//   - eraser mode (black-alpha mask output)
//   - paintop-settings-level preset loading (roadmap (f)): real Krita
//     stock .kpp fixtures (PNG preset containers) passed as argv; checks
//     that the settings-level params (Krita/opacity, brush_definition,
//     CompositeOp, MaskGenerator diameter/hfade, spacing) land on the ABI
//     getters and that an eraser preset paints a black mask WITHOUT the
//     eraser input flag.

#include "krita_bridge.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static int g_failures = 0;

#define CHECK(cond, msg)                                                  \
    do {                                                                  \
        if (cond) {                                                       \
            std::printf("  ok: %s\n", msg);                               \
        } else {                                                          \
            std::printf("  FAIL: %s (line %d)\n", msg, __LINE__);         \
            ++g_failures;                                                 \
        }                                                                 \
    } while (0)

int main(int argc, char** argv) {
    std::printf("version: %s\n", krita_brush_version());
    KritaBrushContext* b = krita_brush_init();
    CHECK(b != nullptr, "init returns handle");

    const double size0 = krita_brush_get_size(b);
    CHECK(size0 > 0.0, "default size positive");

    // --- Hard round brush, full pressure: opaque exact-color center.
    krita_brush_set_size(b, 32.0);
    krita_brush_set_color(b, 0xFF2040A0u); // A=FF R=0x20 G=0x40 B=0xA0
    BrushInput in;
    std::memset(&in, 0, sizeof(in));
    in.pressure = 1.0;
    BrushDab dab;
    std::memset(&dab, 0, sizeof(dab));
    const bool ok = krita_brush_generate_dab(b, &in, &dab);
    CHECK(ok, "hard dab generated");
    if (ok) {
        CHECK(dab.width >= 28 && dab.width <= 34, "hard dab diameter ~= size");
        CHECK(dab.stride == dab.width * 4, "stride == width*4");
        const uint8_t* px = dab.pixels + (dab.height / 2) * dab.stride + (dab.width / 2) * 4;
        std::printf("  center RGBA: %u %u %u %u\n", px[0], px[1], px[2], px[3]);
        CHECK(px[0] == 0x20 && px[1] == 0x40 && px[2] == 0xA0, "center color exact (straight RGBA)");
        CHECK(px[3] >= 250, "center opaque at full pressure");
        // Corner of the bounding box must be transparent for a round tip.
        const uint8_t* corner = dab.pixels;
        CHECK(corner[3] == 0, "bounding-box corner transparent");
        krita_brush_release_dab(b, &dab);
    }

    // --- Soft brush (default hardness 0.85 -> gaussian fade 0.15):
    // falloff present, edge weaker than center.
    krita_brush_set_size(b, 64.0);
    BrushInput in2;
    std::memset(&in2, 0, sizeof(in2));
    in2.pressure = 1.0;
    BrushDab soft;
    std::memset(&soft, 0, sizeof(soft));
    int softWidth = 0;
    if (krita_brush_generate_dab(b, &in2, &soft)) {
        softWidth = soft.width; // captured BEFORE release (release zeroes it)
        std::printf("  soft dab width=%d\n", softWidth);
        CHECK(softWidth >= 60, "soft dab sized from size=64");
        const uint8_t* c = soft.pixels + (soft.height / 2) * soft.stride + (soft.width / 2) * 4;
        const uint8_t* edge = soft.pixels + (soft.height / 2) * soft.stride + 4; // near left edge
        std::printf("  soft center alpha=%u edge alpha=%u\n", c[3], edge[3]);
        CHECK(c[3] >= 200, "soft center still strong");
        CHECK(edge[3] < c[3], "soft edge weaker than center (falloff)");
        krita_brush_release_dab(b, &soft);
    } else {
        CHECK(false, "soft dab generated");
    }

    // --- Pressure->alpha scaling: half pressure gives weaker center.
    BrushInput in3;
    std::memset(&in3, 0, sizeof(in3));
    in3.pressure = 0.5;
    BrushDab half;
    std::memset(&half, 0, sizeof(half));
    if (krita_brush_generate_dab(b, &in3, &half)) {
        const uint8_t* c = half.pixels + (half.height / 2) * half.stride + (half.width / 2) * 4;
        std::printf("  half-pressure center alpha=%u dab width=%d (soft was %d)\n", c[3], half.width, softWidth);
        CHECK(c[3] < 255, "half pressure scales alpha down");
        CHECK(half.width < softWidth, "half pressure shrinks dab");
        krita_brush_release_dab(b, &half);
    } else {
        CHECK(false, "half-pressure dab generated");
    }

    // --- Eraser mode: black-alpha mask output.
    BrushInput in4;
    std::memset(&in4, 0, sizeof(in4));
    in4.pressure = 1.0;
    in4.flags = kBrushInputEraser;
    BrushDab erase;
    std::memset(&erase, 0, sizeof(erase));
    if (krita_brush_generate_dab(b, &in4, &erase)) {
        const uint8_t* c = erase.pixels + (erase.height / 2) * erase.stride + (erase.width / 2) * 4;
        std::printf("  eraser center RGBA: %u %u %u %u\n", c[0], c[1], c[2], c[3]);
        CHECK(c[0] == 0 && c[1] == 0 && c[2] == 0, "eraser dab is black mask");
        CHECK(c[3] >= 250, "eraser center opaque mask");
        krita_brush_release_dab(b, &erase);
    } else {
        CHECK(false, "eraser dab generated");
    }

    // ------------------------------------------------------------------
    // Paintop-settings-level preset gates (roadmap (f)).
    //
    // Real Krita stock presets (PNG preset containers, <Preset> XML with
    // settings-level params) are passed as argv fixtures. With no argv the
    // section is skipped (the android engine job builds the smoke exe but
    // does not run it; linux+windows engine jobs and the Dart smoke wire
    // fixtures explicitly). Failures here are FATAL: the fixtures exist in
    // the app repo the CI clone already fetched.
    // ------------------------------------------------------------------
    for (int a = 1; a < argc; ++a) {
        const char* fixture = argv[a];
        const std::string fixtureName(fixture);
        std::printf("preset fixture: %s\n", fixture);
        KritaBrushContext* p = krita_brush_init();
        CHECK(p != nullptr, "preset context init");
        if (!p) continue;

        const int rc = krita_brush_load_preset(p, fixture);
        CHECK(rc == 0, "load_preset returns 0 (container + XML + settings parsed)");
        if (rc != 0) {
            std::printf("  last_error: %s\n", krita_brush_last_error(p));
            krita_brush_destroy(p);
            continue;
        }

        const std::string pname = krita_brush_get_preset_name(p);
        CHECK(!pname.empty(), "preset name populated");
        const double sz = krita_brush_get_size(p);
        const double op = krita_brush_get_opacity(p);
        const double sp = krita_brush_get_spacing(p);
        const double hd = krita_brush_get_hardness(p);
        std::printf("  size=%.4f opacity=%.4f spacing=%.4f hardness=%.4f name=%s\n",
                    sz, op, sp, hd, pname.c_str());
        CHECK(sz >= 4.0, "paintop size from tip >= 4px");
        CHECK(op > 0.0 && op <= 1.0, "opacity in (0,1]");
        CHECK(sp > 0.0, "spacing positive");
        CHECK(hd >= 0.0 && hd <= 1.0, "hardness in [0,1]");

        // Dab generation must work on the preset-loaded context.
        BrushInput pin;
        std::memset(&pin, 0, sizeof(pin));
        pin.pressure = 1.0;
        BrushDab pd;
        std::memset(&pd, 0, sizeof(pd));
        if (krita_brush_generate_dab(p, &pin, &pd)) {
            const uint8_t* c = pd.pixels + (pd.height / 2) * pd.stride + (pd.width / 2) * 4;
            std::printf("  preset dab center RGBA: %u %u %u %u (w=%d)\n",
                        c[0], c[1], c[2], c[3], pd.width);
            CHECK(pd.width >= 4, "preset dab has extent");

            // Fixture-specific paintop-settings expectations (values from
            // the stock presets' own XML — see test/fixtures/README.md).
            if (fixtureName.find("stock_basic_5_size") != std::string::npos) {
                CHECK(sz == 40.0, "basic-5 size == 40 (MaskGenerator diameter)");
                CHECK(op == 1.0, "basic-5 opacity == 1.0 (Krita/opacity = 100)");
                CHECK(std::fabs(sp - 0.1) < 1e-9, "basic-5 spacing == 0.1 (Brush spacing)");
                CHECK(hd == 0.0, "basic-5 hardness == 0 (hfade = 1)");
                CHECK(!krita_brush_get_eraser(p), "basic-5 NOT flagged eraser");
                CHECK(c[0] == 0 && c[1] == 0 && c[2] == 0,
                      "basic-5 dab sanity (default color is black)");
            } else if (fixtureName.find("stock_eraser_circle") != std::string::npos) {
                CHECK(sz == 50.0, "eraser size == 50 (MaskGenerator diameter)");
                CHECK(op == 1.0, "eraser opacity == 1.0 (Krita/opacity = 100)");
                CHECK(std::fabs(hd - 0.13) < 1e-9,
                      "eraser hardness == 0.13 (hfade = 0.87)");
                // THE eraser gate: the preset's settings-level CompositeOp
                // =erase must flag the context as eraser (the app switches
                // its stroke compositing to destination-out accordingly).
                CHECK(krita_brush_get_eraser(p),
                      "eraser preset flagged via settings (CompositeOp=erase)");
                // The dab path also honors it: black mask WITHOUT the
                // eraser input flag (mask color forcing).
                CHECK(c[0] == 0 && c[1] == 0 && c[2] == 0,
                      "eraser preset dab is black mask WITHOUT eraser flag");
            }
            krita_brush_release_dab(p, &pd);
        } else {
            CHECK(false, "preset dab generated");
        }
        krita_brush_destroy(p);
    }

    krita_brush_destroy(b);

    if (g_failures == 0) {
        std::printf("SMOKE OK — real Krita bridge end-to-end\n");
        return 0;
    }
    std::printf("SMOKE FAILED — %d failure(s)\n", g_failures);
    return 1;
}
