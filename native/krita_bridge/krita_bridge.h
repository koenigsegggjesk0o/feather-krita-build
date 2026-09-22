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
/// Returns the loaded preset's declared paintop family (the root
/// `<Preset paintopid="...">` / `<Paintop id="...">` attribute —
/// "paintbrush", "eraser", "spray", ...). Empty string when no preset is
/// loaded or the preset omits the attribute. The pointer stays valid
/// until the next [krita_brush_load_preset] call or handle disposal;
/// copy it if it must outlive those. Lets the UI show which family a
/// preset belongs to and gate per-paintop options (e.g. Krita only
/// offers hardness to auto-brush paintops). Added by the paintop
/// identity campaign; back-compat: new function, no struct layout change.
KRITA_BRIDGE_API const char* krita_brush_get_paintop_id(KritaBrushContext* handle);

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

/// Returns the number of brush presets found by the last
/// [krita_brush_preset_scan] on [handle] (0 before the first scan), or
/// -1 if the handle is NULL.
KRITA_BRIDGE_API int32_t krita_brush_preset_count(KritaBrushContext* handle);

/// Returns the name of the preset at [index], or NULL if out of range.
/// The returned pointer is owned by the handle and invalidated by the
/// next call on [handle].
KRITA_BRIDGE_API const char* krita_brush_preset_name(KritaBrushContext* handle, int32_t index);

/// Scans [dir] RECURSIVELY for Krita brush preset containers (*.kpp) and
/// parses each file through the engine's own container path (ZIP KoStore
/// containers, legacy PNG zTXt presets, bare XML shapes — the exact
/// extraction krita_brush_load_preset uses), recording per preset the
/// display name and the declared paintop family (root
/// `<Preset paintopid="...">` / `<Paintop id="...">`). The scan result is
/// memoized on [handle] and read by krita_brush_preset_count /
/// krita_brush_preset_name / krita_brush_preset_family /
/// krita_brush_preset_path; a new scan call replaces the previous result.
/// Unparsable files are skipped (robust directory scan) and do not fail
/// the scan. Returns the number of presets found (>= 0), or negative on
/// bad arguments (-1) / missing directory (-2).
/// Added by the preset-families campaign; back-compat: new function.
KRITA_BRIDGE_API int32_t krita_brush_preset_scan(KritaBrushContext* handle, const char* dir);

/// Returns the paintop family ("paintbrush", "eraser", "spray", ...) of
/// the preset at [index] from the last krita_brush_preset_scan, or NULL
/// if out of range. The pointer is owned by the handle and invalidated
/// by the next scan call on [handle]; copy it if it must outlive those.
/// Added by the preset-families campaign; back-compat: new function.
KRITA_BRIDGE_API const char* krita_brush_preset_family(KritaBrushContext* handle, int32_t index);

/// Returns the absolute file path of the preset at [index] from the last
/// krita_brush_preset_scan (feed it straight into
/// [krita_brush_load_preset]), or NULL if out of range. Same pointer
/// lifetime rules as [krita_brush_preset_family].
/// Added by the preset-families campaign; back-compat: new function.
KRITA_BRIDGE_API const char* krita_brush_preset_path(KritaBrushContext* handle, int32_t index);

/// Returns the number of paintop-settings-level parameters captured from
/// the LAST successfully loaded preset (krita_brush_load_preset): every
/// `<param name|id="...">` entry in the preset XML with its value (a
/// value= attribute or the element's text/CDATA), in document order.
/// Real Krita stock presets expose their full settings surface here
/// (Krita/opacity, CompositeOp, FlowValue, brush_definition, ...).
/// Returns 0 before the first load, after a failed load, or on the
/// fallback/portable bridges (raw map enumeration is a real-engine
/// capability; curated values remain available through the scalar
/// getters). Added by the paintop-settings-params campaign (roadmap (f));
/// back-compat: new function, no struct layout change.
KRITA_BRIDGE_API int32_t krita_brush_preset_param_count(KritaBrushContext* handle);

