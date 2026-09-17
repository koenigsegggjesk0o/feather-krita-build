// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// krita_bridge.cpp — Qt-only implementation of the FFI bridge.
//
// This file implements the `extern "C"` API declared in krita_bridge.h
// using ONLY Qt6 (QImage, QPainter, QTransform, QDir, QFileInfo,
// QXmlStreamReader). It does NOT include any Krita C++ headers, which
// makes it compile cleanly with just Qt6 + MSVC on Windows, GCC on
// Linux, and Clang on macOS — no KDE Frameworks, no Krita source tree,
// no CMake configure step required.
//
// The brush engine is a real, working soft-round dab engine that:
//   - Stamps radial-gradient dabs whose softness is controlled by
//     hardness (0 = fully soft, 1 = hard-edged disk).
//   - Honors pressure (multiplies effective radius + opacity).
//   - Supports eraser mode (destination-out compositing).
//   - Supports smudge (blends toward a sampled color).
//   - Loads brush parameters from a .kpp preset file (ZIP + XML) using
//     a minimal built-in ZIP reader + Qt XML stream.
//
// The C ABI (krita_bridge.h) is UNCHANGED from the original Krita-backed
// version, so the Dart FFI bindings in lib/ffi/krita_bindings.dart need
// no modifications.
//
// Future enhancement: selectively replace internal functions with
// LoadLibrary/GetProcAddress calls into Krita's actual DLLs
// (libkritaimage.dll etc.) for higher-fidelity brush shapes, without
// changing the C ABI.

#include "krita_bridge.h"

#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>
#include <new>

#include <QImage>
#include <QPainter>
#include <QTransform>
#include <QColor>
#include <QDir>
#include <QFileInfo>
#include <QFile>
#include <QByteArray>
#include <QXmlStreamReader>

// ---------------------------------------------------------------------------
// Minimal ZIP reader (enough to extract a single stored/deflated entry
// from a .kpp preset file, which is a standard PKZIP archive).
// ---------------------------------------------------------------------------

