// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// glass_slider.dart — Custom glassmorphism slider.
//
// A fully custom [StatefulWidget] slider (NOT a wrapper around
// [Slider]) so the visual treatment matches iOS 26 / macOS: a translucent
// track, a rounded active fill, a glowing thumb, and an optional label /
// value readout. Supports keyboard (← / →) and mouse / touch drag.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:feather_krita/theme/app_theme.dart';

/// A glassmorphism slider.
class GlassSlider extends StatefulWidget {
  const GlassSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.label,
    this.icon,
    this.valueFormatter,
    this.divisions,
    this.accent = AppTheme.accent,
    this.height = 44,
    this.enabled = true,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final String? label;
  final IconData? icon;
  final String Function(double)? valueFormatter;
  final int? divisions;
  final Color accent;
  final double height;

  /// When false the slider ignores all input (drag, tap, keyboard) and is
  /// rendered dimmed. Generic capability: 5-loop-41 used it to grey out
  /// the hardness slider for hardness-less paintop families; 5-loop-49
  /// went further and REMOVED that slider (the panel renders a family
  /// note instead), leaving [enabled] available for future per-family
  /// gating.
  final bool enabled;

  @override
  State<GlassSlider> createState() => _GlassSliderState();
}

class _GlassSliderState extends State<GlassSlider> {
  bool _dragging = false;

  double get _fraction {
    if (widget.max <= widget.min) return 0;
    return ((widget.value - widget.min) / (widget.max - widget.min))
        .clamp(0.0, 1.0);
  }

  double _fractionToValue(double f) {
    var v = widget.min + (widget.max - widget.min) * f;
    if (widget.divisions != null) {
      final step = (widget.max - widget.min) / widget.divisions!;
      v = (v / step).round() * step;
    }
    return v.clamp(widget.min, widget.max);
  }

  void _updateFromLocal(double localX, double trackWidth) {
    final f = (localX / trackWidth).clamp(0.0, 1.0);
    widget.onChanged(_fractionToValue(f));
  }

  @override
  Widget build(BuildContext context) {
    final fmt = widget.valueFormatter ?? ((v) => v.toStringAsFixed(0));
    return Focus(
      autofocus: false,
      onKeyEvent: (node, event) {
        if (!widget.enabled) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final step = (widget.max - widget.min) / (widget.divisions ?? 100);
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onChanged((widget.value - step).clamp(widget.min, widget.max));
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onChanged((widget.value + step).clamp(widget.min, widget.max));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Opacity(
        opacity: widget.enabled ? 1.0 : 0.35,
        child: IgnorePointer(
          ignoring: !widget.enabled,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackWidth = constraints.maxWidth;
              return SizedBox(
                height: widget.height,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.label != null)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 4, left: 2, right: 2),
                        child: Row(
                          children: [
                            if (widget.icon != null) ...[
                              Icon(widget.icon,
                                  size: 14, color: AppTheme.textTertiary),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              widget.label!,
                              style: const TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              fmt(widget.value),
                              style: TextStyle(
                                color: widget.accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) {
                          setState(() => _dragging = true);
                          HapticFeedback.selectionClick();
                          widget.onChangeStart?.call(widget.value);
                          _updateFromLocal(d.localPosition.dx, trackWidth);
                        },
                        onPanUpdate: (d) =>
                            _updateFromLocal(d.localPosition.dx, trackWidth),
                        onPanEnd: (_) {
                          setState(() => _dragging = false);
                          widget.onChangeEnd?.call(widget.value);
                        },
                        onTapDown: (d) =>
                            _updateFromLocal(d.localPosition.dx, trackWidth),
                        child: _Track(
                          fraction: _fraction,
                          accent: widget.accent,
                          dragging: _dragging,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({
    required this.fraction,
    required this.accent,
    required this.dragging,
  });

  final double fraction;
  final Color accent;
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final thumb = dragging ? 22.0 : 18.0;
        final x = (w - thumb) * fraction;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            // Base track (full width).
            Container(
              height: 6,
              width: w,
              decoration: BoxDecoration(
                color: AppTheme.darkGlassLight,
                borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
                border: Border.all(color: AppTheme.glassBorder),
              ),
            ),
            // Active fill.
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                height: 6,
                width: (w * fraction).clamp(0.0, w),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [accent.withOpacity(0.8), accent],
                  ),
                  borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withOpacity(0.5),
                      blurRadius: 8,
                      spreadRadius: -2,
                    ),
                  ],
                ),
              ),
            ),
            // Thumb.
            Positioned(
              left: x,
              top: 0,
              bottom: 0,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: thumb,
                  height: thumb,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withOpacity(dragging ? 0.8 : 0.5),
                        blurRadius: dragging ? 14 : 8,
                        spreadRadius: dragging ? 1 : 0,
                      ),
                    ],
                    border: Border.all(color: accent, width: 2),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
