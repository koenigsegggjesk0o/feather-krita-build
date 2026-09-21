// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// krita_bridge_real.cpp — REAL Krita engine FFI bridge.
//
// This file implements the `extern "C"` API declared in krita_bridge.h by
// CALLING the unmodified Krita v6.0.4 shared libraries (libkritabrush,
// libkritaimage, libkritapigment, libkritaresources, libkritaversion).
// It is a THIN GLUE layer: every brush/mask/pixel computation runs inside
// real, unmodified Krita code:
//
//   - brush tip   : KisGaussCircleMaskGenerator / KisCircleMaskGenerator
//                   (libs/image — gaussian falloff LUT, antialiasing)
//   - dab engine  : KisAutoBrush (libs/brush) -> KisBrush::mask(...) ->
//                   KisBrush::generateMaskAndApplyMaskOrCreateDab
//                   -> brush pyramid scaling/rotation
//                   -> KisBrushMaskApplicator (SIMD-stamped masks)
//   - color       : KoColor + KoColorSpaceRegistry (libs/pigment)
//   - presets     : KisBrush::fromXML + KisResourcesInterface (real .kpp
//                   brush-definition parsing)
//
// The glue in this file only:
//   1. converts the C ABI structs (BrushInput / BrushDab) to Krita calls
//      and back,
//   2. reorders Krita's native byte layout to the ABI's R,G,B,A layout and
//      applies the ABI's documented pressure->alpha scaling (desktop Krita
//      performs the same scaling in KisPainter at composite time),
//   3. unpacks .kpp preset containers (PKZIP entry extraction, and the
//      legacy PNG preset format: PNG files carrying the preset XML in a
//      compressed zTXt chunk keyed "preset" — the format Krita itself
//      ships its stock presets in). The parsed XML is handed to Krita's
//      own KisBrush::fromXML, and the paintop-settings-level <param> map
//      (Krita/opacity, brush_definition, CompositeOp, ...) is applied to
//      the ABI getters.
//
// No painting math is re-implemented. The Krita source tree is used
// UNMODIFIED, per project directive.

#include "krita_bridge.h"

// ---------------------------------------------------------------------------
// Real Krita headers (unmodified v6.0.4 source tree).
// ---------------------------------------------------------------------------
#include <kis_auto_brush.h>          // libs/brush
#include <kis_brush.h>               // libs/brush  (KisBrush::mask, fromXML)
#include <kis_dab_shape.h>           // libs/brush
#include <kis_mask_generator.h>      // libs/image  (gauss/circle generators)
#include <kis_fixed_paint_device.h>  // libs/image
#include <kis_paint_information.h>   // libs/image/brushengine
#include <KisGlobalResourcesInterface.h> // libs/resources
#include <KoColor.h>                 // libs/pigment
#include <KoColorSpaceRegistry.h>    // libs/pigment
#include <KritaVersionWrapper.h>     // libs/version

#include <QByteArray>
#include <QColor>
#include <QDir>
#include <QDirIterator>
#include <QDomDocument>
#include <QDomElement>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#include <zlib.h>

// ---------------------------------------------------------------------------
// Android host bootstrap (loop-61). The Flutter app hosts this library via
// Dart FFI (DynamicLibrary.open -> dlopen), so NO JNI_OnLoad ever runs and
// Qt's private g_javaVm stays null — yet Krita/KF5/Qt static initializers
// in the merged engine image DO touch JNI: QJNIEnvironmentPrivate's ctor
// derefs the VM without a null check (vm->GetEnv, Qt 5.15 qjni.cpp) and a
// QStandardPaths::writableLocation path-cache static crashes the process at
// dlopen time (fault addr 0x0, run 35590595766 backtrace: ctor at
// libkrita_bridge+0x8c4a90 -> QStandardPaths(17) -> QJNIObjectPrivate ->
// QJNIEnvironmentPrivate). The loop-43 emulator harness hit the identical
// static-initializer wall (runs 35510837084/35513090509) and PROVED the fix
// set below in smoke_jni.cpp:
//   1. vminject — Qt's setter (QtAndroidPrivate::setJavaVM) is hidden in
//      the 5.15.2 android build; only the reader javaVM() is exported, as
//      a two/three-instruction thunk. Recover the runtime's JavaVM via
//      JNI_GetCreatedJavaVMs (libart) and write it straight into the
//      global behind the reader's prologue (pattern-verified per arch;
//      any mismatch logs and skips instead of guessing).
//   2. KCatalog::catalogLocaleDir interpose — the KCatalog static probe
//      derefs a null Android context on this deps bundle; interposing with
//      an empty-result stub makes KLocalizedString fall back to source
//      strings (exactly right for a headless engine).
//   3. QAndroidJniObject::javaObject interpose — serves a REAL
//      AssetManager (constructed through the injected VM) so any residual
//      probe path sees a valid object instead of aborting in ART.
// The wrapper TU is the FIRST object on the merge link line, so this
// constructor is init_array[0] of the merged engine — it runs before every
// Krita/KF5 static that needs it. Krita source is NEVER modified; this is
// bridge glue (allowed change surface #2).
// ---------------------------------------------------------------------------
#if defined(__ANDROID__)
#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>

// File-scope (internal linkage) so the javaObject() interpose above can
// serve it; written by the host-init constructor below.
static jobject g_fkr_asset_mgr = nullptr;

extern "C" {

// --- proven interposes (verbatim semantics from loop-43 smoke_jni.cpp) ----

// QString KCatalog::catalogLocaleDir(const QByteArray&, const QString&) —
// sret pointer first; loop-61 iteration-3: construct a REAL empty QString
// (a null d-pointer breaks callers that read d->size directly — Qt5's
// shared_null is a real static, not a null pointer).
__attribute__((visibility("default")))
void _ZN8KCatalog16catalogLocaleDirERK10QByteArrayRK7QString(
    void* sret, const void* /*component*/, const void* /*language*/) {
    new (sret) QString();
}

// jobject QAndroidJniObject::javaObject() const — serves the bootstrapped
// AssetManager (or null when the VM never appeared).
__attribute__((visibility("default")))
void* _ZNK17QAndroidJniObject10javaObjectEv(const void* /*this*/) {
    return g_fkr_asset_mgr;
}

// QString QStandardPaths::writableLocation(QStandardPaths::StandardLocation)
// — loop-61 boot-wall kill switch. The merged engine's Krita/KF5 statics
// cache writable locations at load time; the Qt 5.15 android backend
// routes EVERY location through JNI (testDir() is only a suffix), so a
// single load-time query needs a registered VM. The bridge is the dlopen
// TARGET (solist-first), so this definition wins the PLT binding for the
// whole closure and returns a real EMPTY QString — the same graceful
// outcome the loop-43 harness produced for a context-less process,
// without ever reaching the JNI backend. Desktop builds are
// untouched (guarded by __ANDROID__).
__attribute__((visibility("default")))
void _ZN14QStandardPaths16writableLocationENS_16StandardLocationE(
    void* sret, int /*type*/) {
    // Real empty QString (shared_null d-pointer) — iteration-3 lesson: a
    // raw nullptr sret crashed the caller's d->size read at fault 0x4.
    new (sret) QString();
}

} // extern "C"

