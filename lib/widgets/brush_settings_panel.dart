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
//
// Every control is wired directly to [EditorState] setters which, in turn,
// sync to the native Krita brush engine.

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
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

                      // Live engine params (roadmap (f), 5-loop-69): the
                      // ACTIVE preset's raw paintop-settings surface from
                      // the LIVE engine, editable in place. Hides itself
                      // on fallback/stripped builds.
                      _EngineParamsSection(state: state),
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
