// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// glass_color_picker.dart — Glassmorphism color picker dialog.
//
// A self-contained dialog that lets the user pick a colour by:
//   - Dragging on an HSV colour wheel (hue = angle, saturation = radius).
//   - Adjusting H / S / V / A sliders.
//   - Typing a hex string (#RRGGBB or #AARRGGBB).
//   - Tapping a preset swatch.
//
// The picker reports the live colour via [onChanged] and the committed
// colour via [onConfirm]. Returns the chosen ARGB int from
// [showGlassColorPicker].

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/widgets/glass_slider.dart';

/// Shows a [GlassColorPicker] inside a glass dialog and returns the chosen
/// ARGB int (or `null` if cancelled).
Future<int?> showGlassColorPicker(
  BuildContext context, {
  int initialColor = 0xFF000000,
  List<int>? history,
}) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: GlassColorPicker(
        initialColor: initialColor,
        history: history,
        onCancel: () => Navigator.pop(ctx),
        onConfirm: (c) => Navigator.pop(ctx, c),
      ),
    ),
  );
}

/// A glassmorphism colour picker.
class GlassColorPicker extends StatefulWidget {
  const GlassColorPicker({
    super.key,
    required this.initialColor,
    required this.onConfirm,
    this.onCancel,
    this.onChanged,
    this.history,
  });

  final int initialColor;
  final ValueChanged<int> onConfirm;
  final VoidCallback? onCancel;
  final ValueChanged<int>? onChanged;

  /// Recently-used colours to surface above the static preset swatches
  /// (loop-27). May be null or empty; the section is hidden in that case.
  final List<int>? history;

  @override
  State<GlassColorPicker> createState() => _GlassColorPickerState();
}

class _GlassColorPickerState extends State<GlassColorPicker> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(Color(widget.initialColor));
  }

  int get _argb {
    final c = _hsv.toColor();
    return c.value;
  }

  void _emit() {
    widget.onChanged?.call(_argb);
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return GlassContainer(
      width: 380,
      padding: const EdgeInsets.all(20),
      color: AppTheme.darkGlass.withOpacity(0.7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Color',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          // Wheel + preview.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ColorWheel(
                hsv: _hsv,
                onChanged: (h, s) {
                  setState(() {
                    _hsv = _hsv.withHue(h).withSaturation(s);
                  });
                  _emit();
                },
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    _PreviewSwatch(color: color),
                    const SizedBox(height: 12),
                    _HexField(
                      color: color,
                      onSubmitted: (argb) {
                        setState(() {
                          _hsv = HSVColor.fromColor(Color(argb));
                        });
                        _emit();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Sliders.
          _HueSlider(
            hue: _hsv.hue,
            onChanged: (h) {
              setState(() => _hsv = _hsv.withHue(h));
              _emit();
            },
          ),
          const SizedBox(height: 8),
          _ChannelSlider(
            label: 'Saturation',
            value: _hsv.saturation,
            gradient: LinearGradient(
              colors: [
                _hsv.withSaturation(0).toColor(),
                _hsv.withSaturation(1).toColor(),
              ],
            ),
            onChanged: (s) {
              setState(() => _hsv = _hsv.withSaturation(s));
              _emit();
            },
          ),
          const SizedBox(height: 8),
          _ChannelSlider(
            label: 'Value',
            value: _hsv.value,
            gradient: LinearGradient(
              colors: [Colors.black, _hsv.withValue(1).toColor()],
            ),
            onChanged: (v) {
              setState(() => _hsv = _hsv.withValue(v));
              _emit();
            },
          ),
          const SizedBox(height: 8),
          _ChannelSlider(
            label: 'Alpha',
            value: _hsv.alpha,
            gradient: LinearGradient(
              colors: [
                _hsv.withAlpha(0).toColor(),
                _hsv.withAlpha(1).toColor(),
              ],
            ),
            onChanged: (a) {
              setState(() => _hsv = _hsv.withAlpha(a));
              _emit();
            },
          ),
          const SizedBox(height: 16),
          if (widget.history != null && widget.history!.isNotEmpty) ...[
            _HistorySwatches(
              history: widget.history!,
              onSelected: (argb) {
                setState(() => _hsv = HSVColor.fromColor(Color(argb)));
                _emit();
              },
            ),
            const SizedBox(height: 16),
          ],
          _PresetSwatches(
            onSelected: (argb) {
              setState(() => _hsv = HSVColor.fromColor(Color(argb)));
              _emit();
            },
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
                onPressed: () => widget.onConfirm(_argb),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Colour wheel.
// ---------------------------------------------------------------------------

class _ColorWheel extends StatelessWidget {
  const _ColorWheel({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final void Function(double hue, double saturation) onChanged;

  static const double _size = 180;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: _handle,
      onPanUpdate: _handle,
      onTapDown: _handle,
      child: SizedBox(
        width: _size,
        height: _size,
        child: CustomPaint(
          painter: _WheelPainter(
            hue: hsv.hue,
            saturation: hsv.saturation,
          ),
        ),
      ),
    );
  }

  void _handle(dynamic details) {
    final local = (details as dynamic).localPosition as Offset;
    final dx = local.dx - _size / 2;
    final dy = local.dy - _size / 2;
    final dist = math.sqrt(dx * dx + dy * dy);
    final radius = _size / 2;
    final sat = (dist / radius).clamp(0.0, 1.0);
    var hue = (math.atan2(dy, dx) * 180 / math.pi);
    if (hue < 0) hue += 360;
    onChanged(hue, sat);
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.hue, required this.saturation});

  final double hue;
  final double saturation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    const segments = 64;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Draw a hue wheel as 64 saturated wedges.
    for (var i = 0; i < segments; i++) {
      final a0 = (i / segments) * 2 * math.pi;
      final a1 = ((i + 1) / segments) * 2 * math.pi;
      final hue = (i / segments) * 360;
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(rect, a0, a1 - a0, true)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor()
          ..style = PaintingStyle.fill,
      );
    }

    // Soft white centre so the saturation thumb is readable near the middle.
    canvas.drawCircle(
      center,
      radius * 0.15,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withOpacity(0.85), Colors.white.withOpacity(0)],
        ).createShader(rect),
      );

    // Outline.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = AppTheme.glassBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Thumb.
    final angleRad = hue * math.pi / 180;
    final thumbR = saturation * radius;
    final thumb = Offset(
      center.dx + thumbR * math.cos(angleRad),
      center.dy + thumbR * math.sin(angleRad),
    );
    canvas.drawCircle(
      thumb,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      thumb,
      8,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) =>
      old.hue != hue || old.saturation != saturation;
}

// ---------------------------------------------------------------------------
// Sliders, preview, hex, swatches.
// ---------------------------------------------------------------------------

class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text('Hue',
              style:
                  TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
        ),
        SizedBox(
          height: 22,
          child: GestureDetector(
            onPanUpdate: (d) {
              // Not used — GlassSlider handles input.
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
              child: CustomPaint(
                size: const Size.fromHeight(22),
                painter: _HueBarPainter(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        GlassSlider(
          value: hue,
          min: 0,
          max: 360,
          divisions: 360,
          height: 36,
          accent: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
          onChanged: onChanged,
          valueFormatter: (v) => '${v.round()}°',
        ),
      ],
    );
  }
}

class _HueBarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const steps = 64;
    final w = size.width / steps;
    for (var i = 0; i < steps; i++) {
      final h = (i / steps) * 360;
      canvas.drawRect(
        Rect.fromLTWH(i * w, 0, w + 1, size.height),
        Paint()..color = HSVColor.fromAHSV(1, h, 1, 1).toColor(),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ChannelSlider extends StatelessWidget {
  const _ChannelSlider({
    required this.label,
    required this.value,
    required this.gradient,
    required this.onChanged,
  });

  final String label;
  final double value;
  final Gradient gradient;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.textTertiary, fontSize: 11)),
              const Spacer(),
              Text('${(value * 100).round()}%',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11)),
            ],
          ),
        ),
        SizedBox(
          height: 14,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: gradient),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        const SizedBox(height: 4),
        GlassSlider(
          value: value,
          min: 0,
          max: 1,
          divisions: 100,
          height: 32,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _PreviewSwatch extends StatelessWidget {
  const _PreviewSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: AppTheme.glassBorder),
        boxShadow: AppTheme.glassShadow,
      ),
    );
  }
}

