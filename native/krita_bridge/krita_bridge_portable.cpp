// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// krita_bridge_portable.cpp — dependency-free implementation of the
// krita_bridge.h C ABI for platforms where linking Qt is undesirable
// (Android NDK builds). Renders the same soft-round radial-gradient dabs
// and parses the same .kpp preset ZIP/XML structure as the Qt build.
//
// Uses only: C++17 standard library + zlib. zlib is available on Android
// (bionic ships it in the NDK sysroot), Linux (system), and Windows CI
// (vcpkg).

#include "krita_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include <zlib.h>

#ifdef _WIN32
#define PORTABLE_API __declspec(dllexport)
#else
#define PORTABLE_API __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------------------
// ZIP (PKZIP) reading — EOCD scan + central directory + zlib raw inflate.
// ---------------------------------------------------------------------------

namespace {

inline uint16_t rd16(const uint8_t* p) {
    return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
}
inline uint32_t rd32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
           (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

// Find the End-of-Central-Directory record. Returns its offset or -1.
int64_t findEocd(const std::vector<uint8_t>& data) {
    const int64_t n = static_cast<int64_t>(data.size());
    const int64_t maxBack = n < 65557 ? n : 65557;
    for (int64_t i = n - 22; i >= n - maxBack; --i) {
        if (i < 0) break;
        const uint8_t* p = data.data() + i;
        if (rd32(p) == 0x06054b50UL) return i;
    }
    return -1;
}

// Inflate raw DEFLATE data (no zlib header) using the system zlib.
std::vector<uint8_t> inflateRaw(const uint8_t* data, size_t n) {
    z_stream zs;
    std::memset(&zs, 0, sizeof(zs));
    // -15 = raw deflate (no zlib wrapper), 32KB window.
    if (inflateInit2(&zs, -15) != Z_OK) return {};
    zs.next_in = const_cast<Bytef*>(reinterpret_cast<const Bytef*>(data));
    zs.avail_in = static_cast<uInt>(n);
    std::vector<uint8_t> out;
    out.reserve(4096);
    uint8_t buf[8192];
    int ret = Z_OK;
    do {
        zs.next_out = buf;
        zs.avail_out = sizeof(buf);
        ret = inflate(&zs, Z_NO_FLUSH);
        if (ret == Z_STREAM_ERROR || ret == Z_NEED_DICT ||
            ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
            inflateEnd(&zs);
            return {};
        }
        const size_t produced = sizeof(buf) - zs.avail_out;
        if (produced > 0) out.insert(out.end(), buf, buf + produced);
    } while (ret != Z_STREAM_END && zs.avail_out == 0);
    inflateEnd(&zs);
    return out;
}

// Extract a single file from a ZIP archive by name. Supports STORED (0)
// and DEFLATED (8).
std::vector<uint8_t> zipExtractFile(const std::vector<uint8_t>& zipData,
                                    const std::string& name) {
    const int64_t eocd = findEocd(zipData);
    if (eocd < 0) return {};
    const uint8_t* base = zipData.data();
    const uint8_t* e = base + eocd;
    const uint32_t cdOffset = rd32(e + 16);
    const uint32_t cdSize = rd32(e + 12);
    if (cdOffset + cdSize > zipData.size()) return {};

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
        const std::string entryName(reinterpret_cast<const char*>(cd + 46), nameLen);
        cd += 46 + nameLen + extraLen + commentLen;
        if (entryName != name) continue;

        if (localOff + 30 > zipData.size()) return {};
        const uint8_t* lh = base + localOff;
        if (rd32(lh) != 0x04034b50UL) return {};
        const uint16_t lhNameLen = rd16(lh + 26);
        const uint16_t lhExtraLen = rd16(lh + 28);
        const uint8_t* data = lh + 30 + lhNameLen + lhExtraLen;
        if (data + compSize > base + zipData.size()) return {};

        if (method == 0) {
            return std::vector<uint8_t>(data, data + compSize);
        }
        if (method == 8) {
            return inflateRaw(data, compSize);
        }
        return {};
    }
    return {};
}

// List the names of all top-level entries that end with ".xml".
// Real Krita .kpp archives name the preset XML after the preset itself.
std::vector<std::string> zipListXmlEntries(const std::vector<uint8_t>& zipData) {
    std::vector<std::string> names;
    const int64_t eocd = findEocd(zipData);
    if (eocd < 0) return names;
    const uint8_t* base = zipData.data();
    const uint8_t* e = base + eocd;
    const uint32_t cdOffset = rd32(e + 16);
    const uint32_t cdSize = rd32(e + 12);
    if (cdOffset + cdSize > zipData.size()) return names;

    const uint8_t* cd = base + cdOffset;
    const uint8_t* cdEnd = cd + cdSize;
    while (cd + 46 <= cdEnd) {
        if (rd32(cd) != 0x02014b50UL) break;
        const uint16_t nameLen = rd16(cd + 28);
        const uint16_t extraLen = rd16(cd + 30);
        const uint16_t commentLen = rd16(cd + 32);
        const std::string entryName(reinterpret_cast<const char*>(cd + 46), nameLen);
        cd += 46 + nameLen + extraLen + commentLen;
        if (entryName.size() >= 4 &&
            entryName.compare(entryName.size() - 4, 4, ".xml") == 0 &&
            entryName.find('/') == std::string::npos) {
            names.push_back(entryName);
        }
    }
    return names;
}

// ---------------------------------------------------------------------------
// Minimal XML scanning for brush parameters. Mirrors the Qt parser: for each
// start element, take the "id" (or "name") attribute as the key and the
// "value" attribute (or the element's text) as the numeric value.
// ---------------------------------------------------------------------------

struct ParamPair {
    std::string key;
    double value;
    bool eraserFlag;
};

// Extract an attribute value from a "<tag ... attrs ...>" chunk.
bool attrValue(const std::string& chunk, const char* name, std::string* out) {
    const std::string pat = std::string(name) + "=";
    size_t p = chunk.find(pat);
    while (p != std::string::npos) {
        // Must be preceded by whitespace (attribute boundary).
        if (p == 0 || chunk[p - 1] == ' ' || chunk[p - 1] == '\t' ||
            chunk[p - 1] == '\n' || chunk[p - 1] == '\r') {
            const char quote = (p + pat.size() < chunk.size()) ? chunk[p + pat.size()] : 0;
            if (quote == '"' || quote == '\'') {
                const size_t vStart = p + pat.size() + 1;
                const size_t vEnd = chunk.find(quote, vStart);
                if (vEnd != std::string::npos) {
                    *out = chunk.substr(vStart, vEnd - vStart);
                    return true;
                }
            }
        }
        p = chunk.find(pat, p + 1);
    }
    return false;
}

std::vector<ParamPair> scanParams(const std::string& xml) {
    std::vector<ParamPair> pairs;
    size_t pos = 0;
    while (true) {
        const size_t lt = xml.find('<', pos);
        if (lt == std::string::npos) break;
        const size_t gt = xml.find('>', lt);
        if (gt == std::string::npos) break;
        const std::string tag = xml.substr(lt + 1, gt - lt - 1);
        pos = gt + 1;
        if (tag.empty() || tag[0] == '/' || tag[0] == '!' || tag[0] == '?') {
            continue;
        }
        std::string key;
        if (!attrValue(tag, "id", &key) && !attrValue(tag, "name", &key)) {
            continue;
        }
        std::string valStr;
        bool haveVal = attrValue(tag, "value", &valStr);
        bool selfClosed = tag.size() > 0 && tag.back() == '/';
        if (!haveVal) {
            // Element text: content between <tag> and </tag>.
            const size_t nameEnd = tag.find_first_of(" \t\n\r/");
            const std::string tagName = nameEnd == std::string::npos
                                            ? tag : tag.substr(0, nameEnd);
            const std::string openTag = "<" + tagName + ">";
            const std::string closeTag = "</" + tagName + ">";
            const size_t o = xml.find(openTag, lt);
            if (o != std::string::npos && o < gt + 2) {
                const size_t c = xml.find(closeTag, gt);
                if (c != std::string::npos) {
                    valStr = xml.substr(gt + 1, c - gt - 1);
                    haveVal = true;
                    pos = c + closeTag.size();
                }
            }
        }
        if (!haveVal) continue;
        char* endp = nullptr;
        const double v = std::strtod(valStr.c_str(), &endp);
        if (endp == valStr.c_str()) continue; // not numeric
        ParamPair pair;
        pair.key = key;
        pair.value = v;
        pair.eraserFlag = v > 0.5;
        pairs.push_back(pair);
    }
    return pairs;
}

struct PresetParams {
    double size = 0;
    double opacity = 0;
    double spacing = 0;
    double hardness = 0;
    bool eraser = false;
    bool smudge = false;
    double smudgeRatio = 0;
    double flow = -1.0; // sentinel: -1 = unset (0 is a valid flow value)
    std::string paintopId; // declared family (root paintopid/id attribute)

