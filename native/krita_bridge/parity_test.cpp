// Parity test: compare dab pixel output of the Qt bridge .so vs the
// portable bridge .so for several pressures. Aborts on big mismatches.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>

struct BrushInput {
    double x, y, pressure, tilt_x, tilt_y, time;
    float velocity_x, velocity_y;
    int32_t flags, _padding;
};
struct BrushDab {
    int32_t width, height, stride, reserved;
    uint8_t* pixels;
};

struct Api {
    void* (*init)(void);
    void (*destroy)(void*);
    void (*setSize)(void*, double);
    void (*setOpacity)(void*, double);
    void (*setSpacing)(void*, double);
    void (*setSmudge)(void*, double);
    void (*releaseDab)(void*, void*);
    bool (*generateDab)(void*, const void*, void*);
    const char* (*lastError)(void*);
};

static bool loadApi(const char* path, void** lib, Api* api) {
    void* h = dlopen(path, RTLD_LAZY);
    if (!h) { printf("dlopen %s: %s\n", path, dlerror()); return false; }
    *lib = h;
    api->init = (void* (*)(void))dlsym(h, "krita_brush_init");
    api->destroy = (void (*)(void*))dlsym(h, "krita_brush_destroy");
    api->setSize = (void (*)(void*, double))dlsym(h, "krita_brush_set_size");
    api->setOpacity = (void (*)(void*, double))dlsym(h, "krita_brush_set_opacity");
    api->setSpacing = (void (*)(void*, double))dlsym(h, "krita_brush_set_spacing");
    api->setSmudge = (void (*)(void*, double))dlsym(h, "krita_brush_set_smudge");
    api->releaseDab = (void (*)(void*, void*))dlsym(h, "krita_brush_release_dab");
    api->generateDab = (bool (*)(void*, const void*, void*))dlsym(h, "krita_brush_generate_dab");
    api->lastError = (const char* (*)(void*))dlsym(h, "krita_brush_last_error");
    return api->init && api->generateDab && api->releaseDab;
}

int main(int argc, char** argv) {
    if (argc < 3) { printf("usage: parity <qt.so> <portable.so>\n"); return 2; }
    void *lq, *lp;
    Api q, p;
    if (!loadApi(argv[1], &lq, &q) || !loadApi(argv[2], &lp, &p)) return 2;

    const double pressures[] = { 1.0, 0.75, 0.4, 0.15 };
    int totalDiffs = 0;
    for (double pressure : pressures) {
        void* cq = q.init();
        void* cp = p.init();
        q.setSize(cq, 64.0); q.setOpacity(cq, 1.0); q.setSpacing(cq, 0.1); q.setSmudge(cq, 0.0);
        p.setSize(cp, 64.0); p.setOpacity(cp, 1.0); p.setSpacing(cp, 0.1); p.setSmudge(cp, 0.0);

        BrushInput in{}; in.pressure = pressure;
        BrushDab dq{}, dp{};
        const bool oq = q.generateDab(cq, &in, &dq);
        const bool op = p.generateDab(cp, &in, &dp);
        if (!oq || !op) {
            printf("pressure %.2f: qt ok=%d portable ok=%d  MISMATCH existence\n", pressure, (int)oq, (int)op);
            ++totalDiffs;
        } else if (dq.width != dp.width) {
            printf("pressure %.2f: size %d vs %d  MISMATCH\n", pressure, dq.width, dp.width);
            ++totalDiffs;
        } else {
            // Compare alpha channels; allow small rounding differences.
            int diffs = 0, maxDelta = 0;
            for (int i = 3; i < dq.stride * dq.height; i += 4) {
                const int a1 = dq.pixels[i];
                const int a2 = dp.pixels[i];
                const int d = std::abs(a1 - a2);
                if (d > 8) ++diffs;
                if (d > maxDelta) maxDelta = d;
            }
            printf("pressure %.2f: %dx%d alpha diffs>8: %d (max delta %d)%s\n",
                   pressure, dq.width, dq.height, diffs, maxDelta,
                   diffs > 0 ? "  CHECK" : "  ok");
            totalDiffs += diffs > 0 ? 1 : 0;
        }
        if (oq) q.releaseDab(cq, &dq);
        if (op) p.releaseDab(cp, &dp);
        q.destroy(cq);
        p.destroy(cp);
    }
    printf(totalDiffs == 0 ? "PARITY: PASS\n" : "PARITY: %d mismatches\n", totalDiffs);
    return totalDiffs == 0 ? 0 : 1;
}