namespace {

typedef jint (*FkrGetCreatedJavaVMs_t)(JavaVM**, jsize, jsize*);

// Recover the ART VM of this (already Java-hosted) process. Loop-61
// iteration-2 lesson: dlopen("libart.so") from the app's classloader
// namespace is BLOCKED (libart is not in public.libraries.txt), so first
// go through the MAIN EXECUTABLE handle (dlopen(nullptr) = app_process64,
// whose DT_NEEDED closure contains libart — namespace-safe), then fall
// back to the direct libart dlopen and a global-scope dlsym.
JavaVM* fkr_runtime_vm() {
    const auto log = [](const char* msg) {
        __android_log_print(ANDROID_LOG_INFO, "krita_bridge", "host-init: %s", msg);
    };
    FkrGetCreatedJavaVMs_t fn = nullptr;
    void* main_exe = dlopen(nullptr, RTLD_NOW | RTLD_GLOBAL);
    if (main_exe != nullptr) {
        fn = reinterpret_cast<FkrGetCreatedJavaVMs_t>(dlsym(main_exe, "JNI_GetCreatedJavaVMs"));
        log(fn ? "JNI_GetCreatedJavaVMs via main-exe handle"
               : "main-exe handle ok but JNI_GetCreatedJavaVMs not found");
    } else {
        log("dlopen(nullptr) failed — cannot walk the main-exe closure");
    }
    if (!fn) {
        if (void* h = dlopen("libart.so", RTLD_NOW | RTLD_GLOBAL)) {
            fn = reinterpret_cast<FkrGetCreatedJavaVMs_t>(dlsym(h, "JNI_GetCreatedJavaVMs"));
        }
    }
    if (!fn) fn = reinterpret_cast<FkrGetCreatedJavaVMs_t>(dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs"));
    if (!fn) return nullptr;
    JavaVM* vms[4] = {nullptr, nullptr, nullptr, nullptr};
    jsize n = 0;
    fn(vms, 4, &n);
    return (n > 0 && vms[0] != nullptr) ? vms[0] : nullptr;
}

// Locate Qt's g_javaVm through the exported javaVM() reader thunk, by
// exact prologue pattern per architecture (loop-43 technique; the reader
// is a pure global load, so the global's address is recoverable from the
// instruction encoding). Returns nullptr when the prologue does not match
// — the caller logs and continues (no guessing writes).
void* fkr_qt_g_java_vm_slot() {
    void* sym = dlsym(RTLD_DEFAULT, "_ZN16QtAndroidPrivate6javaVMEv");
    if (sym == nullptr) return nullptr;
    unsigned char* p = static_cast<unsigned char*>(sym);
#if defined(__x86_64__)
    // mov rax,[rip+disp32]; ret  — 8 bytes
    static const unsigned char kPat[8] = {0x48, 0x8b, 0x05, 0, 0, 0, 0, 0xc3};
    for (int i = 0; i < 8; ++i) {
        if (i >= 3 && i <= 6) continue;
        if (p[i] != kPat[i]) return nullptr;
    }
    int32_t disp = 0;
    std::memcpy(&disp, p + 3, 4);
    return p + 7 + disp;
#elif defined(__aarch64__)
    // adrp x0, <page>; ldr x0,[x0,#off]; ret  — 12 bytes
    uint32_t w0 = 0, w1 = 0, w2 = 0;
    std::memcpy(&w0, p, 4);
    std::memcpy(&w1, p + 4, 4);
    std::memcpy(&w2, p + 8, 4);
    if ((w0 & 0x9F00001Fu) != 0x90000000u) return nullptr;   // adrp x0, <label>
    if ((w1 & 0xFFC003FFu) != 0xF9400000u) return nullptr;   // ldr x0,[x0,#off]
    if (w2 != 0xD65F03C0u) return nullptr;                   // ret
    int64_t immlo = int64_t(w0 >> 29) & 0x3;
    int64_t immhi = int64_t(w0 >> 5) & 0x7FFFF;
    int64_t imm = (immhi << 2) | immlo;                       // 21 bits
    if (imm & (int64_t(1) << 20)) imm -= (int64_t(1) << 21);  // sign-extend
    uintptr_t page = (reinterpret_cast<uintptr_t>(p) & ~uintptr_t(0xFFF)) +
                     (uintptr_t)(imm << 12);
    uintptr_t off = uint64_t(w1 >> 10 & 0xFFFu) * 8u;
    return reinterpret_cast<void*>(page + off);
#else
    return nullptr;
#endif
}

// init_array[0] of the merged engine: runs before every Krita/KF5/Qt
// load-time static (the wrapper TU is the first object on the merge link
// line). Best-effort at every step; a skipped step only reproduces the
// pre-loop-61 behavior (loud tombstone) instead of a worse one.
struct FkrQtHostInit {
    FkrQtHostInit() {
        const auto log = [](const char* msg) {
            __android_log_print(ANDROID_LOG_INFO, "krita_bridge", "host-init: %s", msg);
        };
        JavaVM* vm = fkr_runtime_vm();
        if (vm == nullptr) { log("no runtime VM found — vminject skipped"); return; }
        void* slot = fkr_qt_g_java_vm_slot();
        if (slot == nullptr) { log("javaVM() prologue mismatch — vminject skipped"); return; }
        *static_cast<JavaVM* volatile*>(slot) = vm;
        log("g_javaVm injected (runtime VM)");

        // Real AssetManager for the javaObject() interpose (probes that
        // reach AAssetManager_fromJava abort on a null object).
        JNIEnv* env = nullptr;
        if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK || env == nullptr) {
            log("no env on the loading thread — AssetManager skipped");
            return;
        }
        jclass c = env->FindClass("android/content/res/AssetManager");
        if (c == nullptr) { env->ExceptionClear(); log("AssetManager class not found"); return; }
        jmethodID ctor = env->GetMethodID(c, "<init>", "()V");
        if (ctor == nullptr) { env->ExceptionClear(); log("AssetManager ctor not found"); return; }
        jobject o = env->NewObject(c, ctor);
        if (o == nullptr) { env->ExceptionClear(); log("AssetManager construction failed"); return; }
        g_fkr_asset_mgr = env->NewGlobalRef(o);
        env->DeleteLocalRef(o);
        env->DeleteLocalRef(c);
        log("real AssetManager acquired (global ref)");
    }
};
const FkrQtHostInit fkr_qt_host_init_instance;

} // namespace
#endif // __ANDROID__