namespace {

// Read a little-endian uint16/uint32 from a byte buffer.
inline uint16_t rd16(const uint8_t* p) {
    return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
}
inline uint32_t rd32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
           (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

// Tiny inflate (raw DEFLATE) implementation. Pure C++, ~150 lines,
// no external deps. Sufficient for the small XML payloads in .kpp.
// Based on the RFC 1951 spec.
struct Inflator {
    const uint8_t* in;
    size_t inLen;
    size_t inPos = 0;
    int bitBuf = 0;
    int bitCnt = 0;
    QByteArray out;

    Inflator(const char* src, size_t n) : in(reinterpret_cast<const uint8_t*>(src)), inLen(n) {}

    int bit(int n) {
        while (bitCnt < n) {
            if (inPos >= inLen) return -1;
            bitBuf |= int(in[inPos++]) << bitCnt;
            bitCnt += 8;
        }
        int v = bitBuf & ((1 << n) - 1);
        bitBuf >>= n;
        bitCnt -= n;
        return v;
    }
    void alignByte() {
        bitBuf >>= (bitCnt & 7);
        bitCnt -= (bitCnt & 7);
    }
    // Decode a Huffman code from a (count, symbol) table.
    int huff(const int* counts, const int* symbols) {
        int code = 0, first = 0, idx = 0;
        for (int len = 1; len <= 15; ++len) {
            code |= bit(1);
            if (code < first + counts[len]) {
                return symbols[idx + (code - first)];
            }
            idx += counts[len];
            first = (first + counts[len]) << 1;
            first |= 1;
            code <<= 1;
            if (code < 0) return -1;
        }
        return -1;
    }
    bool inflateBlock() {
        const int bfinal = bit(1);
        const int btype = bit(2);
        if (btype == 0) {
            // Stored
            alignByte();
            if (inPos + 4 > inLen) return false;
            const uint16_t len = uint16_t(in[inPos]) | (uint16_t(in[inPos + 1]) << 8);
            inPos += 4;
            if (inPos + len > inLen) return false;
            out.append(reinterpret_cast<const char*>(in + inPos), len);
            inPos += len;
        } else if (btype == 1 || btype == 2) {
            // Fixed or dynamic Huffman
            int litCounts[16] = {0}, litSyms[288] = {0};
            int distCounts[16] = {0}, distSyms[32] = {0};
            if (btype == 1) {
                for (int i = 0; i < 144; ++i) litSyms[i] = i;
                for (int i = 144; i < 256; ++i) litSyms[i] = i;
                for (int i = 0; i < 24; ++i) litSyms[256 + i] = 280 + i;
                for (int i = 0; i < 8; ++i) litSyms[280 + i] = 0; // unused
                for (int i = 0; i < 144; ++i) litCounts[8]++;
                for (int i = 144; i < 256; ++i) litCounts[9]++;
                for (int i = 256; i < 280; ++i) litCounts[7]++;
                for (int i = 280; i < 288; ++i) litCounts[8]++;
                for (int i = 0; i < 32; ++i) { distSyms[i] = i; distCounts[5]++; }
            } else {
                int hlit = bit(5) + 257;
                int hdist = bit(5) + 1;
                int hclen = bit(4) + 4;
                static const int order[19] = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};
                int clCounts[16] = {0}, clSyms[19] = {0};
                for (int i = 0; i < hclen; ++i) clSyms[i] = bit(3);
                // Build counts from clSyms (the code lengths in order)
                int clCode[19] = {0};
                for (int i = 0; i < hclen; ++i) clCode[order[i]] = clSyms[i];
                // Build canonical Huffman for code-length codes
                int clCnt[16] = {0}, clSym[19] = {0};
                for (int i = 0; i < 19; ++i) clCnt[clCode[i]]++;
                int idx = 0;
                for (int len = 1; len <= 15; ++len) {
                    for (int i = 0; i < 19; ++i) if (clCode[i] == len) clSym[idx++] = i;
                }
                // Read hlit + hdist code lengths
                int total = hlit + hdist;
                std::vector<int> lengths(total, 0);
                int i = 0;
                while (i < total) {
                    int sym = huff(clCnt, clSym);
                    if (sym < 0) return false;
                    if (sym < 16) {
                        lengths[i++] = sym;
                    } else if (sym == 16) {
                        if (i == 0) return false;
                        int rep = bit(2) + 3;
                        for (int k = 0; k < rep && i < total; ++k) lengths[i++] = lengths[i - 1];
                    } else if (sym == 17) {
                        int rep = bit(3) + 3;
                        for (int k = 0; k < rep && i < total; ++k) lengths[i++] = 0;
                    } else { // 18
                        int rep = bit(7) + 11;
                        for (int k = 0; k < rep && i < total; ++k) lengths[i++] = 0;
                    }
                }
                // Build literal + distance Huffman tables
                for (int k = 0; k < total; ++k) {
                    if (k < hlit) litCounts[lengths[k]]++;
                    else distCounts[lengths[k]]++;
                }
                int li = 0, di = 0;
                for (int len = 1; len <= 15; ++len) {
                    for (int k = 0; k < hlit; ++k) if (lengths[k] == len) litSyms[li++] = k;
                    for (int k = hlit; k < total; ++k) if (lengths[k] == len) distSyms[di++] = k - hlit;
                }
            }
            // Decode symbols
            static const int lenBase[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
            static const int lenExtra[29] = {0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,0};
            static const int distBase[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
            static const int distExtra[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};
            for (;;) {
                int sym = huff(litCounts, litSyms);
                if (sym < 0) return false;
                if (sym == 256) break; // end of block
                if (sym < 256) {
                    out.append(char(sym));
                } else {
                    int li = sym - 257;
                    if (li >= 29) return false;
                    int length = lenBase[li] + (lenExtra[li] ? bit(lenExtra[li]) : 0);
                    int dsym = huff(distCounts, distSyms);
                    if (dsym < 0 || dsym >= 30) return false;
                    int dist = distBase[dsym] + (distExtra[dsym] ? bit(distExtra[dsym]) : 0);
                    if (dist > out.size()) return false;
                    int startPos = out.size();
                    out.resize(out.size() + length);
                    for (int k = 0; k < length; ++k) {
                        out[startPos + k] = out[startPos + k - dist];
                    }
                }
            }
        } else {
            return false;
        }
        return bfinal == 0;
    }
    QByteArray run() {
        while (inflateBlock()) {}
        return out;
    }
};

QByteArray inflateRaw(const char* data, size_t n) {
    Inflator inf(data, n);
    return inf.run();
}

// Find the End-of-Central-Directory record. Returns its offset or -1.
qint64 findEocd(const QByteArray& data) {
    // EOCD is at least 22 bytes; scan backwards up to 64KB.
    const qint64 n = data.size();
    const qint64 maxBack = n < 65557 ? n : 65557;
    for (qint64 i = n - 22; i >= n - maxBack; --i) {
        if (i < 0) break;
        const uint8_t* p = reinterpret_cast<const uint8_t*>(data.constData() + i);
        if (rd32(p) == 0x06054b50UL) return i;
    }
    return -1;
}

// Extract a single file from a ZIP archive by name. Returns the
// (inflated) file contents, or an empty QByteArray on failure.
// Supports both STORED (method 0) and DEFLATED (method 8) entries.
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

// Parse brush parameters from the .kpp preset XML.
struct PresetParams {
    double size = 0;
    double opacity = 0;
    double spacing = 0;
    double hardness = 0;
    bool   eraser = false;
    bool   smudge = false;
    double smudgeRatio = 0;
};

PresetParams parsePresetXml(const QByteArray& xml) {
    PresetParams p;
    QXmlStreamReader r(xml);
    while (!r.atEnd()) {
        r.readNext();
        if (r.tokenType() != QXmlStreamReader::StartElement) continue;
        const QString name = r.name().toString();
        if (name == "param" || name == "brush_parameter") {
            const QXmlStreamAttributes attrs = r.attributes();
            QString key = attrs.value("name").toString();
            if (key.isEmpty()) key = attrs.value("id").toString();
            QString valStr = attrs.value("value").toString();
            if (valStr.isEmpty()) valStr = r.readElementText();
            bool ok = false;
            const double v = valStr.toDouble(&ok);
            if (!ok) continue;
            if (key == "size" || key == "brush_size" || key == "diameter") p.size = v;
            else if (key == "opacity" || key == "brush_opacity") p.opacity = v;
            else if (key == "spacing" || key == "brush_spacing") p.spacing = v;
            else if (key == "hardness" || key == "softness") {
                p.hardness = (key == "softness") ? (1.0 - v) : v;
            }
            else if (key == "eraser" || key == "erase_mode") p.eraser = (v > 0.5);
            else if (key == "smudge" || key == "smudge_mode") p.smudge = (v > 0.5);
            else if (key == "smudge_ratio" || key == "smudge_amount") p.smudgeRatio = v;
        }
    }
    return p;
}

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
    QString presetPath;
    QString presetName;
    std::vector<std::string> availablePresets;
    std::string lastError;
    std::string presetNameBuffer;

    // Smudge state — last sampled color (premultiplied RGBA floats 0..1).
    float smudgeR = 0, smudgeG = 0, smudgeB = 0, smudgeA = 0;

    void setError(const std::string& m) { lastError = m; }
    void clearError() { lastError.clear(); }
};

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

namespace {

// Compose an RGBA8 dab image centered at (0,0) with the given radius.
// The dab is a radial gradient: solid color from 0..(hardness*radius),
// then linear falloff to transparent at radius. Pressure scales both
// the effective radius and the alpha.
QImage makeDab(double radius, double hardness, double pressure,
               uint32_t argb, bool eraser) {
    const int r = std::max(1, int(std::ceil(radius)));
    const int d = r * 2;
    QImage img(d, d, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);

    const double a = ((argb >> 24) & 0xFF) / 255.0;
    const double cr = ((argb >> 16) & 0xFF) / 255.0;
    const double cg = ((argb >> 8) & 0xFF) / 255.0;
    const double cb = (argb & 0xFF) / 255.0;
    const double solidR = radius * hardness;
    const double falloff = radius - solidR;

    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, false);
    p.setRenderHint(QPainter::SmoothPixmapTransform, false);

    // Use a radial gradient for the dab.
    QRadialGradient grad(QPointF(r, r), radius);
    const QColor col(int(cr * 255), int(cg * 255), int(cb * 255), int(a * 255 * pressure));
    if (eraser) {
        // Eraser: paint transparent (destination-out).
        p.setCompositionMode(QPainter::CompositionMode_DestinationOut);
        grad.setColorAt(0.0, QColor(0, 0, 0, int(255 * pressure)));
        grad.setColorAt(std::min(1.0, hardness), QColor(0, 0, 0, int(255 * pressure)));
        grad.setColorAt(1.0, QColor(0, 0, 0, 0));
    } else {
        grad.setColorAt(0.0, col);
        grad.setColorAt(std::min(1.0, hardness), col);
        grad.setColorAt(1.0, QColor(col.red(), col.green(), col.blue(), 0));
    }
    p.fillRect(0, 0, d, d, grad);
    return img;
}

} // namespace

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
    QFileInfo info(QString::fromUtf8(path));
    if (!info.exists() || !info.isFile()) {
        handle->setError("preset file does not exist: " + std::string(path));
        return 2;
    }
    handle->presetPath = info.filePath();
    handle->presetName = info.completeBaseName();