    bool hasAny() const {
        return size > 0 || opacity > 0 || spacing > 0 || hardness > 0;
    }
};

PresetParams parsePresetXml(const std::vector<uint8_t>& xmlBytes) {
    PresetParams p;
    const std::string xml(xmlBytes.begin(), xmlBytes.end());
    // Root paintop identity (paintop identity campaign): stock presets
    // declare <Preset paintopid="paintbrush">, legacy/synthetic shapes
    // use <Paintop id="paintbrush">. attrValue's whitespace boundary
    // keeps the "id=" fallback from matching inside "paintopid=".
    {
        static const char* kRoots[] = {"<Preset", "<Paintop"};
        for (const char* tag : kRoots) {
            const size_t pos = xml.find(tag);
            if (pos == std::string::npos) continue;
            const size_t gt = xml.find('>', pos);
            if (gt == std::string::npos) continue;
            const std::string head = xml.substr(pos, gt - pos);
            std::string pid;
            if (attrValue(head, "paintopid", &pid) ||
                attrValue(head, "id", &pid)) {
                if (!pid.empty()) p.paintopId = pid;
            }
            break;
        }
    }
    for (const ParamPair& pair : scanParams(xml)) {
        const std::string& key = pair.key;
        const double v = pair.value;
        if (key == "size" || key == "brush_size" || key == "diameter") p.size = v;
        else if (key == "opacity" || key == "brush_opacity") p.opacity = v;
        else if (key == "spacing" || key == "brush_spacing") p.spacing = v;
        else if (key == "hardness" || key == "softness") {
            p.hardness = (key == "softness") ? (1.0 - v) : v;
        }
        else if (key == "eraser" || key == "erase_mode") p.eraser = pair.eraserFlag;
        else if (key == "smudge" || key == "smudge_mode") p.smudge = pair.eraserFlag;
        else if (key == "smudge_ratio" || key == "smudge_amount") p.smudgeRatio = v;
        else if (key == "FlowValue" || key == "flow") p.flow = v;
    }
    return p;
}

// ---------------------------------------------------------------------------
// Brush context.
// ---------------------------------------------------------------------------

} // namespace

