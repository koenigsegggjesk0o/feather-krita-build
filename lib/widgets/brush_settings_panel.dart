// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_settings_panel.dart — Right sidebar brush settings.
//
// A glassmorphism side panel that exposes the active brush parameters:
//   - Size (1 – 500 px)
//   - Opacity (0 – 100 %)
//   - Flow (0 – 100 %, 5-loop-40 — per-dab build-up rate, engine ABI)
//   - Hardness (0 – 100 %, 5-loop-40 — mask fade, engine ABI rebuild);
//     family-aware since 5-loop-49: paintop families without a hardness
//     dimension get NO slider (a note explains the absence), mirroring
//     Krita's own per-paintop option availability
//   - Spacing (0 – 100 %)
//   - Smudge (0 – 100 %)
//   - Colour swatch (opens [showGlassColorPicker])
//   - Active preset name + change button (opens brush picker) + inline
//     inspector entry (5-loop-68): when the active preset is present in
//     the loaded library, a compact manage-search button opens the
//     engine-authoritative [showPresetInspector] for it — the same
//     inspector the picker exposes via long-press, now reachable for
//     the preset you are ACTUALLY painting with, without leaving the
//     settings panel.
//   - Engine params (5-loop-69, roadmap (f) live editing): an
//     expandable section listing the ACTIVE preset's raw
//     paintop-settings parameters straight from the LIVE engine, with
//     tap-to-edit and immediate engine apply. Consumed keys (opacity,
//     flow, hardness, spacing, smudge, eraser flags) take effect on the
//     very next dab and re-seed the curated sliders; unknown keys are
//     recorded engine-side and visible in the inspector. The section
//     hides entirely on fallback/stripped builds (no engine param map)
//   - Sensor curves (milestone (i), 5-loop-77): an expandable section
//     listing the ACTIVE preset's dynamic-sensor curve entries
//     ("<CurveOption>Sensor" keys) with a tap-to-open curve editor — a
//     draggable 0..1 point grid that reads through krita_brush_get_curve
//     and writes through krita_brush_set_curve (strictly validated
//     KisDynamicSensorData XML), plus a UseCurve on/off toggle for the
//     sibling "<Id>UseCurve" flag written through set_param. The section
//     hides itself on fallback/stripped/pre-ABI builds (get_curve
//     collapses to null there), mirroring the Engine-params behaviour
//   - Engine version badge (5-loop-79): a compact always-on row above
//     the engine sections showing the loaded bridge's OWN
//     krita_brush_version string with an honest provenance chip
//     (REAL / PORTABLE / FALLBACK) — closing the honesty gap that the
//     export existed in all three bridges but was unreachable from the
//     UI. Hides itself when no engine version is available.
//
// Every control is wired directly to [EditorState] setters which, in turn,
// sync to the native Krita brush engine.

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/ffi/krita_bindings.dart' show CurveEditStatus;
import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/glass_slider.dart';
import 'package:feather_krita/widgets/glass_color_picker.dart';
import 'package:feather_krita/widgets/preset_inspector_sheet.dart';

/// The right-side brush settings panel.
class BrushSettingsPanel extends StatelessWidget {
  const BrushSettingsPanel({
    super.key,
    required this.state,
    required this.onPickPreset,
    this.onClose,
  });

