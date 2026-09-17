// Local smoke test for the krita_bridge shared library.
// Uses dlopen/dlsym (Linux/macOS) or LoadLibrary/GetProcAddress (Windows) —
// the same mechanism Flutter's DynamicLibrary.open uses at runtime.
#include <cstdio>
#include <cstdint>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
using LibHandle = HMODULE;
static LibHandle openLib(const char* p) { return LoadLibraryA(p); }
static void* sym(LibHandle h, const char* n) { return (void*)GetProcAddress(h, n); }
static const char* libErr() { return "LoadLibrary failed"; }
#else
#include <dlfcn.h>
using LibHandle = void*;
static LibHandle openLib(const char* p) { return dlopen(p, RTLD_LAZY); }
static void* sym(LibHandle h, const char* n) { return dlsym(h, n); }
static const char* libErr() { return dlerror(); }
#endif

int main(int argc, char** argv) {
    const char* libPath = argc > 1 ? argv[1] : "/tmp/libkrita_bridge_test.so";
    LibHandle lib = openLib(libPath);
    if (!lib) {
        printf("FAIL: open: %s\n", libErr());
        return 1;
    }
    printf("open library: OK\n");

    using VersionFn = const char* (*)(void);
    using InitFn = void* (*)(void);
    using DestroyFn = void (*)(void*);
    using SetSizeFn = void (*)(void*, double);
    using SetOpacityFn = void (*)(void*, double);
    using SetSpacingFn = void (*)(void*, double);
    using SetSmudgeFn = void (*)(void*, double);
    using LastErrorFn = const char* (*)(void*);
    using CleanupFn = void (*)(void*);
    using ReleaseDabFn = void (*)(void*, void*);
    using GenerateDabFn = bool (*)(void*, const void*, void*);
    using LoadPresetFn = int32_t (*)(void*, const char*);
    using PresetCountFn = int32_t (*)(void*);

    auto version = (VersionFn)sym(lib, "krita_brush_version");
    auto init = (InitFn)sym(lib, "krita_brush_init");
    auto destroy = (DestroyFn)sym(lib, "krita_brush_destroy");
    auto setSize = (SetSizeFn)sym(lib, "krita_brush_set_size");
    auto setOpacity = (SetOpacityFn)sym(lib, "krita_brush_set_opacity");
    auto setSpacing = (SetSpacingFn)sym(lib, "krita_brush_set_spacing");
    auto setSmudge = (SetSmudgeFn)sym(lib, "krita_brush_set_smudge");
    auto lastError = (LastErrorFn)sym(lib, "krita_brush_last_error");
    auto cleanup = (CleanupFn)sym(lib, "krita_brush_cleanup");
    auto releaseDab = (ReleaseDabFn)sym(lib, "krita_brush_release_dab");
    auto generateDab = (GenerateDabFn)sym(lib, "krita_brush_generate_dab");
    auto loadPreset = (LoadPresetFn)sym(lib, "krita_brush_load_preset");
    auto presetCount = (PresetCountFn)sym(lib, "krita_brush_preset_count");

    if (!version || !init || !destroy || !generateDab || !releaseDab) {
        printf("FAIL: missing symbols: %s\n", libErr());
        return 1;
    }
    printf("version: %s\n", version());

    void* ctx = init();
    if (!ctx) { printf("FAIL: init returned null\n"); return 1; }
    printf("init: OK\n");

    setSize(ctx, 64.0);
    setOpacity(ctx, 1.0);
    setSpacing(ctx, 0.1);
    setSmudge(ctx, 0.0);
    printf("params: OK\n");

    // BrushInput layout per krita_bridge.h:
    // 6 doubles (x y pressure tilt_x tilt_y time) + 2 floats (velocity_x velocity_y)
    // + 2 int32 (flags _padding) = 64 bytes
    struct BrushInput {
        double x, y, pressure, tilt_x, tilt_y, time;
        float velocity_x, velocity_y;
        int32_t flags, _padding;
    };
    static_assert(sizeof(BrushInput) == 64, "BrushInput must be 64 bytes");

    // BrushDab layout: 4 int32 (width height stride reserved) + pointer
    struct BrushDab {
        int32_t width, height, stride, reserved;
        uint8_t* pixels;
    };

    BrushInput input{};
    input.x = 100.0;
    input.y = 100.0;
    input.pressure = 1.0;

    BrushDab dab{};
    bool ok = generateDab(ctx, &input, &dab);
    if (!ok || !dab.pixels) {
        printf("FAIL: generate_dab ok=%d err=%s\n", (int)ok, lastError(ctx));
        destroy(ctx);
        return 1;
    }
    printf("generate_dab: ok w=%d h=%d stride=%d\n", dab.width, dab.height, dab.stride);
    if (dab.width != 64 || dab.height != 64) {
        printf("FAIL: unexpected dab size\n");
        releaseDab(ctx, &dab);
        destroy(ctx);
        return 1;
    }
    const uint8_t* center = dab.pixels + ((size_t)dab.height / 2) * dab.stride + ((size_t)dab.width / 2) * 4;
    const uint8_t* corner = dab.pixels;
    printf("center RGBA: %d,%d,%d,%d\n", center[0], center[1], center[2], center[3]);
    printf("corner RGBA: %d,%d,%d,%d\n", corner[0], corner[1], corner[2], corner[3]);
    const bool pixelsOk = center[3] > 200 && corner[3] < 60;
    releaseDab(ctx, &dab);
    printf("release_dab: OK\n");
    bool presetOk = true;

    // Low pressure
    input.pressure = 0.25;
    ok = generateDab(ctx, &input, &dab);
    printf("low-pressure dab: ok=%d w=%d\n", (int)ok, dab.width);
    if (ok) releaseDab(ctx, &dab);

    // Preset API robustness
    int32_t rc = loadPreset(ctx, "/nonexistent/file.kpp");
    printf("load_preset(badpath): rc=%d (expect nonzero)\n", rc);
    printf("last_error: %s\n", lastError(ctx));
    printf("preset_count: %d\n", presetCount(ctx));

    // ---- Preset loading from real-shaped .kpp files (ZIP + XML) ----
    // After loading, size should be 77, opacity 0.42, spacing 0.07.
    // Verify by reading back the param getters.
    using GetSizeFn = double (*)(void*);
    using GetOpacityFn = double (*)(void*);
    using GetSpacingFn = double (*)(void*);
    auto getSize = (GetSizeFn)sym(lib, "krita_brush_get_size");
    auto getOpacity = (GetOpacityFn)sym(lib, "krita_brush_get_opacity");
    auto getSpacing = (GetSpacingFn)sym(lib, "krita_brush_get_spacing");
    if (getSize && getOpacity && getSpacing) {
        if (argc > 2) {
            // Explicitly reset to known defaults first: size 16, opacity 1.
            setSize(ctx, 16.0);
            setOpacity(ctx, 1.0);
            setSpacing(ctx, 0.15);
            int32_t prc = loadPreset(ctx, argv[2]);
            printf("load_preset(%s): rc=%d\n", argv[2], prc);
            if (prc != 0) {
                printf("last_error: %s\n", lastError(ctx));
                presetOk = false;
            } else {
                const double gs = getSize(ctx);
                const double go = getOpacity(ctx);
                const double gsp = getSpacing(ctx);
                printf("after preset: size=%.2f opacity=%.2f spacing=%.3f\n", gs, go, gsp);
                const bool good = gs == 77.0 && go == 0.42 && gsp == 0.07;
                if (!good) presetOk = false;
            }
        }
    } else {
        printf("note: param getters not exported; skipping preset value check\n");
    }

    cleanup(ctx);
    destroy(ctx);
    printf("destroy: OK\n");
    printf((pixelsOk && presetOk) ? "SMOKE TEST: PASS\n" : "SMOKE TEST: FAIL\n");
    return (pixelsOk && presetOk) ? 0 : 1;
}