/// Returns the parameter NAME at [index] (document order) from the last
/// successfully loaded preset, or NULL if out of range. The pointer is
/// owned by the handle and invalidated by the next load_preset call or
/// the next param-name call on [handle]; copy it if it must outlive
/// those. Added by the paintop-settings-params campaign; back-compat:
/// new function.
KRITA_BRIDGE_API const char* krita_brush_preset_param_name(KritaBrushContext* handle, int32_t index);

/// Returns the parameter VALUE at [index] (document order) from the last
/// successfully loaded preset, or NULL if out of range. Values are the
/// raw settings strings (e.g. "100" for Krita/opacity, "erase" for
/// CompositeOp, full `<Brush ...>` XML for brush_definition). Same
/// pointer lifetime rules as [krita_brush_preset_param_name], with its
/// own buffer. Added by the paintop-settings-params campaign;
/// back-compat: new function.
KRITA_BRIDGE_API const char* krita_brush_preset_param_value(KritaBrushContext* handle, int32_t index);

/// Sets a paintop-settings-level parameter of the last successfully
/// loaded preset by NAME (roadmap (f) live param editing). The
/// (name, value) pair first updates the engine's param map of record
/// (immediately visible through krita_brush_preset_param_count / _name /
/// _value), then — for keys the engine actually consumes — is applied to
/// the live brush state, mirroring the load_preset consumption exactly:
///   Krita/opacity (0-100) | OpacityValue | opacity | brush_opacity
///       (0-1)                                      -> master opacity
///   FlowValue | flow (0-1)                         -> per-dab flow
///   hardness (0-1) | SoftnessValue | softness (0-1, complement)
///       -> tip fade (rebuilds the auto brush, superseding a
///       preset-loaded brush exactly like krita_brush_set_hardness)
///   brush_spacing (0-5]                            -> dab spacing
///   SmudgeRateValue | smudge_rate | smudge (0-1)   -> smudge rate
///   Krita/erase | EraserMode | eraser ("true"/"1") or
///       CompositeOp ("erase")                      -> eraser flag
/// Unknown names still update the map and return 1: the settings-level
/// value is recorded, the wrapper's dab model simply has no dimension
/// for it (the inspector shows the recorded value). Returns 0 on null
/// arguments, an empty name, or when no preset was loaded. The portable
/// and fallback bridges return 0 unconditionally (capability probe:
/// bindings treat false as "live param editing not supported on this
/// bridge"). Back-compat: new function, no struct layout change.
KRITA_BRIDGE_API int32_t krita_brush_set_param(KritaBrushContext* handle,
                                               const char* name,
                                               const char* value);

/// Returns the raw sensor-curve XML value of the param-map entry [key]
/// from the LAST successfully loaded preset (krita_brush_load_preset),
/// or NULL when the key is absent / arguments are bad / no preset was
/// loaded. Sensor curves are the v6.0.4 paintop-settings entries named
/// "<CurveOption>Sensor" (e.g. "OpacitySensor", "FlowSensor",
/// "SizeSensor"): their values are dynamic-sensor params XML —
/// `<!DOCTYPE params> <params id="pressure"> <curve>0,0;1,1;</curve>
/// </params>` — a semicolon-separated x,y point list in [0,1]^2 (the
/// engine's own KisDynamicSensorData serialization). Stock presets carry
/// them exactly when the option declares a curve (basic-5 ships
/// OpacitySensor/FlowSensor/SizeSensor/... with a real FlowSensor curve;
/// stock_eraser_circle ships none). The curve use flags
/// (<Id>UseCurve / <Id>UseSameCurve / <Id>curveMode) stay plain map
/// entries editable through krita_brush_set_param. The pointer is owned
/// by the handle and invalidated by the next load_preset or curve/param
/// call on [handle]; copy it if it must outlive those. Added by the
/// sensor-curve campaign (milestone (i)); back-compat: new function, no
/// struct layout change. The portable/fallback bridges return NULL
/// unconditionally (capability probe).
KRITA_BRIDGE_API const char* krita_brush_get_curve(KritaBrushContext* handle,
                                                   const char* key);