class _HexField extends StatefulWidget {
  const _HexField({required this.color, required this.onSubmitted});

  final Color color;
  final ValueChanged<int> onSubmitted;

  @override
  State<_HexField> createState() => _HexFieldState();
}

class _HexFieldState extends State<_HexField> {
  late TextEditingController _controller;
  late FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _toHex(widget.color));
    _focus = FocusNode();
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        _commit();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _HexField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color && !_focus.hasFocus) {
      _controller.text = _toHex(widget.color);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _toHex(Color c) {
    final a = (c.alpha * 255).round();
    final r = (c.red * 255).round();
    final g = (c.green * 255).round();
    final b = (c.blue * 255).round();
    return '#${a.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${r.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${g.toRadixString(16).padLeft(2, '0').toUpperCase()}'
        '${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }

  void _commit() {
    final raw = _controller.text.trim();
    var hex = raw.startsWith('#') ? raw.substring(1) : raw;
    if (hex.length == 6) hex = 'FF$hex';
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed != null) {
      widget.onSubmitted(parsed);
    } else {
      _controller.text = _toHex(widget.color);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      style: const TextStyle(
        color: AppTheme.textPrimary,
        fontFamily: 'monospace',
        fontSize: 13,
      ),
      textCapitalization: TextCapitalization.characters,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
      ],
      decoration: InputDecoration(
        prefixIcon:
            const Icon(Icons.tag, size: 14, color: AppTheme.textTertiary),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: AppTheme.darkGlass,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          borderSide: BorderSide.none,
        ),
      ),
      onSubmitted: (_) => _commit(),
    );
  }
}

class _PresetSwatches extends StatelessWidget {
  const _PresetSwatches({required this.onSelected});

  final ValueChanged<int> onSelected;

  static const _swatches = <int>[
    0xFF000000, 0xFFFFFFFF, 0xFFFF3B30, 0xFFFF9500, 0xFFFFCC00,
    0xFF34C759, 0xFF30B0C7, 0xFF007AFF, 0xFF5856D6, 0xFFFF2D55,
    0xFFAF52DE, 0xFF5AC8FA, 0xFFFFD60A, 0xFFBF5AF2, 0xFF64D2FF,
    0xFF8E8E93,
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in _swatches)
          GestureDetector(
            onTap: () => onSelected(c),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.glassBorder),
                boxShadow: AppTheme.glassShadow,
              ),
            ),
          ),
      ],
    );
  }
}

/// Dynamic recently-used colour swatches (loop-27). Rendered above the
/// static [_PresetSwatches] when the caller supplies a non-empty history.
class _HistorySwatches extends StatelessWidget {
  const _HistorySwatches({
    required this.history,
    required this.onSelected,
  });

  final List<int> history;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text('Recent',
              style:
                  TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in history)
              GestureDetector(
                onTap: () => onSelected(c),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.glassBorder),
                    boxShadow: AppTheme.glassShadow,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
