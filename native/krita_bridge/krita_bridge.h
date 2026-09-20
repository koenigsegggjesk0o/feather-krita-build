// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// krita_bridge.h — C ABI bridge between Flutter (Dart FFI) and the Krita
// C++ brush engine.
//
// This header defines an opaque brush handle and a small set of `extern
// "C"` functions that Flutter calls via `dart:ffi`. The matching Dart
// bindings live in `lib/ffi/krita_bindings.dart`.
//
// The C++ implementation (`krita_bridge.cpp`) calls Krita's public API
// (KisBrush, KisPaintOp, KisBrushOption etc.) WITHOUT modifying any
// Krita source code.

#ifndef FEATHER_KRITA_BRIDGE_H
#define FEATHER_KRITA_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// ---------------------------------------------------------------------------
// Export macros. On Windows the functions must be marked with
// __declspec(dllexport) or they will not appear in the DLL's export table;
// on Linux/macOS default visibility is already exported.
// ---------------------------------------------------------------------------
#if defined(_WIN32) || defined(__CYGWIN__)
  #define KRITA_BRIDGE_API __declspec(dllexport)
#else
  #define KRITA_BRIDGE_API __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------------------
// Opaque handle.
// ---------------------------------------------------------------------------

/// Opaque handle to a Krita brush instance. The actual C++ type is
/// `KritaBrushContext` defined in the .cpp file; the C side only sees it
/// as an opaque pointer.
typedef struct KritaBrushContext KritaBrushContext;

// ---------------------------------------------------------------------------
// Input / output structs. These layouts MUST match the Dart `Struct`
// definitions in `lib/ffi/krita_bindings.dart`.
// ---------------------------------------------------------------------------

/// One brush input sample.
///
/// Layout: 6 doubles + 2 floats + 2 int32 = 64 bytes (with 8-byte
/// alignment the struct naturally pads to 72 bytes; the trailing
/// `_padding` field is reserved).
typedef struct BrushInput {
    /// X position in device-independent pixels relative to the dab origin.
    double x;
    /// Y position in device-independent pixels relative to the dab origin.
    double y;
    /// Normalized stylus pressure in [0, 1].
    double pressure;
    /// X tilt in degrees, range [-90, 90].
    double tilt_x;
    /// Y tilt in degrees, range [-90, 90].
    double tilt_y;
    /// Time in seconds since stroke start.
    double time;
    /// Velocity along X axis (px/s).
    float  velocity_x;
    /// Velocity along Y axis (px/s).
    float  velocity_y;
    /// Bitfield of [BrushInputFlags].
    int32_t flags;
    /// Reserved for alignment / future use.
    int32_t _padding;
} BrushInput;

/// Bit flags packed inside [BrushInput::flags].
enum BrushInputFlags {
    kBrushInputNone     = 0,
    kBrushInputEraser   = 1 << 0,
    kBrushInputSmudge   = 1 << 1,
    kBrushInputMirrorX  = 1 << 2,
    kBrushInputMirrorY  = 1 << 3,
    kBrushInputInverted = 1 << 4,
};

/// A generated dab image (RGBA8 premultiplied).
///
/// The pixel buffer is owned by the bridge and must be released with
/// [krita_brush_release_dab] after the caller has copied the data out.
typedef struct BrushDab {
    /// Width of the dab image in pixels.
    int32_t width;
    /// Height of the dab image in pixels.
    int32_t height;
    /// Number of bytes per row (== width * 4 for RGBA8). May be 0 in
    /// which case callers should compute width * 4.
    int32_t stride;
    /// Reserved for alignment / future use.
    int32_t reserved;
    /// Pointer to width * height * 4 bytes of RGBA8 pixel data, or NULL
    /// when [width] or [height] are 0.
    uint8_t* pixels;
} BrushDab;

// ---------------------------------------------------------------------------
// Brush lifecycle.
// ---------------------------------------------------------------------------

/// Allocates a new brush context. The returned handle must be released
/// with [krita_brush_destroy] to avoid leaking native memory.
///
/// Returns NULL if allocation fails.
KRITA_BRIDGE_API KritaBrushContext* krita_brush_init(void);

/// Releases all resources held by [handle] and frees the handle itself.
/// After this call [handle] is invalid.
KRITA_BRIDGE_API void krita_brush_destroy(KritaBrushContext* handle);

// ---------------------------------------------------------------------------
// Brush configuration.
// ---------------------------------------------------------------------------

/// Loads a Krita brush preset (.kpp file) from [path]. Returns 0 on
/// success, non-zero on failure (use [krita_brush_last_error] for
/// details).
KRITA_BRIDGE_API int32_t krita_brush_load_preset(KritaBrushContext* handle, const char* path);

/// Sets the brush diameter in pixels.
KRITA_BRIDGE_API void krita_brush_set_size(KritaBrushContext* handle, double size);

/// Sets the brush color as a packed ARGB value (0xAARRGGBB).
KRITA_BRIDGE_API void krita_brush_set_color(KritaBrushContext* handle, uint32_t argb);

/// Sets the brush flow / opacity in [0, 1].
KRITA_BRIDGE_API void krita_brush_set_opacity(KritaBrushContext* handle, double opacity);