/// Validates + records a sensor-curve entry (milestone (i) curve
/// editing). [curve_xml] must be the dynamic-sensor params XML: after an
/// optional XML prolog/DOCTYPE, the root element must be <params> with a
/// non-empty id attribute and exactly one <curve> child whose text
/// parses as semicolon-separated "x,y;" float pairs (>= 2 points, both
/// axes in [0,1]) — the engine's own KisDynamicSensorData shape. On
/// success the (key, value) pair replaces the existing entry or appends
/// at the end of the map of record (same policy as
/// krita_brush_set_param) and is immediately visible through
/// krita_brush_get_curve / preset_param_count/_name/_value. Curves
/// modulate dab output at the paintop-strategy level: the wrapper
/// records them (the settings-level of record, like unknown set_param
/// keys) and the host applies the curve evaluation — no live dab-model
/// effect is claimed. Returns 1 when recorded (replace OR append), 0 on
/// null/empty arguments or no loaded preset, -1 when validation rejects
/// the XML (the map is untouched). The portable and fallback bridges
/// return 0 unconditionally (capability probe). Back-compat: new
/// function, no struct layout change.
KRITA_BRIDGE_API int32_t krita_brush_set_curve(KritaBrushContext* handle,
                                               const char* key,
                                               const char* curve_xml);

// ---------------------------------------------------------------------------
// Stroke session ABI — "Feather-3D" campaign, phase F1.
//
// ABI v1 renders dabs through the AUTO-BRUSH mask path only; the session
// exports below run a REAL STROKE through Krita's own paintop pipeline:
// the preset (loaded via krita_brush_load_preset) is dispatched through
// KisPaintOpRegistry — the exact dispatcher desktop Krita uses — onto a
// texture-sized RGBA8 KisPaintDevice owned by the bridge. The host
// (Feather-3D) uploads the current surface texture, streams stroke
// events in UV space, and reads back only the dirty region.
//
// Lifecycle: krita_stroke_begin (creates the device + painter + the
// registry-dispatched paintop) -> krita_stroke_upload* ->
// krita_stroke_move* -> krita_stroke_dirty_rect / krita_stroke_readback*
// -> krita_stroke_end. A second krita_stroke_begin ends the active
// session first. The v1 exports remain valid at any time; the session
// keeps its own engine objects.
//
// Capability probe contract (same as the curve ABI): the portable and
// fallback bridges return 0 / NULL / empty from every session export
// (no session state exists there); the Dart bindings treat those values
// as "stroke session not supported on this bridge" and keep the v1
// dab-compositing path. Back-compat: new functions only, no struct
// layout change.
// ---------------------------------------------------------------------------

/// Starts a stroke session on a [tex_w] x [tex_h] RGBA8 texture canvas,
/// dispatching the CURRENTLY loaded preset (krita_brush_load_preset)
/// through the engine's own KisPaintOpRegistry. The registry is
/// populated headless with the same factories the paintop plugins
/// register on desktop (mypaint excluded: it needs the external
/// libmypaint dependency): paintbrush, duplicate, colorsmudge,
/// curvebrush, deformbrush, experimentbrush, spraybrush, filter,
/// gridbrush, hairybrush, hatchingbrush, particlebrush, roundmarker,
/// sketchbrush, tangentnormal. Returns 0 on success; -1 on null handle
/// or non-positive dimensions; -2 when no preset was loaded yet; -3
/// when the engine rejects the preset (unknown family / unparsable
/// container); -4 on internal setup failure (see
/// krita_brush_last_error). Added by phase F1; back-compat: new
/// function.
KRITA_BRIDGE_API int32_t krita_stroke_begin(KritaBrushContext* handle,
                                            int32_t tex_w, int32_t tex_h);