// ---------------------------------------------------------------------------
// Glue: minimal PKZIP entry extraction for .kpp preset files.
// (Serialization only — the extracted XML is parsed by Krita's own code.)
// ---------------------------------------------------------------------------

namespace {

inline uint16_t rd16(const uint8_t* p) {
    return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
}
inline uint32_t rd32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
           (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

// Inflate DEFLATE data using the system zlib. [windowBits] selects the
// container format: -15 = raw DEFLATE (PKZIP entries), +15 = zlib-wrapped
// (PNG zTXt chunks).
QByteArray inflateBytes(const char* data, size_t n, int windowBits) {
    z_stream zs;
    std::memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, windowBits) != Z_OK) return QByteArray();
    zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(data));
    zs.avail_in = uint(n);
    QByteArray out;
    out.reserve(4096);
    uint8_t buf[8192];
    int ret = Z_OK;
    do {
        zs.next_out = buf;
        zs.avail_out = sizeof(buf);
        ret = inflate(&zs, Z_NO_FLUSH);
        if (ret == Z_STREAM_ERROR || ret == Z_NEED_DICT || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
            inflateEnd(&zs);
            return QByteArray();
        }
        const size_t produced = sizeof(buf) - zs.avail_out;
        if (produced > 0) out.append(reinterpret_cast<const char*>(buf), produced);
        if (zs.avail_in == 0 && produced == 0) break; // truncated stream
    } while (ret != Z_STREAM_END && zs.avail_out == 0);
    inflateEnd(&zs);
    return out;
}

QByteArray inflateRaw(const char* data, size_t n) {
    return inflateBytes(data, n, -15);
}

qint64 findEocd(const QByteArray& data) {
    const qint64 n = data.size();
    const qint64 maxBack = n < 65557 ? n : 65557;
    for (qint64 i = n - 22; i >= n - maxBack; --i) {
        if (i < 0) break;
        const uint8_t* p = reinterpret_cast<const uint8_t*>(data.constData() + i);
        if (rd32(p) == 0x06054b50UL) return i;
    }
    return -1;
}

QByteArray zipExtractFile(const QByteArray& zipData, const QString& name) {
    const qint64 eocd = findEocd(zipData);
    if (eocd < 0) return QByteArray();
    const uint8_t* base = reinterpret_cast<const uint8_t*>(zipData.constData());
    const uint8_t* e = base + eocd;
    const uint32_t cdOffset = rd32(e + 16);
    const uint32_t cdSize = rd32(e + 12);
    if (cdOffset + cdSize > (uint32_t)zipData.size()) return QByteArray();

    const uint8_t* cd = base + cdOffset;
    const uint8_t* cdEnd = cd + cdSize;
    while (cd + 46 <= cdEnd) {
        if (rd32(cd) != 0x02014b50UL) break;
        const uint16_t method = rd16(cd + 10);
        const uint32_t compSize = rd32(cd + 20);
        const uint16_t nameLen = rd16(cd + 28);
        const uint16_t extraLen = rd16(cd + 30);
        const uint16_t commentLen = rd16(cd + 32);
        const uint32_t localOff = rd32(cd + 42);
        const QByteArray entryName(reinterpret_cast<const char*>(cd + 46), nameLen);
        cd += 46 + nameLen + extraLen + commentLen;
        if (QString::fromUtf8(entryName) != name) continue;

        if (localOff + 30 > (uint32_t)zipData.size()) return QByteArray();
        const uint8_t* lh = base + localOff;
        if (rd32(lh) != 0x04034b50UL) return QByteArray();
        const uint16_t lhNameLen = rd16(lh + 26);
        const uint16_t lhExtraLen = rd16(lh + 28);
        const uint8_t* data = lh + 30 + lhNameLen + lhExtraLen;
        if (data + compSize > base + zipData.size()) return QByteArray();

        if (method == 0) {
            return QByteArray(reinterpret_cast<const char*>(data), compSize);
        } else if (method == 8) {
            return inflateRaw(reinterpret_cast<const char*>(data), compSize);
        }
        return QByteArray();
    }
    return QByteArray();
}

// ---------------------------------------------------------------------------
// Legacy PNG preset container: Krita's stock presets are PNG thumbnails
// whose preset XML lives in a compressed zTXt chunk with the keyword
// "preset" (format version "2.2" in the tEXt chunk). Extraction only —
// the XML is parsed by Krita's own code and the generic param mapper
// below.
// ---------------------------------------------------------------------------