  final EditorState state;
  final VoidCallback onPickPreset;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return GlassContainer(
          width: 280,
          padding: const EdgeInsets.all(16),
          borderRadius: AppTheme.radiusLarge,
          color: AppTheme.darkGlass.withOpacity(0.55),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(title: 'Brush', onClose: onClose),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Preset name + change button + inspector entry
                      // (5-loop-68). The inspector button only renders when
                      // the active preset resolves in the loaded library —
                      // before [EditorState.loadPresetLibrary] fills
                      // [EditorState.presets] (or for an unmatched name)
                      // there is nothing to inspect and the chip degrades
                      // to the plain picker entry.
                      _PresetChip(
                        name: state.brushPresetName,
                        family: state.activePaintopId,
                        color: Color(state.brushColor),
                        onTap: onPickPreset,
                        onInspect: _activePreset(state) == null
                            ? null
                            : () => showPresetInspector(
                                context, _activePreset(state)!),
                      ),
                      const SizedBox(height: 16),

                      // Size.
                      GlassSlider(
                        value: state.brushSize,
                        min: 1,
                        max: 500,
                        divisions: 499,
                        label: 'Size',
                        icon: Icons.line_weight_rounded,
                        accent: AppTheme.accent,
                        onChanged: state.setBrushSize,
                        valueFormatter: (v) => '${v.round()} px',
                      ),
                      const SizedBox(height: 12),

                      // Opacity.
                      GlassSlider(
                        value: state.brushOpacity,
                        min: 0,
                        max: 1,
                        divisions: 100,
                        label: 'Opacity',
                        icon: Icons.opacity_rounded,
                        accent: AppTheme.toolSelect,
                        onChanged: state.setBrushOpacity,
                        valueFormatter: (v) => '${(v * 100).round()}%',
                      ),
                      const SizedBox(height: 12),

                      // Flow (5-loop-40): per-dab application rate through
                      // the real engine (set_flow ABI). Low flow builds
                      // paint up gradually, airbrush-style.
                      GlassSlider(
                        value: state.brushFlow,
                        min: 0,
                        max: 1,
                        divisions: 100,
                        label: 'Flow',
                        icon: Icons.gradient_rounded,
                        accent: AppTheme.toolShape,
                        onChanged: state.setBrushFlow,
                        valueFormatter: (v) => '${(v * 100).round()}%',
                      ),
                      const SizedBox(height: 12),

                      // Hardness (5-loop-40): mask fade through the real
                      // engine (set_hardness ABI rebuilds the mask
                      // generator). 0 = fully soft gaussian, 1 = hard
                      // disk. Family-aware (5-loop-41 data, 5-loop-49 UX):
                      // paintop families without a hardness dimension get
                      // NO slider — Krita's own brush editors offer no
                      // hardness option for them — just a compact note
                      // explaining the absence. Unknown / undeclared
                      // families keep the slider (manual control).
                      if (state.activePaintopSupportsHardness)
                        GlassSlider(
                          value: state.brushHardness,
                          min: 0,
                          max: 1,
                          divisions: 100,
                          label: 'Hardness',
                          icon: Icons.adjust_rounded,
                          accent: AppTheme.toolLight,
                          onChanged: state.setBrushHardness,
                          valueFormatter: (v) => '${(v * 100).round()}%',
                        )
                      else
                        _NoHardnessNote(family: state.activePaintopId),
                      const SizedBox(height: 12),

                      // Spacing.
                      GlassSlider(
                        value: state.brushSpacing,
                        min: 0,
                        max: 1,
                        divisions: 100,
                        label: 'Spacing',
                        icon: Icons.space_bar_rounded,
                        accent: AppTheme.toolShape,
                        onChanged: state.setBrushSpacing,
                        valueFormatter: (v) => '${(v * 100).round()}%',
                      ),
                      const SizedBox(height: 12),

                      // Smudge.
                      GlassSlider(
                        value: state.brushSmudge,
                        min: 0,
                        max: 1,
                        divisions: 100,
                        label: 'Smudge',
                        icon: Icons.water_drop_outlined,
                        accent: AppTheme.toolLiquify,
                        onChanged: state.setBrushSmudge,
                        valueFormatter: (v) => '${(v * 100).round()}%',
                      ),
                      const SizedBox(height: 12),

                      // Smoothing / stabilizer (loop-25).
                      GlassSlider(
                        value: state.brushSmoothing,
                        min: 0,
                        max: 1,
                        divisions: 100,
                        label: 'Smoothing',
                        icon: Icons.waves_rounded,
                        accent: AppTheme.toolSelect,
                        onChanged: state.setBrushSmoothing,
                        valueFormatter: (v) => '${(v * 100).round()}%',
                      ),
                      const SizedBox(height: 16),

                      // Colour swatch + picker.
                      _ColorRow(state: state),
                      const SizedBox(height: 8),
                      // Recent colours (loop-27).
                      _ColorHistoryRow(state: state),
                      const SizedBox(height: 16),

                      // Mirror.
                      _MirrorRow(state: state),
                      const SizedBox(height: 16),

                      // Active-engine version badge (5-loop-79): WHICH
                      // bridge is backing the engine sections below,
                      // verbatim from krita_brush_version. Hides itself
                      // when no engine version is available.
                      _EngineVersionBadge(state: state),
                      const SizedBox(height: 16),

                      // Live engine params (roadmap (f), 5-loop-69): the
                      // ACTIVE preset's raw paintop-settings surface from
                      // the LIVE engine, editable in place. Hides itself
                      // on fallback/stripped builds.
                      _EngineParamsSection(state: state),
                      const SizedBox(height: 8),

                      // Sensor curves (milestone (i), 5-loop-77): the
                      // ACTIVE preset's dynamic-sensor curve entries with
                      // a draggable point-grid editor (get_curve /
                      // set_curve). Hides itself on bridges that cannot
                      // expose curves (portable/fallback/pre-ABI).
                      _SensorCurvesSection(state: state),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets.
// ---------------------------------------------------------------------------

/// Resolves the ACTIVE preset object from the loaded library by display
/// name (5-loop-68). [EditorState.loadBrushPreset] sets the name from the
/// very same scanned list, so a first-match lookup is exact for every
/// preset the panel can have loaded. Returns null when the library is
/// not loaded yet or the name has no entry — the inspector entry hides.
BrushPreset? _activePreset(EditorState state) {
  final name = state.brushPresetName;
  for (final p in state.presets) {
    if (p.name == name) return p;
  }
  return null;
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.onClose});

  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: AppTheme.accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const Spacer(),
        if (onClose != null)
          GestureDetector(
            onTap: onClose,
            child: const Icon(Icons.close_rounded,
                size: 18, color: AppTheme.textTertiary),
          ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.name,
    required this.color,
    required this.onTap,
    this.family,
    this.onInspect,
  });

  final String name;
  final Color color;
  final VoidCallback onTap;

  /// Opens the preset inspector for THIS preset (5-loop-68). Null hides
  /// the inline inspect button — the chip then offers only the picker
  /// entry. Distinct from [onTap]: tapping the chip still opens the
  /// picker; tapping the lens-like button inspects the active preset
  /// in place.
  final VoidCallback? onInspect;

  /// The loaded preset's declared paintop family (5-loop-41), shown as a
  /// small badge after the "Preset" label. Empty hides the badge.
  final String? family;

  String get _familyLabel {
    final f = (family ?? '').trim();
    if (f.isEmpty) return '';
    return f[0].toUpperCase() + f.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final familyLabel = _familyLabel;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.darkGlassLight,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(color: AppTheme.glassBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Preset',
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (familyLabel.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        // Flexible: the badge degrades to an ellipsis on
                        // pathological widths instead of overflowing
                        // (5-loop-49 — widget tests surfaced this under
                        // the Ahem test font's wide metrics).
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.accentSoft,
                              borderRadius: BorderRadius.circular(
                                  AppTheme.radiusSmall),
                            ),
                            child: Text(
                              familyLabel,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (onInspect != null)
              GestureDetector(
                onTap: onInspect,
                child: Tooltip(
                  message: 'Inspect preset settings',
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.manage_search_rounded,
                        size: 22, color: AppTheme.textTertiary),
                  ),
                ),
              ),
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right_rounded,
                color: AppTheme.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }
}

