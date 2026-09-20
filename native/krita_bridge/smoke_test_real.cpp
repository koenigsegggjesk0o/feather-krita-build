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
#include <vector>

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

// smoke_main — the full gate set. Runs standalone via main() (linux /
// windows engine CI jobs) and ON-DEVICE via the JNI wrapper
// (smoke_jni.cpp + FkrSmoke.java: app_process boots an ART VM so the
// Qt/KF5 android statics see a JavaVM; loop-43). C linkage is REQUIRED:
// smoke_jni.cpp declares and resolves it as an unmangled C symbol —
// run 35520311991 ("cannot locate symbol smoke_main") was the latent
// mismatch that surfaced once the JNI_ERR load-order bug was fixed.
extern "C" int smoke_main(int argc, char** argv) {
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

        // Paintop identity gate (paintop identity campaign): the declared
        // root family must come through the ABI. Both smoke fixtures are
        // real Krita stock files declaring <Preset paintopid="paintbrush">.
        const std::string pid = krita_brush_get_paintop_id(p);
        std::printf("  paintop_id=%s\n", pid.c_str());
        CHECK(!pid.empty(), "paintop id populated from preset root");

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
                CHECK(pid == "paintbrush", "basic-5 paintop id == paintbrush");
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
                CHECK(pid == "paintbrush",
                      "eraser-circle paintop id == paintbrush (CompositeOp marks the eraser, not the family)");
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

    // ------------------------------------------------------------------
    // Flow + hardness ABI gates (flow/hardness campaign).
    //
    // set_flow: per-dab alpha scale. flow=0.5 must roughly halve the dab
    // center alpha vs flow=1.0 at the same pressure/size/hardness.
    // set_hardness: rebuilds the mask generator. hardness=1.0 = hard disk
    // (flat top, sharp edge); hardness=0.0 = gaussian falloff (edge < center).
    // get_flow / get_hardness round-trip their setters.
    // ------------------------------------------------------------------
    {
        // Neutralize the main context for the flow/hardness comparison.
        krita_brush_set_size(b, 64.0);
        krita_brush_set_color(b, 0xFF000000u);
        krita_brush_set_hardness(b, 0.85);
        krita_brush_set_flow(b, 1.0);

        BrushInput fin;
        std::memset(&fin, 0, sizeof(fin));
        fin.pressure = 1.0;

        // --- Flow: full vs half ---
        BrushDab fd1;
        std::memset(&fd1, 0, sizeof(fd1));
        CHECK(krita_brush_generate_dab(b, &fin, &fd1), "flow=1.0 dab generated");
        int alphaFull = 0;
        if (fd1.pixels) {
            const uint8_t* c = fd1.pixels + (fd1.height / 2) * fd1.stride + (fd1.width / 2) * 4;
            alphaFull = c[3];
            krita_brush_release_dab(b, &fd1);
        }

        krita_brush_set_flow(b, 0.5);
        CHECK(std::fabs(krita_brush_get_flow(b) - 0.5) < 1e-9,
              "get_flow round-trips set_flow(0.5)");
        BrushDab fd2;
        std::memset(&fd2, 0, sizeof(fd2));
        CHECK(krita_brush_generate_dab(b, &fin, &fd2), "flow=0.5 dab generated");
        if (fd2.pixels) {
            const uint8_t* c = fd2.pixels + (fd2.height / 2) * fd2.stride + (fd2.width / 2) * 4;
            const int alphaHalf = c[3];
            std::printf("  flow alpha: full=%d half=%d\n", alphaFull, alphaHalf);
            CHECK(alphaHalf < alphaFull, "flow=0.5 reduces dab alpha vs flow=1.0");
            CHECK(alphaHalf <= int(alphaFull * 0.60) && alphaHalf >= int(alphaFull * 0.40),
                  "flow=0.5 roughly halves dab alpha (within 40-60%%)");
            krita_brush_release_dab(b, &fd2);
        }

        // --- Hardness: set_hardness rebuilds the mask generator ---
        // Contract under test: get_hardness round-trips the setter, and
        // switching hardness 1.0 <-> 0.0 rebuilds the real Krita mask
        // generator so the dab changes MATERIALLY (alpha bytes differ over
        // the dab) while the center stays opaque in both regimes (disk
        // core / gaussian peak). Directional falloff-shape asserts are NOT
        // portable across Krita's internal mask-generator semantics
        // (spikes=2 lens geometry narrows the diagonal; the fade-zone
        // interpretation is Krita's own) — the fade->falloff path itself
        // is already covered by the default-hardness soft-dab gates
        // above (edge < center).
        krita_brush_set_flow(b, 1.0); // neutralize flow for hardness compare

        krita_brush_set_hardness(b, 1.0);
        CHECK(std::fabs(krita_brush_get_hardness(b) - 1.0) < 1e-9,
              "get_hardness round-trips set_hardness(1.0)");
        BrushDab hd;
        std::memset(&hd, 0, sizeof(hd));
        CHECK(krita_brush_generate_dab(b, &fin, &hd), "hard-edge dab generated");
        int hardCenter = 0;
        std::vector<uint8_t> hardAlpha;
        int hw = 0, hh = 0, hstride = 0;
        if (hd.pixels) {
            hw = hd.width; hh = hd.height; hstride = hd.stride;
            hardCenter = hd.pixels[(hh / 2) * hstride + (hw / 2) * 4 + 3];
            hardAlpha.resize(size_t(hw) * hh);
            for (int y = 0; y < hh; ++y) {
                for (int x = 0; x < hw; ++x) {
                    hardAlpha[size_t(y) * hw + x] =
                        hd.pixels[size_t(y) * hstride + size_t(x) * 4 + 3];
                }
            }
            std::printf("  hard: center=%d w=%d\n", hardCenter, hw);
            krita_brush_release_dab(b, &hd);
        }

        krita_brush_set_hardness(b, 0.0);
        CHECK(std::fabs(krita_brush_get_hardness(b)) < 1e-9,
              "get_hardness round-trips set_hardness(0.0)");
        BrushDab sd;
        std::memset(&sd, 0, sizeof(sd));
        CHECK(krita_brush_generate_dab(b, &fin, &sd), "soft-edge dab generated");
        if (sd.pixels) {
            const int sw = sd.width, sh = sd.height, sstride = sd.stride;
            const int softCenter = sd.pixels[(sh / 2) * sstride + (sw / 2) * 4 + 3];
            std::printf("  soft: center=%d w=%d\n", softCenter, sw);
            CHECK(softCenter >= 250, "soft center still strong (gaussian peak)");
            CHECK(hardCenter >= 250, "hard center opaque (disk core)");
            if (!hardAlpha.empty() && hw == sw && hh == sh) {
                int diff = 0;
                for (int y = 0; y < sh; ++y) {
                    for (int x = 0; x < sw; ++x) {
                        const uint8_t sa = sd.pixels[size_t(y) * sstride + size_t(x) * 4 + 3];
                        if (sa != hardAlpha[size_t(y) * sw + x]) ++diff;
                    }
                }
                const double frac = double(diff) / double(sw * sh);
                std::printf("  hardness material diff: %d/%d px (%.1f%%)\n",
                            diff, sw * sh, frac * 100.0);
                CHECK(frac >= 0.01,
                      "set_hardness materially rebuilds the mask (hard != soft)");
            } else {
                CHECK(false, "hard/soft dabs comparable (same geometry)");
            }
            krita_brush_release_dab(b, &sd);
        }
    }

    krita_brush_destroy(b);

    // ------------------------------------------------------------------
    // Preset scan gate (preset-families campaign). The directory that
    // holds the argv fixtures is scanned through the engine's own
    // container parser (the same extraction load_preset uses); the two
    // real stock fixtures must appear with their declared paintop family
    // ("paintbrush" for both) and a scanned path that round-trips through
    // the full load_preset path. Skipped when the smoke runs without
    // fixture argv (android engine job builds but does not run the exe).
    // ------------------------------------------------------------------
    if (argc >= 2) {
        std::string fixdir(argv[1]);
        const std::size_t slash = fixdir.find_last_of("/\\");
        if (slash != std::string::npos) fixdir.resize(slash);
        KritaBrushContext* s = krita_brush_init();
        CHECK(s != nullptr, "scan context init");
        if (s) {
            const int32_t n = krita_brush_preset_scan(s, fixdir.c_str());
            std::printf("preset scan %s -> %d entries\n", fixdir.c_str(), int(n));
            if (n < 0) {
                std::printf("  last_error: %s\n", krita_brush_last_error(s));
            }
            CHECK(n >= argc - 1, "scan finds at least the argv fixtures");
            CHECK(krita_brush_preset_count(s) == n, "count matches scan size");
            int32_t basicIdx = -1;
            int32_t eraserIdx = -1;
            for (int32_t i = 0; i < n; ++i) {
                const std::string p = krita_brush_preset_path(s, i);
                if (p.find("stock_basic_5_size") != std::string::npos) basicIdx = i;
                if (p.find("stock_eraser_circle") != std::string::npos) eraserIdx = i;
            }
            CHECK(basicIdx >= 0, "scan sees stock_basic_5_size");
            CHECK(eraserIdx >= 0, "scan sees stock_eraser_circle");
            if (basicIdx >= 0 && eraserIdx >= 0) {
                const std::string bf = krita_brush_preset_family(s, basicIdx);
                const std::string ef = krita_brush_preset_family(s, eraserIdx);
                std::printf("  families: basic=%s eraser=%s\n", bf.c_str(), ef.c_str());
                CHECK(bf == "paintbrush", "basic-5 scanned family == paintbrush");
                CHECK(ef == "paintbrush", "eraser-circle scanned family == paintbrush");
                CHECK(!std::string(krita_brush_preset_name(s, basicIdx)).empty(),
                      "scanned display name populated");
                // Round-trip: a scanned path must load through the FULL
                // preset path (scan and loader share the parse; the load
                // additionally builds the real engine tip/params).
                KritaBrushContext* r = krita_brush_init();
                CHECK(r != nullptr, "scan round-trip context init");
                if (r) {
                    const int lrc = krita_brush_load_preset(
                        r, krita_brush_preset_path(s, basicIdx));
                    CHECK(lrc == 0, "scanned path loads through load_preset");
                    if (lrc == 0) {
                        CHECK(std::string(krita_brush_get_paintop_id(r)) == "paintbrush",
                              "round-trip paintop id matches scanned family");
                    }
                    krita_brush_destroy(r);
                }
            }
            krita_brush_destroy(s);
        }
    }

    if (g_failures == 0) {
        std::printf("SMOKE OK — real Krita bridge end-to-end\n");
        return 0;
    }
    std::printf("SMOKE FAILED — %d failure(s)\n", g_failures);
    return 1;
}

// Standalone entry point (linux / windows engine CI jobs). The on-device
// run goes through smoke_jni.cpp's JNI wrapper instead.
int main(int argc, char** argv) {
    return smoke_main(argc, argv);
}