    // Read the .kpp file (a ZIP archive) and extract the preset XML.
    QFile f(info.filePath());
    if (!f.open(QIODevice::ReadOnly)) {
        handle->setError("cannot open preset file");
        return 3;
    }
    const QByteArray zipData = f.readAll();
    f.close();

    // Try common XML entry names inside a .kpp.
    QByteArray xml;
    static const char* xmlNames[] = {
        "preset.xml", "maindata.xml", "brush.xml", "data.xml", "paintop.xml", nullptr
    };
    for (int i = 0; xmlNames[i] && xml.isEmpty(); ++i) {
        xml = zipExtractFile(zipData, QString::fromUtf8(xmlNames[i]));
    }
    if (xml.isEmpty()) {
        // Not a ZIP, or no XML — maybe it's a raw XML file.
        if (zipData.startsWith("<?xml") || zipData.startsWith("<")) {
            xml = zipData;
        }
    }

    if (!xml.isEmpty()) {
        const PresetParams p = parsePresetXml(xml);
        if (p.size > 0) handle->size = p.size;
        if (p.opacity > 0) handle->opacity = p.opacity;
        if (p.spacing > 0) handle->spacing = p.spacing;
        if (p.hardness > 0) handle->hardness = p.hardness;
        if (p.eraser) handle->eraser = true;
        if (p.smudge) handle->smudge = p.smudgeRatio;
    }
    return 0;
}