/// Uploads an RGBA8 (straight alpha, R,G,B,A byte order) block of the
/// current texture INTO the session's paint device (KisPaintDevice::
/// writeBytes) so canvas-sampling engines (colorsmudge, deform,
/// filterop, duplicate) read real pixels. The rectangle is clipped to
/// the texture; coordinates are texel-space. Returns 1 on success, 0 on
/// a null/inactive session or bad arguments. Added by phase F1.
KRITA_BRIDGE_API int32_t krita_stroke_upload(KritaBrushContext* handle,
                                             const uint8_t* rgba,
                                             int32_t x, int32_t y,
                                             int32_t w, int32_t h);

/// Streams one stroke event through the engine's own paint pipeline
/// (KisPainter::paintAt for the first event, KisPainter::paintLine for
/// subsequent ones — the spacing/interpolation is the engine's own).
/// [u]/[v] are normalized texture coordinates in [0,1] (UV space; the
/// bridge maps them to texels), [pressure] in [0,1] (out-of-range
/// values fall back to 1.0, same policy as the dab ABI), [tilt_x]/
/// [tilt_y] in degrees (passed through as tool-level tilt, see
/// KisPaintInformation), [time_s] seconds since stroke start. The
/// brush color is the context color (krita_brush_set_color); the
/// composite op comes from the preset's own settings (CompositeOp,
/// e.g. erase for eraser presets — the engine composites, not the
/// host). Returns 1 when a stroke event ran, 0 on a null/inactive
/// session. Added by phase F1.
KRITA_BRIDGE_API int32_t krita_stroke_move(KritaBrushContext* handle,
                                           double u, double v,
                                           double pressure,
                                           double tilt_x, double tilt_y,
                                           double time_s);

/// Reports the union of the engine-reported dirty rects since the
/// session start / the previous readback query. Returns 1 and fills
/// [x]/[y]/[w]/[h] when a dirty region exists (the host should
/// readback + repaint exactly this region), 0 when nothing is dirty,
/// -1 on a null/inactive session or null out-pointers. Added by
/// phase F1.
KRITA_BRIDGE_API int32_t krita_stroke_dirty_rect(KritaBrushContext* handle,
                                                 int32_t* x, int32_t* y,
                                                 int32_t* w, int32_t* h);

/// Reads an RGBA8 (straight alpha) block of the session's paint device
/// back to the host (KisPaintDevice::readBytes; the dirty rect is the
/// natural query region). [out_rgba] must hold w*h*4 bytes. Returns 1
/// on success, 0 on a null/inactive session or bad arguments. Added
/// by phase F1.
KRITA_BRIDGE_API int32_t krita_stroke_readback(KritaBrushContext* handle,
                                               uint8_t* out_rgba,
                                               int32_t x, int32_t y,
                                               int32_t w, int32_t h);

/// Ends the active session: the painter (and the engine-owned paintop)
/// is destroyed and the texture device released. The recorded engine
/// id (krita_stroke_engine_id) survives until the next session. No-op
/// without an active session. Added by phase F1.
KRITA_BRIDGE_API void krita_stroke_end(KritaBrushContext* handle);

/// Returns the paintop family id the CURRENT (or most recent) session
/// actually dispatched through the registry (e.g. "paintbrush",
/// "spraybrush", "colorsmudge" — the honesty badge for the host UI).
/// Empty string when no session ever ran on this handle. The pointer
/// is owned by the handle; copy it if it must outlive the handle.
/// Added by phase F1.
KRITA_BRIDGE_API const char* krita_stroke_engine_id(KritaBrushContext* handle);

/// Returns the number of paintop families registered in the engine's
/// paintop registry available to stroke sessions (15 on the real
/// bridge: the built-in non-mypaint families; see
/// krita_stroke_begin). The portable and fallback bridges return 0
/// (capability probe). Added by phase F1.
KRITA_BRIDGE_API int32_t krita_stroke_registry_count(KritaBrushContext* handle);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // FEATHER_KRITA_BRIDGE_H