QByteArray pngExtractPresetXml(const QByteArray& png) {
    const uint8_t sig[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    if (png.size() < 8 || std::memcmp(png.constData(), sig, 8) != 0) {
        return QByteArray();
    }
    const uint8_t* base = reinterpret_cast<const uint8_t*>(png.constData());
    qint64 pos = 8;
    while (pos + 8 <= png.size()) {
        // PNG chunk lengths are BIG-endian (unlike the PKZIP fields above,
        // which are little-endian — hence rd32 there, be32 here).
        const uint32_t len = (uint32_t(base[pos]) << 24) |
                             (uint32_t(base[pos + 1]) << 16) |
                             (uint32_t(base[pos + 2]) << 8) |
                             uint32_t(base[pos + 3]);
        const char* type = reinterpret_cast<const char*>(base + pos + 4);
        if (len > (uint32_t)(png.size() - pos - 12)) break; // corrupt
        const uint8_t* data = base + pos + 8;
        const bool isZtxt = std::memcmp(type, "zTXt", 4) == 0;
        const bool isText = std::memcmp(type, "tEXt", 4) == 0;
        if (isZtxt || isText) {
            // chunk = keyword \0 [method \0] payload
            const uint8_t* nul =
                static_cast<const uint8_t*>(std::memchr(data, 0, len));
            if (nul) {
                const qint64 kwLen = nul - data;
                const QByteArray keyword(reinterpret_cast<const char*>(data), kwLen);
                if (keyword.compare("preset", Qt::CaseInsensitive) == 0) {
                    const uint8_t* payload = nul + 1;
                    const qint64 payloadLen = len - kwLen - 1;
                    if (isText) {
                        return QByteArray(reinterpret_cast<const char*>(data) + kwLen + 1,
                                          payloadLen);
                    }
                    // zTXt: one compression-method byte (0 = zlib) then the
                    // zlib-wrapped DEFLATE stream.
                    if (payloadLen > 1 && payload[0] == 0) {
                        return inflateBytes(
                            reinterpret_cast<const char*>(payload + 1),
                            size_t(payloadLen - 1), 15);
                    }
                }
            }
        }
        if (std::memcmp(type, "IEND", 4) == 0) break;
        pos += 12 + len; // length + type + data + crc
    }
    return QByteArray();
}

QList<QByteArray> zipListXmlEntries(const QByteArray& zipData) {
    QList<QByteArray> names;
    const qint64 eocd = findEocd(zipData);
    if (eocd < 0) return names;
    const uint8_t* base = reinterpret_cast<const uint8_t*>(zipData.constData());
    const uint8_t* e = base + eocd;
    const uint32_t cdOffset = rd32(e + 16);
    const uint32_t cdSize = rd32(e + 12);
    if (cdOffset + cdSize > (uint32_t)zipData.size()) return names;

    const uint8_t* cd = base + cdOffset;
    const uint8_t* cdEnd = cd + cdSize;
    while (cd + 46 <= cdEnd) {
        if (rd32(cd) != 0x02014b50UL) break;
        const uint16_t nameLen = rd16(cd + 28);
        const uint16_t extraLen = rd16(cd + 30);
        const uint16_t commentLen = rd16(cd + 32);
        const QByteArray entryName(reinterpret_cast<const char*>(cd + 46), nameLen);
        cd += 46 + nameLen + extraLen + commentLen;
        if (entryName.length() >= 4 &&
            entryName.endsWith(".xml") &&
            !entryName.contains('/')) {
            names.append(entryName);
        }
    }
    return names;
}

// Find the first descendant element with the given tag name (recursive).
QDomElement firstDescendant(const QDomElement& parent, const QString& tag) {
    if (parent.tagName() == tag) return parent;
    for (QDomElement child = parent.firstChildElement();
         !child.isNull();
         child = child.nextSiblingElement()) {
        const QDomElement hit = firstDescendant(child, tag);
        if (!hit.isNull()) return hit;
    }
    return QDomElement();
}

} // namespace

// ---------------------------------------------------------------------------
// Bridge context — owns real Krita objects.
// ---------------------------------------------------------------------------

/// One entry of a preset-directory scan (preset-families campaign):
/// absolute file path, display name and declared paintop family, all
/// parsed by the engine's own container/XML path.
struct PresetScanEntry {
    std::string path;
    std::string name;
    std::string family;
};

struct KritaBrushContext {
    // ABI parameters (mirrors the fallback bridge defaults).
    double size = 16.0;
    double opacity = 1.0;
    double flow = 1.0;      // per-dab application rate (FlowValue sensor base)
    double hardness = 0.85;
    double spacing = 0.15;
    double smudge = 0.0;
    uint32_t color = 0xFF000000; // ARGB
    bool eraser = false;

    // Real Krita engine state.
    const KoColorSpace* cs = nullptr;   // lazily created RGBA8
    int rIdx = 0;                       // probed channel byte indices
    int gIdx = 1;
    int bIdx = 2;
    int aIdx = 3;                       // -1 if the colorspace has no alpha
    KisBrushSP brush;                   // real KisAutoBrush / preset brush
    bool brushFromPreset = false;       // brush loaded via KisBrush::fromXML

    // Bookkeeping.
    QString presetPath;
    QString presetName;
    std::vector<PresetScanEntry> presetScan;
    std::string lastError;
    std::string nameBuffer;
    std::string scanBuffer;
    std::string versionBuffer;
    std::string paintopId;   // declared preset family (paintopid root attr)

    void setError(const std::string& m) { lastError = m; }
    void clearError() { lastError.clear(); }
};

// ---------------------------------------------------------------------------
// Engine setup (all construction goes through real Krita classes).
// ---------------------------------------------------------------------------

namespace {

// Rebuild the real auto brush from the current size/hardness parameters.
// This mirrors what Krita's own KisAutoBrushFactory::createBrush does for
// <brush type="auto_brush"> definitions: a circle generator for hard tips,
// a gaussian generator with (1 - hardness) fade for soft tips, spikes=2
// (Krita's own default for round tips).
void rebuildAutoBrush(KritaBrushContext* h) {
    const qreal fade = qBound<qreal>(0.0, 1.0 - h->hardness, 1.0);
    KisMaskGenerator* gen;
    if (h->hardness >= 0.999) {
        gen = new KisCircleMaskGenerator(h->size, 1.0, 0.0, 0.0, 2, true);
    } else {
        gen = new KisGaussCircleMaskGenerator(h->size, 1.0, fade, fade, 2, true);
    }
    // KisAutoBrush takes ownership of the mask generator.
    h->brush = KisBrushSP(new KisAutoBrush(gen, 0.0, 0.0, 1.0));
    h->brushFromPreset = false;
}

// Lazily initialize the real colorspace + brush. Returns false on failure
// (last_error is set).
bool ensureEngine(KritaBrushContext* h) {
    if (!h->cs) {
        h->cs = KoColorSpaceRegistry::instance()->rgb8();
        if (!h->cs) {
            h->setError("KoColorSpaceRegistry::rgb8() failed");
            return false;
        }
        // Probe the channel byte indices with fully TRANSPARENT primary
        // colors: exactly one byte is 255 per probe, which identifies R, G
        // and B regardless of the layout Krita uses (RGBA, BGRA, ...).
        struct Probe { const char* name; int* idx; };
        const QColor primaries[3] = {
            QColor(255, 0, 0, 0),
            QColor(0, 255, 0, 0),
            QColor(0, 0, 255, 0),
        };
        int* targets[3] = { &h->rIdx, &h->gIdx, &h->bIdx };
        for (int p = 0; p < 3; ++p) {
            KoColor probe(primaries[p], h->cs);
            const quint8* d = probe.data();
            for (int i = 0; i < h->cs->channelCount(); ++i) {
                if (d[i] == 255) { *targets[p] = i; break; }
            }
        }
        // Alpha: the remaining channel (channel indices sum to 0+1+2+3).
        if (h->cs->channelCount() == 4) {
            h->aIdx = 6 - (h->rIdx + h->gIdx + h->bIdx);
            if (h->aIdx < 0 || h->aIdx > 3 ||
                (h->aIdx == h->rIdx || h->aIdx == h->gIdx || h->aIdx == h->bIdx)) {
                h->aIdx = -1;
            }
        } else {
            h->aIdx = -1; // no alpha channel: alpha is implicitly 255
        }
    }
    if (!h->brush) rebuildAutoBrush(h);
    return true;
}

KoColor abiColorToKoColor(KritaBrushContext* h, bool forceBlack = false) {
    if (forceBlack) {
        return KoColor(QColor(0, 0, 0), h->cs);
    }
    const int r = (h->color >> 16) & 0xFF;
    const int g = (h->color >> 8) & 0xFF;
    const int b = h->color & 0xFF;
    return KoColor(QColor(r, g, b), h->cs);
}

} // namespace