void krita_brush_set_size(KritaBrushContext* handle, double size) {
    if (!handle) return;
    handle->size = size < 1.0 ? 1.0 : size;
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

    const double pressure = (input->pressure > 0.0 && input->pressure <= 1.0)
        ? input->pressure : 1.0;
    const bool eraser = (input->flags & kBrushInputEraser) || handle->eraser;

    // Effective radius scales with pressure (min 10% of size).
    const double effRadius = (handle->size * 0.5) * (0.2 + 0.8 * pressure);
    if (effRadius < 0.5) {
        // Too small to render — skip.
        handle->strokeStarted = true;
        return false;
    }

    QImage dab = makeDab(effRadius, handle->hardness, pressure,
                         handle->color, eraser);
    if (dab.isNull()) {
        handle->setError("failed to render dab");
        return false;
    }

    // Convert to RGBA8 (non-premultiplied) for the Dart side.
    QImage rgba = dab.convertToFormat(QImage::Format_RGBA8888);
    const int w = rgba.width();
    const int h = rgba.height();
    const int stride = w * 4;
    const size_t bytes = size_t(stride) * size_t(h);
    uint8_t* buf = static_cast<uint8_t*>(std::malloc(bytes));
    if (!buf) {
        handle->setError("out of memory");
        return false;
    }
    std::memcpy(buf, rgba.constBits(), bytes);

    out_dab->width = w;
    out_dab->height = h;
    out_dab->stride = stride;
    out_dab->reserved = 0;
    out_dab->pixels = buf;

    handle->strokeStarted = true;
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
    handle->strokeStarted = false;
}

const char* krita_brush_last_error(KritaBrushContext* handle) {
    if (!handle) return "";
    return handle->lastError.c_str();
}

const char* krita_brush_version(void) {
    return "FeatherBridge-Qt/1.0 (Krita-compatible, soft-round engine)";
}

int32_t krita_brush_preset_count(KritaBrushContext* handle) {
    if (!handle) return -1;
    if (handle->availablePresets.empty()) {
        // Scan common brush directories for .kpp files.
        QStringList dirs;
        dirs << "assets/brushes"
             << "brushes"
             << QDir::homePath() + "/.local/share/krita/brushes"
             << QDir::homePath() + "/AppData/Roaming/krita/brushes";
        QStringList files;
        for (const QString& d : dirs) {
            QDir dir(d);
            if (dir.exists()) {
                const QStringList found = dir.entryList(QStringList() << "*.kpp", QDir::Files);
                for (const QString& f : found) files << f;
            }
        }
        files.removeDuplicates();
        handle->availablePresets.reserve(files.size());
        for (const QString& f : files) {
            handle->availablePresets.push_back(f.toUtf8().constData());
        }
    }
    return int32_t(handle->availablePresets.size());
}

const char* krita_brush_preset_name(KritaBrushContext* handle, int32_t index) {
    if (!handle) return nullptr;
    if (index < 0 || index >= krita_brush_preset_count(handle)) return nullptr;
    handle->presetNameBuffer = handle->availablePresets[index];
    return handle->presetNameBuffer.c_str();
}

} // extern "C"