struct KritaBrushContext {
    double size = 16.0;
    double opacity = 1.0;
    double flow = 1.0;
    double hardness = 0.85;
    double spacing = 0.15;
    double smudge = 0.0;
    uint32_t color = 0xFF000000; // ARGB
    bool eraser = false;
    bool strokeStarted = false;
    std::string presetPath;
    std::string presetName;
    std::vector<std::string> availablePresets;
    std::string lastError;
    std::string presetNameBuffer;
    std::string paintopId;   // declared preset family (paintopid root attr)

    void setError(const std::string& m) { lastError = m; }
    void clearError() { lastError.clear(); }
};

namespace {

// Render a soft-round dab identical to the Qt implementation:
// radial gradient, solid color up to `hardness`, linear falloff to 0 at the
// edge; premultiplication happens in the caller (output here is RGBA8888,
// i.e. NON-premultiplied, matching the Qt build's Format_RGBA8888 output).
bool makeDab(double radius, double hardness, double pressure, double flow,
             uint32_t argb, bool eraser,
             int* outW, int* outH, int* outStride, uint8_t** outPixels) {
    const int r = std::max(1, static_cast<int>(std::ceil(radius)));
    const int d = r * 2;

    const double a = ((argb >> 24) & 0xFF) / 255.0;
    const double cr = ((argb >> 16) & 0xFF) / 255.0;
    const double cg = ((argb >> 8) & 0xFF) / 255.0;
    const double cb = (argb & 0xFF) / 255.0;
    // Per-dab alpha scale: pressure (stylus) * flow (application rate).
    // Opacity is the master multiplier left to the host compositor.
    const int solidA = std::min(255, static_cast<int>(a * 255.0 * pressure * flow + 0.5));
    const double stop = std::min(1.0, hardness);

    std::vector<uint8_t> px(size_t(d) * size_t(d) * 4, 0);
    for (int y = 0; y < d; ++y) {
        for (int x = 0; x < d; ++x) {
            const double dx = (x + 0.5) - r;
            const double dy = (y + 0.5) - r;
            const double dist = std::sqrt(dx * dx + dy * dy);
            const double t = dist / radius;
            if (t >= 1.0) continue; // outside the gradient radius
            double mask;
            if (t <= stop) {
                mask = 1.0;
            } else {
                mask = 1.0 - (t - stop) / std::max(1e-9, 1.0 - stop);
            }
            const uint8_t alpha =
                static_cast<uint8_t>(std::min(255.0, solidA * mask + 0.5));
            if (alpha == 0) continue;
            const size_t i = (size_t(y) * size_t(d) + size_t(x)) * 4;
            if (eraser) {
                // Destination-out mask: RGB is ignored, alpha carries strength.
                px[i] = 0;
                px[i + 1] = 0;
                px[i + 2] = 0;
                px[i + 3] = static_cast<uint8_t>(
                    std::min(255.0, 255.0 * pressure * flow * mask + 0.5));
            } else {
                px[i] = static_cast<uint8_t>(std::min(255.0, cr * 255.0 + 0.5));
                px[i + 1] = static_cast<uint8_t>(std::min(255.0, cg * 255.0 + 0.5));
                px[i + 2] = static_cast<uint8_t>(std::min(255.0, cb * 255.0 + 0.5));
                px[i + 3] = alpha;
            }
        }
    }

    *outW = d;
    *outH = d;
    *outStride = d * 4;
    *outPixels = static_cast<uint8_t*>(std::malloc(px.size()));
    if (!*outPixels) return false;
    std::memcpy(*outPixels, px.data(), px.size());
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// C API implementation.
// ---------------------------------------------------------------------------

extern "C" {

PORTABLE_API KritaBrushContext* krita_brush_init(void) {
    try {
        return new (std::nothrow) KritaBrushContext();
    } catch (...) {
        return nullptr;
    }
}

PORTABLE_API void krita_brush_destroy(KritaBrushContext* handle) {
    delete handle;
}

PORTABLE_API int32_t krita_brush_load_preset(KritaBrushContext* handle,
                                             const char* path) {
    if (!handle || !path) return 1;
    handle->clearError();

    std::ifstream f(path, std::ios::binary);
    if (!f) {
        handle->setError(std::string("preset file does not exist: ") + path);
        return 2;
    }
    std::vector<uint8_t> zipData((std::istreambuf_iterator<char>(f)),
                                 std::istreambuf_iterator<char>());

    // Extract the preset XML: try common entry names, then every top-level
    // *.xml, then fall back to raw XML.
    std::vector<uint8_t> xml;
    static const char* xmlNames[] = {
        "preset.xml", "maindata.xml", "brush.xml", "data.xml", "paintop.xml", nullptr
    };
    for (int i = 0; xmlNames[i] && xml.empty(); ++i) {
        xml = zipExtractFile(zipData, xmlNames[i]);
    }
    if (xml.empty()) {
        const std::vector<std::string> entries = zipListXmlEntries(zipData);
        for (const std::string& name : entries) {
            const std::vector<uint8_t> candidate = zipExtractFile(zipData, name);
            if (candidate.empty()) continue;
            const PresetParams probe = parsePresetXml(candidate);
            if (probe.hasAny()) {
                xml = candidate;
                break;
            }
        }
    }
    if (xml.empty() && zipData.size() > 1 && zipData[0] == '<') {
        xml = zipData;
    }

    if (!xml.empty()) {
        const PresetParams p = parsePresetXml(xml);
        if (p.size > 0) handle->size = p.size;
        if (p.opacity > 0) handle->opacity = p.opacity;
        if (p.spacing > 0) handle->spacing = p.spacing;
        if (p.hardness > 0) handle->hardness = p.hardness;
        if (p.eraser) handle->eraser = true;
        if (p.smudge) handle->smudge = p.smudgeRatio;
        if (p.flow >= 0.0) handle->flow = p.flow;
        // Declared family replaces any previous preset's identity (empty
        // stays empty — no preset-level claim means no family badge).
        handle->paintopId = p.paintopId;
    }
    return 0;
}

PORTABLE_API void krita_brush_set_size(KritaBrushContext* handle, double size) {
    if (!handle) return;
    handle->size = size < 1.0 ? 1.0 : size;
}

PORTABLE_API void krita_brush_set_color(KritaBrushContext* handle, uint32_t argb) {
    if (!handle) return;
    handle->color = argb;
}

PORTABLE_API void krita_brush_set_opacity(KritaBrushContext* handle, double opacity) {
    if (!handle) return;
    handle->opacity = opacity < 0.0 ? 0.0 : (opacity > 1.0 ? 1.0 : opacity);
}

PORTABLE_API void krita_brush_set_spacing(KritaBrushContext* handle, double spacing) {
    if (!handle) return;
    handle->spacing = spacing < 0.0 ? 0.0 : (spacing > 5.0 ? 5.0 : spacing);
}

PORTABLE_API void krita_brush_set_smudge(KritaBrushContext* handle, double smudge) {
    if (!handle) return;
    handle->smudge = smudge < 0.0 ? 0.0 : (smudge > 1.0 ? 1.0 : smudge);
}

PORTABLE_API void krita_brush_set_flow(KritaBrushContext* handle, double flow) {
    if (!handle) return;
    handle->flow = flow < 0.0 ? 0.0 : (flow > 1.0 ? 1.0 : flow);
}

PORTABLE_API void krita_brush_set_hardness(KritaBrushContext* handle, double hardness) {
    if (!handle) return;
    handle->hardness = hardness < 0.0 ? 0.0 : (hardness > 1.0 ? 1.0 : hardness);
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
    handle->presetNameBuffer = handle->presetName;
    return handle->presetNameBuffer.c_str();
}

PORTABLE_API const char* krita_brush_get_paintop_id(KritaBrushContext* handle) {
    if (!handle) return "";
    return handle->paintopId.c_str();
}

// Paintop-settings param map enumeration (roadmap (f)) is a real-engine
// capability: the portable bridge keeps only the curated scalar getters,
// so the raw map is reported as empty (bindings degrade gracefully).
PORTABLE_API int32_t krita_brush_preset_param_count(KritaBrushContext* handle) {
    (void)handle;
    return 0;
}

PORTABLE_API const char* krita_brush_preset_param_name(KritaBrushContext* handle,
                                                       int32_t index) {
    (void)handle;
    (void)index;
    return nullptr;
}

PORTABLE_API const char* krita_brush_preset_param_value(KritaBrushContext* handle,
                                                        int32_t index) {
    (void)handle;
    (void)index;
    return nullptr;
}

// Live paintop-settings param editing (roadmap (f)) is a real-engine
// capability: the portable bridge has no param map to edit, so the
// setter always reports "not supported" (bindings treat false as the
// capability probe, same degrade contract as the param getters above).
PORTABLE_API int32_t krita_brush_set_param(KritaBrushContext* handle,
                                           const char* name,
                                           const char* value) {
    (void)handle;
    (void)name;
    (void)value;
    return 0;
}

PORTABLE_API bool krita_brush_generate_dab(KritaBrushContext* handle,
                                           const BrushInput* input,
                                           BrushDab* out_dab) {
    if (!handle || !input || !out_dab) return false;
    handle->clearError();

    out_dab->width = 0;
    out_dab->height = 0;
    out_dab->stride = 0;
    out_dab->reserved = 0;
    out_dab->pixels = nullptr;

    const double pressure = (input->pressure > 0.0 && input->pressure <= 1.0)
                                ? input->pressure
                                : 1.0;
    const bool eraser = (input->flags & kBrushInputEraser) || handle->eraser;

    // Effective radius scales with pressure (min 20% of size).
    const double effRadius = (handle->size * 0.5) * (0.2 + 0.8 * pressure);
    if (effRadius < 0.5) {
        handle->strokeStarted = true;
        return false;
    }

    int w = 0, h = 0, stride = 0;
    uint8_t* pixels = nullptr;
    if (!makeDab(effRadius, handle->hardness, pressure, handle->flow, handle->color, eraser,
                 &w, &h, &stride, &pixels)) {
        handle->setError("failed to render dab");
        return false;
    }

    out_dab->width = w;
    out_dab->height = h;
    out_dab->stride = stride;
    out_dab->reserved = 0;
    out_dab->pixels = pixels;
    handle->strokeStarted = true;
    return true;
}

PORTABLE_API void krita_brush_release_dab(KritaBrushContext* handle, BrushDab* dab) {
    (void)handle;
    if (dab && dab->pixels) {
        std::free(dab->pixels);
        dab->pixels = nullptr;
    }
}

PORTABLE_API void krita_brush_cleanup(KritaBrushContext* handle) {
    if (!handle) return;
    handle->strokeStarted = false;
}

PORTABLE_API const char* krita_brush_last_error(KritaBrushContext* handle) {
    if (!handle) return "";
    return handle->lastError.c_str();
}

PORTABLE_API const char* krita_brush_version(void) {
    return "FeatherBridge-Portable/1.0 (Krita-compatible, soft-round engine)";
}

// Sensor-curve access (milestone (i)) is a real-engine capability: the
// portable bridge has no param map to read or record curves into, so
// the getters/setter always report "not supported" (same capability
// probe / degrade contract as the param getters and set_param above).
PORTABLE_API const char* krita_brush_get_curve(KritaBrushContext* handle,
                                               const char* key) {
    (void)handle;
    (void)key;
    return nullptr;
}

PORTABLE_API int32_t krita_brush_set_curve(KritaBrushContext* handle,
                                           const char* key,
                                           const char* curve_xml) {
    (void)handle;
    (void)key;
    (void)curve_xml;
    return 0;
}

PORTABLE_API int32_t krita_brush_preset_count(KritaBrushContext* handle) {
    // Full Krita installation discovery is not available without Qt.
    (void)handle;
    return 0;
}

PORTABLE_API const char* krita_brush_preset_name(KritaBrushContext* handle,
                                                 int32_t index) {
    (void)index;
    if (!handle) return nullptr;
    return nullptr;
}

} // extern "C"