// ---------------------------------------------------------------------------
// Preset container/XML extraction shared by krita_brush_load_preset and
// the preset-directory scan (preset-families campaign).
// ---------------------------------------------------------------------------

// Extract the preset XML payload from a .kpp container. Supported
// containers: PKZIP KoStore archives (the XML entry named after the
// preset), legacy PNG stock presets (zTXt chunk keyed "preset") and bare
// XML files. On a PNG container without the chunk, *err (when non-null)
// is set so the loader can keep its historical error message; an empty
// return with an empty *err means "no XML found at all".
QByteArray extractPresetXml(const QByteArray& container, std::string* err = nullptr) {
    if (err) err->clear();
    const uint8_t* cdata = reinterpret_cast<const uint8_t*>(container.constData());
    static const uint8_t pngSig[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    QByteArray xml;
    if (container.size() >= 4 && rd32(cdata) == 0x04034b50UL) {
        const QList<QByteArray> entries = zipListXmlEntries(container);
        for (const QByteArray& entryName : entries) {
            const QByteArray candidate = zipExtractFile(container, QString::fromUtf8(entryName));
            if (!candidate.isEmpty()) { xml = candidate; break; }
        }
    } else if (container.size() >= 8 && std::memcmp(cdata, pngSig, 8) == 0) {
        xml = pngExtractPresetXml(container);
        if (xml.isEmpty() && err) *err = "png";
    } else if (!container.isEmpty()) {
        xml = container;
    }
    return xml;
}

// Light parse of one preset container: display name + declared paintop
// family. Shares the container/XML path of krita_brush_load_preset; no
// engine objects are constructed, so a scan stays cheap even on large
// preset directories. Returns false when the file carries no parsable
// preset XML (the caller skips it — robust directory scan).
bool probePresetFile(const QString& path, QString* nameOut, QString* familyOut) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    const QByteArray container = f.readAll();
    f.close();

    const QByteArray xml = extractPresetXml(container);
    if (xml.isEmpty()) return false;
    QDomDocument doc;
    if (!doc.setContent(xml)) return false;

    const QDomElement root = doc.documentElement();
    QString name = root.attribute("name");
    if (name.isEmpty()) name = QFileInfo(path).completeBaseName();
    QString pid = root.attribute("paintopid");
    if (pid.isEmpty() &&
        root.tagName().compare("Paintop", Qt::CaseInsensitive) == 0) {
        pid = root.attribute("id");
    }
    *nameOut = name;
    *familyOut = pid;
    return true;
}

// ---------------------------------------------------------------------------
// C API implementation.
// ---------------------------------------------------------------------------

