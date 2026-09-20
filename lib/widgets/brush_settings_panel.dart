// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_settings_panel.dart — Right sidebar brush settings.
//
// A glassmorphism side panel that exposes the active brush parameters:
//   - Size (1 – 500 px)
//   - Opacity (0 – 100 %)
//   - Flow (0 – 100 %, 5-loop-40 — per-dab build-up rate, engine ABI)
//   - Hardness (0 – 100 %, 5-loop-40 — mask fade, engine ABI rebuild)
//   - Spacing (0 – 100 %)
//   - Smudge (0 – 100 %)
//   - Colour swatch (opens [showGlassColorPicker])
//   - Active preset name + change button (opens brush picker)
//
// Every control is wired directly to [EditorState] setters which, in turn,
// sync to the native Krita brush engine.

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/widgets/glass_slider.dart';
import 'package:feather_krita/widgets/glass_color_picker.dart';

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
                      // Preset name + change button.
                      _PresetChip(
                        name: state.brushPresetName,
                        family: state.activePaintopId,
                        color: Color(state.brushColor),
                        onTap: onPickPreset,
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
                      // generator). 0 = fully soft gaussian, 1 = hard disk.
                      // Disabled (5-loop-41) when the loaded preset's
                      // paintop family has no hardness dimension, mirroring
                      // Krita's own per-paintop option availability.
                      GlassSlider(
                        value: state.brushHardness,
                        min: 0,
                        max: 1,
                        divisions: 100,
                        label: 'Hardness',
                        icon: Icons.adjust_rounded,
                        accent: AppTheme.toolLight,
                        enabled: state.activePaintopSupportsHardness,
                        onChanged: state.setBrushHardness,
                        valueFormatter: (v) => '${(v * 100).round()}%',
                      ),
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
  });

  final String name;
  final Color color;
  final VoidCallback onTap;

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
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.accentSoft,
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusSmall),
                          ),
                          child: Text(
                            familyLabel,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.accent,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
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
            const Icon(Icons.chevron_right_rounded,
                color: AppTheme.textTertiary, size: 20),
          ],
        ),
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