/// Sets the dab spacing in [0, 5] (fraction of brush diameter).
KRITA_BRIDGE_API void krita_brush_set_spacing(KritaBrushContext* handle, double spacing);

/// Sets the smudge ratio in [0, 1].
KRITA_BRIDGE_API void krita_brush_set_smudge(KritaBrushContext* handle, double smudge);

/// Sets the brush flow (per-dab application rate) in [0, 1]. Flow < 1
/// scales each dab's alpha so paint builds up gradually over multiple
/// stamps (semantically the paintop FlowValue sensor base). Default 1.0
/// = full application per dab. Applied alongside pressure in
/// [krita_brush_generate_dab]; opacity is the master multiplier left to
/// the host compositor (KisPainter layer in desktop Krita).
/// Added by the flow/hardness ABI campaign; back-compat: new function.
KRITA_BRIDGE_API void krita_brush_set_flow(KritaBrushContext* handle, double flow);

/// Sets the brush hardness in [0, 1] (0 = fully soft gaussian falloff,
/// 1 = hard-edged disk). For auto brushes this rebuilds the mask
/// generator's fade (1 - hardness); for preset-loaded brushes the tip is
/// rebuilt as a real KisAutoBrush from the current diameter + new fade
/// (an explicit hardness override supersedes the preset tip, mirroring
/// the loop-37 self-heal path). Added by the flow/hardness ABI campaign.
KRITA_BRIDGE_API void krita_brush_set_hardness(KritaBrushContext* handle, double hardness);

// ---------------------------------------------------------------------------
// Parameter getters — let the app reflect loaded preset values into its UI.
// ---------------------------------------------------------------------------
KRITA_BRIDGE_API double krita_brush_get_size(KritaBrushContext* handle);
KRITA_BRIDGE_API double krita_brush_get_opacity(KritaBrushContext* handle);
KRITA_BRIDGE_API double krita_brush_get_spacing(KritaBrushContext* handle);
KRITA_BRIDGE_API double krita_brush_get_hardness(KritaBrushContext* handle);
KRITA_BRIDGE_API double krita_brush_get_smudge(KritaBrushContext* handle);
/// Returns the current flow in [0, 1] (default 1.0). Reflects either a
/// [krita_brush_set_flow] call or a preset's FlowValue sensor base.
/// Added by the flow/hardness ABI campaign; back-compat: new function.
KRITA_BRIDGE_API double krita_brush_get_flow(KritaBrushContext* handle);
/// True when the loaded preset is an eraser preset (settings-level
/// Krita/erase, EraserMode or CompositeOp=erase). Callers should switch
/// their stroke compositing to destination-out. Added by roadmap (f);
/// back-compat: new function, no struct layout change.
KRITA_BRIDGE_API bool krita_brush_get_eraser(KritaBrushContext* handle);
KRITA_BRIDGE_API const char* krita_brush_get_preset_name(KritaBrushContext* handle);

// ---------------------------------------------------------------------------
// Dab generation.
// ---------------------------------------------------------------------------

/// Generates a single dab image for the given [input] and writes the
/// result into [out_dab]. The dab's pixel buffer is owned by the bridge
/// and must be released with [krita_brush_release_dab].
///
/// Returns `true` if a dab was generated (caller should inspect
/// [out_dab] and copy the data out before releasing), `false` if no
/// dab was produced (e.g. zero pressure and skip-on-zero enabled).
KRITA_BRIDGE_API bool krita_brush_generate_dab(KritaBrushContext* handle,
                              const BrushInput* input,
                              BrushDab* out_dab);

/// Releases the pixel buffer of [dab]. Safe to call with a dab whose
/// pixels pointer is NULL.
KRITA_BRIDGE_API void krita_brush_release_dab(KritaBrushContext* handle, BrushDab* dab);

/// Resets the brush's internal stroke state. Call between strokes so the
/// next dab is treated as the start of a fresh stroke.
KRITA_BRIDGE_API void krita_brush_cleanup(KritaBrushContext* handle);

/// Returns a pointer to a UTF-8 string describing the most recent error,
/// or an empty string if there is none. The pointer is owned by the
/// bridge and remains valid until the next call on [handle].
KRITA_BRIDGE_API const char* krita_brush_last_error(KritaBrushContext* handle);

// ---------------------------------------------------------------------------
// Optional helpers for engine integration.
// ---------------------------------------------------------------------------

/// Returns the Krita version string (e.g. "5.2.0"). The pointer is
/// static and valid for the lifetime of the bridge library.
KRITA_BRIDGE_API const char* krita_brush_version(void);

/// Returns the number of brush presets bundled with the loaded Krita
/// installation, or -1 if Krita is not available.
KRITA_BRIDGE_API int32_t krita_brush_preset_count(KritaBrushContext* handle);

/// Returns the name of the preset at [index], or NULL if out of range.
/// The returned pointer is owned by the handle and invalidated by the
/// next call on [handle].
KRITA_BRIDGE_API const char* krita_brush_preset_name(KritaBrushContext* handle, int32_t index);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // FEATHER_KRITA_BRIDGE_H