/// A compact note rendered in place of the hardness slider when the loaded
/// preset's paintop family has no hardness dimension (5-loop-49). Mirrors
/// Krita: the brush editor simply offers no hardness option for these
/// families — hiding the dead slider beats greying it out, and the note
/// keeps the panel self-explanatory (why did the slider disappear?) while
/// giving widget tests a stable handle.
///
/// By construction [family] is non-empty here: the note renders only when
/// [EditorState.activePaintopSupportsHardness] is false, which cannot
/// happen for an undeclared family.
class _NoHardnessNote extends StatelessWidget {
  const _NoHardnessNote({required this.family});

  /// The engine-declared paintop family, e.g. "spraybrush".
  final String family;

  /// Same capitalization rule as the preset chip's family badge so the
  /// panel speaks of the family consistently.
  String get _familyLabel {
    final f = family.trim();
    return f[0].toUpperCase() + f.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.adjust_rounded,
              size: 14, color: AppTheme.textTertiary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Hardness not available for $_familyLabel',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Color',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: () async {
            final c = await showGlassColorPicker(
              context,
              initialColor: state.brushColor,
              history: state.colorHistory,
            );
            if (c != null) state.setBrushColor(c);
          },
          child: Container(
            width: 48,
            height: 32,
            decoration: BoxDecoration(
              color: Color(state.brushColor),
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              border: Border.all(color: AppTheme.glassBorder),
              boxShadow: AppTheme.glassShadow,
            ),
            child: const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.edit, size: 12, color: Colors.white70),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '#${(state.brushColor & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}',
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}

/// A horizontally-wrapped row of recently-used brush colours (loop-27).
/// Tap a swatch to reuse the colour; long-press to remove it from the
/// history. Hidden when the history is empty. The active brush colour is
/// outlined with the accent ring.
class _ColorHistoryRow extends StatelessWidget {
  const _ColorHistoryRow({required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final history = state.colorHistory;
    if (history.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          'Recent',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in history)
                GestureDetector(
                  onTap: () => state.setBrushColor(c),
                  onLongPress: () => state.removeFromColorHistory(c),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c == state.brushColor
                            ? AppTheme.accent
                            : AppTheme.glassBorder,
                        width: c == state.brushColor ? 2 : 1,
                      ),
                      boxShadow: AppTheme.glassShadow,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MirrorRow extends StatelessWidget {
  const _MirrorRow({required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Mirror',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _MirrorToggle(
              label: 'X',
              active: state.mirrorX,
              color: AppTheme.primaryPink,
              onTap: () => state.setMirror(
                x: !state.mirrorX,
                y: state.mirrorY,
                z: state.mirrorZ,
              ),
            ),
            const SizedBox(width: 6),
            _MirrorToggle(
              label: 'Y',
              active: state.mirrorY,
              color: AppTheme.primaryGreen,
              onTap: () => state.setMirror(
                x: state.mirrorX,
                y: !state.mirrorY,
                z: state.mirrorZ,
              ),
            ),
            const SizedBox(width: 6),
            _MirrorToggle(
              label: 'Z',
              active: state.mirrorZ,
              color: AppTheme.primaryBlue,
              onTap: () => state.setMirror(
                x: state.mirrorX,
                y: state.mirrorY,
                z: !state.mirrorZ,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MirrorToggle extends StatelessWidget {
  const _MirrorToggle({
    required this.label,
    required this.active,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 44,
        height: 32,
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.3) : AppTheme.darkGlassLight,
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          border: Border.all(
            color: active ? color : AppTheme.glassBorder,
            width: active ? 1.5 : 0.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : AppTheme.textTertiary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

/// Active-engine version badge (5-loop-79). Shows the loaded bridge's
/// own krita_brush_version string with an honest provenance chip: REAL
/// for the real Krita bridge, PORTABLE / FALLBACK for the soft-round
/// fallbacks. Collapses to nothing when no engine version is available
/// (no engine / pre-symbol artifact) — the same degrade contract as the
/// engine sections below it.
class _EngineVersionBadge extends StatelessWidget {
  const _EngineVersionBadge({required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final v = state.activeEngineVersion;
    if (v == null) return const SizedBox.shrink();
    final String chip;
    final Color chipColor;
    if (v.startsWith('FeatherBridge-Krita/')) {
      chip = 'REAL';
      chipColor = const Color(0xFF3FB26F);
    } else if (v.startsWith('FeatherBridge-Portable/')) {
      chip = 'PORTABLE';
      chipColor = const Color(0xFFC9A227);
    } else if (v.startsWith('FeatherBridge-Qt/')) {
      chip = 'FALLBACK';
      chipColor = const Color(0xFFC9A227);
    } else {
      chip = 'ENGINE';
      chipColor = AppTheme.textTertiary;
    }
    // HANDOVER 6.5 honesty note: the upstream v6.0.4 sources' own
    // CMakeLists carries two KRITA_VERSION_STRING blocks and the Qt5
    // build configuration picks the later 5.3.x one — so the real
    // bridge self-reports 5.3.x while the sources are byte-identical
    // v6.0.4 (blob-SHA proven). Surface that fact exactly once, and
    // only while it actually applies.
    final showSourceNote =
        v.contains('real engine') && !v.contains('6.0.4');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.verified_outlined,
                size: 14, color: AppTheme.textTertiary),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              ),
              child: Text(
                chip,
                style: TextStyle(
                  color: chipColor,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                v,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        if (showSourceNote) ...[
          const SizedBox(height: 2),
          const Padding(
            padding: EdgeInsets.only(left: 26),
            child: Text(
              'engine self-report · built from upstream Krita v6.0.4 '
              'sources (the upstream Qt5 build configuration reports '
              '5.3.x)',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 9.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The live paintop-settings param editor (roadmap (f), 5-loop-69).
///
/// Lists the ACTIVE preset's raw `<param>` surface exactly as the LIVE
/// engine holds it ([EditorState.activeEngineParams] — the engine's own
/// parse, document order), with search-as-you-type and tap-to-edit: the
/// edit dialog writes through [EditorState.setEngineParam], so consumed
/// keys take effect on the very next dab and re-seed the curated
/// sliders, while unknown keys are recorded in the engine's param map
/// of record (visible in the preset inspector).
///
/// Renders NOTHING on fallback/stripped builds: without a native engine
/// there is no param map to edit — the preset inspector's DART PARSE
/// view stays the read-only fallback surface. On engine artifacts that
/// predate the set_param export the map still renders (the getters are
/// older), but applying an edit shows a "not supported" note instead of
/// a silently dead edit.
class _EngineParamsSection extends StatefulWidget {
  const _EngineParamsSection({required this.state});

  final EditorState state;

  @override
  State<_EngineParamsSection> createState() => _EngineParamsSectionState();
}

class _EngineParamsSectionState extends State<_EngineParamsSection> {
  bool _expanded = false;
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final params = widget.state.activeEngineParams;
    // No live engine param map (no native engine / no loaded preset /
    // fallback bridge): the whole section collapses to nothing.
    if (params.isEmpty) return const SizedBox.shrink();

    final entries = params.entries.toList();
    final q = _filter.trim().toLowerCase();
    final filtered = q.isEmpty
        ? entries
        : entries
            .where((e) =>
                e.key.toLowerCase().contains(q) ||
                e.value.toLowerCase().contains(q))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            children: [
              const Icon(Icons.tune_rounded,
                  size: 14, color: AppTheme.textTertiary),
              const SizedBox(width: 6),
              const Text(
                'Engine params',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.accentSoft,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                ),
                child: Text(
                  '${filtered.length}/${entries.length}',
                  style: const TextStyle(
                    color: AppTheme.accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 120),
                child: const Icon(Icons.keyboard_arrow_down_rounded,
                    size: 18, color: AppTheme.textTertiary),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          TextField(
            onChanged: (v) => setState(() => _filter = v),
            style: const TextStyle(
                color: AppTheme.textPrimary, fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText:
                  'Filter ${entries.length} params (name or value)',
              hintStyle: const TextStyle(
                  color: AppTheme.textTertiary, fontSize: 11),
              prefixIcon: const Icon(Icons.search_rounded,
                  size: 16, color: AppTheme.textTertiary),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              filled: true,
              fillColor: AppTheme.darkGlassLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                borderSide: const BorderSide(color: AppTheme.glassBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                borderSide: const BorderSide(color: AppTheme.glassBorder),
              ),
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'no params match "$_filter"',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppTheme.textTertiary, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final e = filtered[i];
                      return _EngineParamRow(
                        name: e.key,
                        value: e.value,
                        onEdit: () => _editParam(context, e.key, e.value),
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }

  Future<void> _editParam(
      BuildContext context, String name, String value) async {
    final controller = TextEditingController(text: value);
    var saved = false;
    var edited = value;
    try {
      saved = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              backgroundColor: AppTheme.darkGlassLight,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                side: const BorderSide(color: AppTheme.glassBorder),
              ),
              title: Text(
                name,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 14),
              ),
              content: TextField(
                controller: controller,
                autofocus: true,
                maxLines: null,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: 'raw settings value',
                  hintStyle:
                      TextStyle(color: AppTheme.textTertiary, fontSize: 11),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ) ??
          false;
      edited = controller.text;
    } finally {
      controller.dispose();
    }
    if (!saved) return;
    final ok = widget.state.setEngineParam(name, edited);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Live param editing is not supported by this engine build'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }
}

/// One row of the engine-params list: monospace name, ellipsised raw
/// value (sensor-curve blobs can be kilobytes — the edit dialog shows
/// the full text), tap to edit.
class _EngineParamRow extends StatelessWidget {
  const _EngineParamRow({
    required this.name,
    required this.value,
    required this.onEdit,
  });

  final String name;
  final String value;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.edit_outlined,
                size: 12, color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sensor curves (milestone (i), 5-loop-77)
// ---------------------------------------------------------------------------

/// Parses / serializes the engine's dynamic-sensor params XML (the
/// KisDynamicSensorData shape carried by "<CurveOption>Sensor" param-map
/// entries): an optional DOCTYPE prolog, a <params id="..."> root with
/// exactly one <curve> child holding semicolon-separated "x,y;" float
/// pairs in [0,1]^2. Sensors can also carry the EMPTY form
/// `<params id="..."/>` (no <curve> child) — [parse] then reports the
/// default linear curve and the original id, so the editor always starts
/// from something sensible.
class _CurveXml {
  static final RegExp _idRe = RegExp(r'<params\b[^>]*\bid\s*=\s*"([^"]*)"');
  static final RegExp _curveRe = RegExp(r'<curve>([^<]*)</curve>');

  /// The default sensor id used when the source XML carries none (all
  /// stock v6.0.4 presets key their dynamic sensors "pressure").
  static const String defaultId = 'pressure';

  /// Extracts the params id and the curve points from raw sensor XML.
  /// Points are sorted by x; invalid / non-finite / out-of-range pairs
  /// are dropped; fewer than 2 survivors fall back to the linear
  /// default. Returns the id verbatim (or [defaultId]).
  static ({String id, List<Offset> points}) parse(String xml) {
    final id = _idRe.firstMatch(xml)?.group(1);
    final curveText = _curveRe.firstMatch(xml)?.group(1);
    final pts = <Offset>[];
    if (curveText != null) {
      for (final pair in curveText.split(';')) {
        final t = pair.trim();
        if (t.isEmpty) continue;
        final parts = t.split(',');
        if (parts.length != 2) continue;
        final x = double.tryParse(parts[0].trim());
        final y = double.tryParse(parts[1].trim());
        if (x == null || y == null) continue;
        if (x.isNaN || y.isNaN || x.isInfinite || y.isInfinite) continue;
        if (x < 0 || x > 1 || y < 0 || y > 1) continue;
        pts.add(Offset(x, y));
      }
    }
    pts.sort((a, b) => a.dx.compareTo(b.dx));
    if (pts.length < 2) {
      pts
        ..clear()
        ..addAll(const [Offset(0, 0), Offset(1, 1)]);
    }
    return (id: (id == null || id.isEmpty) ? defaultId : id, points: pts);
  }

  /// Formats a double the way stock presets do: up to 6 decimals with
  /// trailing zeros stripped ("1" not "1.0", "0.35" not "0.350000").
  static String _fmt(double v) {
    final clamped = v.clamp(0.0, 1.0);
    var s = clamped.toStringAsFixed(6);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s.isEmpty ? '0' : s;
  }

  /// Serializes [points] (sorted by x first) into the exact fixture
  /// shape the engine writes and the wrapper's set_curve validator
  /// accepts: `<!DOCTYPE params> <params id="ID"> <curve>x0,y0;
  /// x1,y1;</curve> </params> ` (single spaces, trailing space — byte
  /// compatible with stock v6.0.4 preset payload).
  static String serialize(String id, List<Offset> points) {
    final pts = [...points]..sort((a, b) => a.dx.compareTo(b.dx));
    final body = pts.map((p) => '${_fmt(p.dx)},${_fmt(p.dy)};').join();
    final safeId = id.replaceAll('"', '');
    return '<!DOCTYPE params> <params id="$safeId"> <curve>$body</curve> </params> ';
  }
}

/// The live sensor-curve section (milestone (i)): lists the ACTIVE
/// preset's curve-capable param entries — keys named
/// "<CurveOption>Sensor" that the loaded engine actually resolves
/// through krita_brush_get_curve — with a mini curve preview per row
/// and a tap-to-open draggable point-grid editor. Curves are recorded
/// engine-side (the settings-level of record) and applied host-side;
/// the "<Id>UseCurve" sibling flag is toggled through set_param.
///
/// Renders NOTHING on fallback/stripped builds, on engine artifacts
/// that predate the get_curve export, or before a preset is loaded —
/// the capability probe is per-key (get_curve must resolve non-null),
/// mirroring the Engine-params section behaviour.
class _SensorCurvesSection extends StatefulWidget {
  const _SensorCurvesSection({required this.state});

  final EditorState state;

  @override
  State<_SensorCurvesSection> createState() => _SensorCurvesSectionState();
}

class _SensorCurvesSectionState extends State<_SensorCurvesSection> {
  bool _expanded = false;

  /// The curve-capable keys of the active preset: every "*Sensor" map
  /// entry whose raw XML the engine resolves non-null. On bridges that
  /// cannot expose curves this stays empty and the section collapses.
  List<String> _curveKeys() {
    final params = widget.state.activeEngineParams;
    final keys = params.keys.where((k) => k.endsWith('Sensor')).toList()
      ..sort();
    return keys
        .where((k) => widget.state.activeEngineCurve(k) != null)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final curveKeys = _curveKeys();
    if (curveKeys.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            children: [
              const Icon(Icons.show_chart_rounded,
                  size: 14, color: AppTheme.textTertiary),
              const SizedBox(width: 6),
              const Text(
                'Sensor curves',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.accentSoft,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                ),
                child: Text(
                  '${curveKeys.length}',
                  style: const TextStyle(
                    color: AppTheme.accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 120),
                child: const Icon(Icons.keyboard_arrow_down_rounded,
                    size: 18, color: AppTheme.textTertiary),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 6),
          Text(
            'recorded engine-side, applied host-side',
            style: const TextStyle(
              color: AppTheme.textTertiary,
              fontSize: 9.5,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: curveKeys.length,
              itemBuilder: (context, i) => _CurveRow(
                state: widget.state,
                curveKey: curveKeys[i],
                onOpen: () => _openEditor(context, curveKeys[i]),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openEditor(BuildContext context, String curveKey) async {
    final recorded = await showDialog<bool>(
      context: context,
      builder: (_) => _CurveEditorDialog(state: widget.state, curveKey: curveKey),
    );
    if (!mounted) return;
    if (recorded == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$curveKey curve recorded'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (recorded == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Curve editing is not supported by this engine build'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    setState(() {}); // refresh mini previews from the engine of record
  }
}

/// One row of the sensor-curves list: monospace key, an "active" chip
/// when the sibling "<Id>UseCurve" flag is on, a mini polyline preview
/// of the recorded curve, tap to open the editor.
class _CurveRow extends StatelessWidget {
  const _CurveRow({
    required this.state,
    required this.curveKey,
    required this.onOpen,
  });

  final EditorState state;
  final String curveKey;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final raw = state.activeEngineCurve(curveKey) ?? '';
    final parsed = _CurveXml.parse(raw);
    final useCurveKey = '${curveKey.substring(0, curveKey.length - 6)}UseCurve';
    final useRaw = state.activeEngineParamValue(useCurveKey);
    final useOn = useRaw == 'true' || useRaw == '1';

    return GestureDetector(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                curveKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            if (useRaw != null)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: useOn ? AppTheme.accentSoft : AppTheme.darkGlassLight,
                  borderRadius:
                      BorderRadius.circular(AppTheme.radiusSmall),
                ),
                child: Text(
                  useOn ? 'curve on' : 'curve off',
                  style: TextStyle(
                    color: useOn ? AppTheme.accent : AppTheme.textTertiary,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              height: 22,
              child: CustomPaint(
                painter: _CurveGridPainter(
                  points: parsed.points,
                  showGrid: false,
                  showPoints: false,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.edit_outlined,
                size: 12, color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// The sensor-curve editor (milestone (i)): a 0..1 point grid over the
/// curve's [0,1]^2 space — drag points to reshape, tap empty space to
/// add one (max 12), long-press a point to remove it (min 2, the
/// engine validator's floor). "Use curve" toggles the sibling
/// "<Id>UseCurve" flag engine-side through set_param (immediate,
/// exact fixture strings "true"/"false"). Apply writes the edited
/// points through krita_brush_set_curve as the engine's own
/// KisDynamicSensorData XML (validated wrapper-side, recorded into the
/// param map of record, applied host-side).
///
/// Pop results: true = recorded, false = bridge cannot edit curves
/// (the section shows the "not supported" note), null = cancelled.
class _CurveEditorDialog extends StatefulWidget {
  const _CurveEditorDialog({required this.state, required this.curveKey});

  final EditorState state;
  final String curveKey;

  @override
  State<_CurveEditorDialog> createState() => _CurveEditorDialogState();
}

class _CurveEditorDialogState extends State<_CurveEditorDialog> {
  late final String _sensorId;
  late final List<Offset> _original;
  late List<Offset> _points;
  String? _useCurveKey;
  bool? _useCurve;
  int _dragIndex = -1;
  String? _error;
  Size _plotSize = Size.zero;

  static const double _hitRadius = 26;
  static const int _maxPoints = 12;

  @override
  void initState() {
    super.initState();
    final raw = widget.state.activeEngineCurve(widget.curveKey) ?? '';
    final parsed = _CurveXml.parse(raw);
    _sensorId = parsed.id;
    _original = parsed.points;
    _points = [...parsed.points];
    final base = widget.curveKey.substring(0, widget.curveKey.length - 6);
    _useCurveKey = '${base}UseCurve';
    final useRaw = widget.state.activeEngineParamValue(_useCurveKey!);
    if (useRaw == null) {
      _useCurveKey = null;
      _useCurve = null;
    } else {
      _useCurve = useRaw == 'true' || useRaw == '1';
    }
  }

  Offset _toNorm(Offset local) => Offset(
        (local.dx / _plotSize.width).clamp(0.0, 1.0),
        (1.0 - local.dy / _plotSize.height).clamp(0.0, 1.0),
      );

  Offset _toPx(Offset norm) => Offset(
        norm.dx * _plotSize.width,
        (1.0 - norm.dy) * _plotSize.height,
      );

  int _hitIndex(Offset local) {
    var best = -1;
    var bestD2 = _hitRadius * _hitRadius;
    for (var i = 0; i < _points.length; i++) {
      final d = (_toPx(_points[i]) - local).distanceSquared;
      if (d <= bestD2) {
        bestD2 = d;
        best = i;
      }
    }
    return best;
  }

  void _onPanStart(DragStartDetails d) {
    setState(() => _dragIndex = _hitIndex(d.localPosition));
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_dragIndex < 0 || _dragIndex >= _points.length) return;
    setState(() {
      _points[_dragIndex] = _toNorm(d.localPosition);
      _error = null;
    });
  }

  void _onPanEnd(DragEndDetails d) {
    if (_dragIndex < 0) return;
    setState(() {
      // Re-sort after the gesture so the polyline never zigzags; the
      // drag index is cleared so identity no longer matters.
      _points.sort((a, b) => a.dx.compareTo(b.dx));
      _dragIndex = -1;
    });
  }

  void _onTapUp(TapUpDetails d) {
    if (_hitIndex(d.localPosition) >= 0) return;
    if (_points.length >= _maxPoints) {
      setState(() => _error = 'max $_maxPoints points');
      return;
    }
    setState(() {
      _points.add(_toNorm(d.localPosition));
      _points.sort((a, b) => a.dx.compareTo(b.dx));
      _error = null;
    });
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final i = _hitIndex(d.localPosition);
    if (i < 0) return;
    if (_points.length <= 2) {
      setState(() => _error = 'a curve needs at least 2 points');
      return;
    }
    setState(() {
      _points.removeAt(i);
      _error = null;
    });
  }

  void _toggleUseCurve(bool on) {
    setState(() {
      final ok =
          widget.state.setEngineParam(_useCurveKey!, on ? 'true' : 'false');
      if (ok) {
        _useCurve = on;
        _error = null;
      } else {
        _error = 'flag edit not supported by this engine build';
      }
    });
  }

  Future<void> _apply() async {
    final xml = _CurveXml.serialize(_sensorId, _points);
    final status = widget.state.setEngineCurve(widget.curveKey, xml);
    switch (status) {
      case CurveEditStatus.recorded:
        if (mounted) Navigator.of(context).pop(true);
        return;
      case CurveEditStatus.unsupported:
        if (mounted) Navigator.of(context).pop(false);
        return;
      case CurveEditStatus.rejected:
        setState(
            () => _error = 'engine rejected the payload (needs >= 2 points in [0,1])');
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.darkGlassLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        side: const BorderSide(color: AppTheme.glassBorder),
      ),
      title: Text(
        widget.curveKey,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
      ),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_useCurveKey != null)
              GestureDetector(
                onTap: () => _toggleUseCurve(!(_useCurve ?? false)),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        _useCurve == true
                            ? Icons.toggle_on_rounded
                            : Icons.toggle_off_rounded,
                        size: 22,
                        color: _useCurve == true
                            ? AppTheme.accent
                            : AppTheme.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Use curve for this option ($_useCurveKey)',
                          style: const TextStyle(
                              color: AppTheme.textSecondary, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            LayoutBuilder(
              builder: (context, constraints) {
                _plotSize = Size(constraints.maxWidth, 200);
                return GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  onTapUp: _onTapUp,
                  onLongPressStart: _onLongPressStart,
                  child: Container(
                    height: _plotSize.height,
                    decoration: BoxDecoration(
                      color: AppTheme.darkGlassLight,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                      border: Border.all(color: AppTheme.glassBorder),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                      child: CustomPaint(
                        painter: _CurveGridPainter(
                          points: _points,
                          showGrid: true,
                          showPoints: true,
                          dragIndex: _dragIndex,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  'sensor: $_sensorId',
                  style: const TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                Text(
                  '${_points.length} pts',
                  style: const TextStyle(
                      color: AppTheme.textTertiary, fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'tap: add · drag: move · long-press: remove',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 9.5),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: const TextStyle(color: AppTheme.accent, fontSize: 10.5),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _points = [..._original];
            _error = null;
          }),
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _apply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Paints the 0..1 sensor-curve space: faint quarter grid, the polyline
/// through [points] (curve space — y up), and (optionally) the point
/// handles with the dragged one highlighted. Shared by the mini row
/// previews (grid + points off) and the editor plot.
class _CurveGridPainter extends CustomPainter {
  _CurveGridPainter({
    required this.points,
    required this.showGrid,
    required this.showPoints,
    this.dragIndex = -1,
  });

  final List<Offset> points;
  final bool showGrid;
  final bool showPoints;
  final int dragIndex;

  @override
  void paint(Canvas canvas, Size size) {
    Offset px(Offset p) =>
        Offset(p.dx * size.width, (1.0 - p.dy) * size.height);

    if (showGrid) {
      final gridPaint = Paint()
        ..color = AppTheme.glassBorder
        ..strokeWidth = 0.5;
      for (final t in const [0.0, 0.25, 0.5, 0.75, 1.0]) {
        canvas.drawLine(Offset(t * size.width, 0),
            Offset(t * size.width, size.height), gridPaint);
        canvas.drawLine(Offset(0, t * size.height),
            Offset(size.width, t * size.height), gridPaint);
      }
    }

    final linePaint = Paint()
      ..color = AppTheme.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = showGrid ? 2.0 : 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (points.isEmpty) {
      canvas.drawLine(px(const Offset(0, 0)), px(const Offset(1, 1)),
          linePaint..color = AppTheme.textTertiary);
      return;
    }

    final path = Path()..moveTo(px(points.first).dx, px(points.first).dy);
    for (var i = 1; i < points.length; i++) {
      final p = px(points[i]);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, linePaint);

    if (showPoints) {
      for (var i = 0; i < points.length; i++) {
        final c = px(points[i]);
        final isDrag = i == dragIndex;
        canvas.drawCircle(
          c,
          isDrag ? 7 : 5,
          Paint()
            ..color = isDrag ? AppTheme.accent : AppTheme.darkGlassLight,
        );
        canvas.drawCircle(
          c,
          isDrag ? 7 : 5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = AppTheme.accent,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CurveGridPainter oldDelegate) =>
      oldDelegate.dragIndex != dragIndex ||
      oldDelegate.showGrid != showGrid ||
      oldDelegate.showPoints != showPoints ||
      !_samePoints(oldDelegate.points, points);

  static bool _samePoints(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