extern "C" {

KritaBrushContext* krita_brush_init(void) {
    KritaBrushContext* ctx = new (std::nothrow) KritaBrushContext();
    return ctx;
}

void krita_brush_destroy(KritaBrushContext* handle) {
    if (!handle) return;
    delete handle;
}

int32_t krita_brush_load_preset(KritaBrushContext* handle, const char* path) {
    if (!handle || !path) return 1;
    handle->clearError();
    if (!ensureEngine(handle)) return 10;

    QFileInfo info(QString::fromUtf8(path));
    if (!info.exists() || !info.isFile()) {
        handle->setError("preset file does not exist: " + std::string(path));
        return 2;
    }
    handle->presetPath = info.filePath();
    handle->presetName = info.completeBaseName();
    handle->paintopId.clear();  // re-filled from the root element below

    QFile f(info.filePath());
    if (!f.open(QIODevice::ReadOnly)) {
        handle->setError("cannot open preset file");
        return 3;
    }
    const QByteArray container = f.readAll();
    f.close();

    std::string extractErr;
    const QByteArray xml = extractPresetXml(container, &extractErr);
    if (!extractErr.empty()) {
        handle->setError("PNG preset container has no 'preset' zTXt/tEXt chunk");
        return 6;
    }
    if (xml.isEmpty()) {
        handle->setError("no preset XML found in container");
        return 4;
    }

    QDomDocument doc;
    if (!doc.setContent(xml)) {
        handle->setError("preset XML is not well-formed");
        return 5;
    }

    // ------------------------------------------------------------------
    // Paintop-settings-level parameter map (roadmap (f)).
    //
    // Real Krita presets store every paintop setting as a flat <param>
    // entry at the settings level, e.g.:
    //
    //   <Preset name="..." paintopid="paintbrush">
    //     <param name="Krita/opacity" type="string"><![CDATA[100]]></param>
    //     <param name="CompositeOp" type="string"><![CDATA[erase]]></param>
    //     <param name="brush_definition" ...><![CDATA[<Brush ...>...</Brush>]]></param>
    //   </Preset>
    //
    // while legacy/synthetic shapes use <param id="brush_size" value="77"/>
    // or <param name="opacity" value="0.42"/>. Collect ALL <param>
    // descendants (every depth), accepting both the name= and id= spellings
    // and both a value= attribute and text/CDATA content.
    // ------------------------------------------------------------------
    QHash<QString, QString> params;
    {
        const QDomNodeList all = doc.elementsByTagName("param");
        for (int i = 0; i < all.size(); ++i) {
            const QDomElement p = all.at(i).toElement();
            if (p.isNull()) continue;
            QString key = p.attribute("name");
            if (key.isEmpty()) key = p.attribute("id");
            if (key.isEmpty()) continue;
            QString value = p.attribute("value");
            if (value.isEmpty()) value = p.text().trimmed();
            if (!value.isEmpty()) params.insert(key, value);
        }
    }

    // Helper lambdas over the map.
    auto lookup = [&params](const QStringList& keys) -> QString {
        for (const QString& k : keys) {
            const auto it = params.constFind(k);
            if (it != params.constEnd()) return it.value();
        }
        return QString();
    };
    auto toDouble = [](const QString& s, bool* ok) -> double {
        const double v = s.toDouble(ok);
        return *ok ? v : 0.0;
    };

    // --- Brush tip (real engine part, parsed by Krita's own fromXML) ------
    // The <Brush> element can appear as a real XML descendant (ZIP shapes)
    // or as the "brush_definition" settings value (stock PNG presets).
    QDomElement root = doc.documentElement();
    // Paintop family identity (paintop identity campaign): stock presets
    // declare <Preset paintopid="paintbrush">, legacy/synthetic shapes
    // use <Paintop id="paintbrush">. Reported via
    // krita_brush_get_paintop_id so the UI can badge the family and gate
    // per-paintop options (hardness etc.).
    {
        QString pid = root.attribute("paintopid");
        if (pid.isEmpty() &&
            root.tagName().compare("Paintop", Qt::CaseInsensitive) == 0) {
            pid = root.attribute("id");
        }
        handle->paintopId = pid.toStdString();
    }
    QDomElement brushEl = firstDescendant(root, "brush");
    if (brushEl.isNull()) brushEl = firstDescendant(root, "Brush");
    const QString brushDefinition = lookup(QStringList() << "brush_definition");
    if (brushEl.isNull() && brushDefinition.startsWith("<")) {
        QDomDocument frag;
        if (frag.setContent(brushDefinition)) {
            brushEl = frag.documentElement();
        }
    }
    bool fadeFromBrush = false;
    bool spacingFromBrush = false;
    qreal expectedDiameter = -1.0;
    if (!brushEl.isNull()) {
        // Real spacing attribute on the brush element (fixed spacing; the
        // useAutoSpacing/autoSpacingCoeff attrs are applied by Krita's own
        // paintop spacing logic).
        if (brushEl.hasAttribute("spacing")) {
            bool ok = false;
            const double s = brushEl.attribute("spacing").toDouble(&ok);
            if (ok && s > 0.0) { handle->spacing = s; spacingFromBrush = true; }
        }
        // Real tip diameter + softness from the MaskGenerator element. In
        // stock presets (BrushVersion 2) softness is hfade/vfade; older
        // shapes use a single fade attribute. hardness = 1 - fade.
        const QDomElement mg = brushEl.firstChildElement("MaskGenerator");
        if (!mg.isNull()) {
            const QString diamAttr = mg.hasAttribute("diameter")
                ? mg.attribute("diameter") : mg.attribute("radius");
            bool ok = false;
            const double d = diamAttr.toDouble(&ok);
            if (ok && d >= 1.0) {
                handle->size = d;
                expectedDiameter = d;
            }
            const QString fadeAttr = mg.hasAttribute("hfade")
                ? mg.attribute("hfade")
                : (mg.hasAttribute("vfade") ? mg.attribute("vfade")
                                             : mg.attribute("fade"));
            if (!fadeAttr.isEmpty()) {
                const double fade = fadeAttr.toDouble(&ok);
                if (ok && fade >= 0.0 && fade <= 1.0) {
                    handle->hardness = 1.0 - fade;
                    fadeFromBrush = true;
                }
            }
        }
        // REAL path: hand the <Brush> definition to Krita's own loader.
        // NOTE: KisBrush::fromXML NEVER returns null — when its registry
        // path cannot make sense of the element it silently substitutes a
        // default-fallback auto brush. Trust the result only when its
        // geometry matches the tip we parsed above; otherwise fall through
        // to a real KisAutoBrush rebuilt from the parsed diameter/fade
        // (same Krita generator classes, preset's own parameters).
        KisBrushSP realBrush =
            KisBrush::fromXML(brushEl, KisGlobalResourcesInterface::instance());
        bool trusted = false;
        if (realBrush) {
            if (expectedDiameter > 0.0) {
                const qreal eff = realBrush->userEffectiveSize();
                trusted = realBrush->valid() &&
                          qAbs(eff - expectedDiameter) <=
                              qMax<qreal>(1.0, expectedDiameter * 0.2);
            } else {
                // Tip without a numeric diameter (image/pipe brushes):
                // keep the historical trust rule.
                trusted = realBrush->valid();
            }
        }
        if (trusted) {
            handle->brush = realBrush;
            handle->brushFromPreset = true;
        }
    }
    // Self-heal: when the registry-built brush was rejected, rebuild a real
    // auto brush from the preset's parsed tip parameters (ensureEngine
    // created one earlier with the stale default size 16).
    if (!handle->brushFromPreset && !brushEl.isNull() &&
        (expectedDiameter > 0.0 || fadeFromBrush)) {
        if (ensureEngine(handle)) rebuildAutoBrush(handle);
    }

    // --- Paintop-settings-level params (the user-facing values) -----------

    // Opacity. "Krita/opacity" is the master 0-100 slider value written by
    // Krita's paintop settings; "OpacityValue" is the sensor base (0-1);
    // legacy shapes use flat "opacity" / "brush_opacity".
    {
        bool ok = false;
        const QString master = lookup(QStringList() << "Krita/opacity");
        double v = master.toDouble(&ok);
        if (ok && v >= 0.0 && v <= 100.0) {
            handle->opacity = v / 100.0;
        } else {
            v = toDouble(lookup(QStringList() << "OpacityValue"
                                              << "opacity"
                                              << "brush_opacity"), &ok);
            if (ok && v > 0.0 && v <= 1.0) handle->opacity = v;
        }
    }

    // Hardness fallbacks for tips without a MaskGenerator fade (image and
    // pipe brushes). "Softness" in Krita is the complement of hardness;
    // the sensor base "SoftnessValue" mirrors the same scale.
    if (!fadeFromBrush) {
        bool ok = false;
        const QString h = lookup(QStringList() << "hardness");
        double v = h.toDouble(&ok);
        if (ok && v >= 0.0 && v <= 1.0) {
            handle->hardness = v;
        } else {
            v = toDouble(lookup(QStringList() << "SoftnessValue" << "softness"), &ok);
            if (ok && v >= 0.0 && v <= 1.0) handle->hardness = 1.0 - v;
        }
    }

    // Spacing fallback for brush elements without a spacing attribute.
    if (!spacingFromBrush) {
        bool ok = false;
        const double v = toDouble(lookup(QStringList() << "brush_spacing"), &ok);
        if (ok && v > 0.0 && v <= 5.0) handle->spacing = v;
    }

    // Smudge rate: only the smudge-bearing paintops write it (colorsmudge
    // family, "SmudgeRate*" settings namespace); leave 0 otherwise.
    {
        bool ok = false;
        const double v = toDouble(lookup(QStringList() << "SmudgeRateValue"
                                                      << "smudge_rate"
                                                      << "smudge"), &ok);
        if (ok && v >= 0.0 && v <= 1.0) handle->smudge = v;
    }

    // Flow: the paintop FlowValue sensor base (0-1). Krita's paintbrush /
    // airbrush / colorsmudge families write it; presets that omit it keep
    // the default 1.0 (full application per dab). Distinct from the master
    // opacity (Krita/opacity) which is left to the host compositor.
    {
        bool ok = false;
        const double v = toDouble(lookup(QStringList() << "FlowValue"
                                                      << "flow"), &ok);
        if (ok && v >= 0.0 && v <= 1.0) handle->flow = v;
    }

    // Eraser mode. Krita marks eraser presets in three ways (stock files
    // use CompositeOp=erase; the settings checkbox writes Krita/erase or
    // EraserMode; legacy shapes use a flat eraser param).
    {
        const QString eraseFlag = lookup(QStringList() << "Krita/erase"
                                                       << "EraserMode"
                                                       << "eraser");
        const QString composite = lookup(QStringList() << "CompositeOp");
        const bool truthy = eraseFlag.compare("true", Qt::CaseInsensitive) == 0 ||
                            eraseFlag == "1" || eraseFlag == "1.0";
        if (truthy || composite.compare("erase", Qt::CaseInsensitive) == 0) {
            handle->eraser = true;
        }
    }

    return 0;
}

void krita_brush_set_size(KritaBrushContext* handle, double size) {
    if (!handle) return;
    const double s = size < 1.0 ? 1.0 : size;
    if (std::abs(s - handle->size) > 1e-9 || !handle->brush) {
        handle->size = s;
        // Only rebuild auto brushes; preset-loaded brushes are scaled via
        // KisDabShape in generate_dab (real Krita behavior).
        if (!handle->brushFromPreset) {
            if (ensureEngine(handle)) rebuildAutoBrush(handle);
        }
    } else {
        handle->size = s;
    }
}

void krita_brush_set_color(KritaBrushContext* handle, uint32_t argb) {
    if (!handle) return;
    handle->color = argb;
}

void krita_brush_set_opacity(KritaBrushContext* handle, double opacity) {
    if (!handle) return;
    handle->opacity = opacity < 0.0 ? 0.0 : (opacity > 1.0 ? 1.0 : opacity);
}

void krita_brush_set_spacing(KritaBrushContext* handle, double spacing) {
    if (!handle) return;
    handle->spacing = spacing < 0.0 ? 0.0 : (spacing > 5.0 ? 5.0 : spacing);
}

void krita_brush_set_smudge(KritaBrushContext* handle, double smudge) {
    if (!handle) return;
    handle->smudge = smudge < 0.0 ? 0.0 : (smudge > 1.0 ? 1.0 : smudge);
}

void krita_brush_set_flow(KritaBrushContext* handle, double flow) {
    if (!handle) return;
    handle->flow = flow < 0.0 ? 0.0 : (flow > 1.0 ? 1.0 : flow);
    // Flow is a per-dab alpha scale applied in generate_dab — no brush
    // rebuild needed (the mask generator shape is unchanged).
}

void krita_brush_set_hardness(KritaBrushContext* handle, double hardness) {
    if (!handle) return;
    const double h = hardness < 0.0 ? 0.0 : (hardness > 1.0 ? 1.0 : hardness);
    handle->hardness = h;
    // Hardness lives in the mask generator's fade (1 - hardness). There is
    // no KisDabShape equivalent for fade, so rebuild the tip always — an
    // explicit hardness override supersedes any preset-loaded brush
    // (mirrors the loop-37 self-heal rebuild path).
    if (ensureEngine(handle)) rebuildAutoBrush(handle);
}

double krita_brush_get_size(KritaBrushContext* handle) {
    return handle ? handle->size : 0.0;
}

double krita_brush_get_opacity(KritaBrushContext* handle) {
    return handle ? handle->opacity : 0.0;
}

double krita_brush_get_spacing(KritaBrushContext* handle) {
    return handle ? handle->spacing : 0.0;
}

double krita_brush_get_hardness(KritaBrushContext* handle) {
    return handle ? handle->hardness : 0.0;
}

double krita_brush_get_smudge(KritaBrushContext* handle) {
    return handle ? handle->smudge : 0.0;
}

double krita_brush_get_flow(KritaBrushContext* handle) {
    return handle ? handle->flow : 0.0;
}

bool krita_brush_get_eraser(KritaBrushContext* handle) {
    return handle ? handle->eraser : false;
}

const char* krita_brush_get_preset_name(KritaBrushContext* handle) {
    if (!handle) return "";
    handle->nameBuffer = handle->presetName.toStdString();
    return handle->nameBuffer.c_str();
}

const char* krita_brush_get_paintop_id(KritaBrushContext* handle) {
    if (!handle) return "";
    return handle->paintopId.c_str();
}

bool krita_brush_generate_dab(KritaBrushContext* handle,
                              const BrushInput* input,
                              BrushDab* out_dab) {
    if (!handle || !input || !out_dab) return false;
    handle->clearError();

    out_dab->width = 0;
    out_dab->height = 0;
    out_dab->stride = 0;
    out_dab->reserved = 0;
    out_dab->pixels = nullptr;

    if (!ensureEngine(handle)) return false;

    const double pressure = (input->pressure > 0.0 && input->pressure <= 1.0)
        ? input->pressure : 1.0;
    const bool eraser = (input->flags & kBrushInputEraser) || handle->eraser;

    // ABI pressure->size policy (identical to the fallback bridge's
    // documented behavior: minimum 20% of the configured diameter).
    const double sizeFactor = 0.2 + 0.8 * pressure;
    if (handle->size * sizeFactor < 1.0) return false;

    // Real dab scale. For auto brushes the generator diameter equals the
    // configured size, so the extra factor is 1; preset brushes scale
    // relative to their own effective size (real Krita semantics).
    qreal scale = sizeFactor;
    if (handle->brushFromPreset) {
        const qreal eff = qMax<qreal>(1.0, handle->brush->userEffectiveSize());
        scale = sizeFactor * (handle->size / eff);
    }


    // Real Krita dab generation:
    //   tip image -> pyramid scaling/rotation -> colorize through mask.
    // Size scaling goes through KisBrush::setScale (the real KisPaintOp
    // path for pressure->size); the auto-brush mask generator path does
    // not consume KisDabShape scale directly.
    handle->brush->setScale(scale);
    const KisDabShape shape(1.0, 1.0, 0.0);
    const KisPaintInformation info(QPointF(0.0, 0.0), pressure);
    const KoColor c = abiColorToKoColor(handle, eraser);

    KisFixedPaintDeviceSP dst = new KisFixedPaintDevice(handle->cs);
    handle->brush->mask(dst, c, shape, info,
                        input->x - std::floor(input->x),   // real subpixel AA
                        input->y - std::floor(input->y));
    if (!dst || dst->bounds().isEmpty() || !dst->data()) {
        handle->setError("KisBrush::mask produced no dab");
        return false;
    }

    const QRect bounds = dst->bounds();
    const int w = bounds.width();
    const int h = bounds.height();
    const int stride = w * 4;
    const size_t bytes = size_t(stride) * size_t(h);
    uint8_t* buf = static_cast<uint8_t*>(std::malloc(bytes));
    if (!buf) {
        handle->setError("out of memory");
        return false;
    }

    // Convert Krita's native RGBA8 layout to the ABI's straight-alpha
    // R,G,B,A layout and apply the ABI's pressure->alpha scaling.
    const quint8* src = dst->data();
    const int rIdx = handle->rIdx;
    const int gIdx = handle->gIdx;
    const int bIdx = handle->bIdx;
    const int aIdx = handle->aIdx;
    const quint32 pixelSize = handle->cs->pixelSize();
    for (int y = 0; y < h; ++y) {
        const quint8* row = src + size_t(y) * size_t(w) * pixelSize;
        uint8_t* out = buf + size_t(y) * size_t(stride);
        for (int x = 0; x < w; ++x) {
            const quint8* px = row + size_t(x) * pixelSize;
            out[0] = px[rIdx];
            out[1] = px[gIdx];
            out[2] = px[bIdx];
            const uint8_t alpha = (aIdx >= 0) ? px[aIdx] : 255;
            // ABI per-dab alpha scaling: pressure (stylus) * flow (per-dab
            // application rate). Opacity is the master multiplier left to
            // the host compositor (KisPainter layer in desktop Krita).
            const int a = int(std::lround(double(alpha) * pressure * handle->flow));
            out[3] = uint8_t(a > 255 ? 255 : a);
            out += 4;
        }
    }

    out_dab->width = w;
    out_dab->height = h;
    out_dab->stride = stride;
    out_dab->reserved = 0;
    out_dab->pixels = buf;
    return true;
}

void krita_brush_release_dab(KritaBrushContext* handle, BrushDab* dab) {
    if (!handle || !dab) return;
    if (dab->pixels) {
        std::free(dab->pixels);
        dab->pixels = nullptr;
    }
    dab->width = 0;
    dab->height = 0;
    dab->stride = 0;
}

void krita_brush_cleanup(KritaBrushContext* handle) {
    if (!handle) return;
    // Real Krita keeps per-stroke state inside the paintop / stroke
    // strategy; the dab-level ABI is stateless per stroke.
}

const char* krita_brush_last_error(KritaBrushContext* handle) {
    if (!handle) return "";
    return handle->lastError.c_str();
}

const char* krita_brush_version(void) {
    // Real Krita version, fetched from the unmodified libkritaversion.
    static std::string v;
    if (v.empty()) {
        const QString s = KritaVersionWrapper::versionString(false);
        v = "FeatherBridge-Krita/2.0 (real engine " + s.toStdString() + ")";
    }
    return v.c_str();
}

int32_t krita_brush_preset_scan(KritaBrushContext* handle, const char* dir) {
    if (!handle) return -1;
    if (!dir || !*dir) {
        handle->setError("scan dir is null or empty");
        return -1;
    }
    handle->clearError();
    const QDir rootDir(QString::fromUtf8(dir));
    if (!rootDir.exists()) {
        handle->setError("scan dir does not exist: " + std::string(dir));
        return -2;
    }

    handle->presetScan.clear();
    // Recursive *.kpp walk (Krita bundles presets in per-family
    // subdirectories); the hard cap keeps a pathological tree bounded.
    QDirIterator it(rootDir.absolutePath(), QStringList() << "*.kpp",
                    QDir::Files, QDirIterator::Subdirectories);
    QStringList files;
    while (it.hasNext() && files.size() < 512) files << it.next();
    files.sort();

    handle->presetScan.reserve(size_t(files.size()));
    for (const QString& f : files) {
        QString name, family;
        if (!probePresetFile(f, &name, &family)) continue;
        PresetScanEntry e;
        e.path = f.toUtf8().constData();
        e.name = name.toUtf8().constData();
        e.family = family.toUtf8().constData();
        handle->presetScan.push_back(std::move(e));
    }
    return int32_t(handle->presetScan.size());
}

int32_t krita_brush_preset_count(KritaBrushContext* handle) {
    if (!handle) return -1;
    return int32_t(handle->presetScan.size());
}

const char* krita_brush_preset_name(KritaBrushContext* handle, int32_t index) {
    if (!handle) return nullptr;
    if (index < 0 || size_t(index) >= handle->presetScan.size()) return nullptr;
    handle->nameBuffer = handle->presetScan[size_t(index)].name;
    return handle->nameBuffer.c_str();
}

const char* krita_brush_preset_family(KritaBrushContext* handle, int32_t index) {
    if (!handle) return nullptr;
    if (index < 0 || size_t(index) >= handle->presetScan.size()) return nullptr;
    handle->scanBuffer = handle->presetScan[size_t(index)].family;
    return handle->scanBuffer.c_str();
}

const char* krita_brush_preset_path(KritaBrushContext* handle, int32_t index) {
    if (!handle) return nullptr;
    if (index < 0 || size_t(index) >= handle->presetScan.size()) return nullptr;
    handle->scanBuffer = handle->presetScan[size_t(index)].path;
    return handle->scanBuffer.c_str();
}

} // extern "C"
