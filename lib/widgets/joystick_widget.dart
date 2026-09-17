// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// joystick_widget.dart — Virtual 3D manipulation joystick.
//
// A floating glassmorphism joystick (Feather 3D style) that the user
// drags to drive the four manipulation modes:
//   - Move    → translates the selection in the XY plane.
//   - Rotate  → spins the selection around X / Y.
//   - Scale   → drag up = grow, drag down = shrink.
//   - Liquify → applies a liquify deformation along the drag direction.
//
// The knob returns to the centre with a spring animation on release. A
// coloured glow surrounds the joystick while it is active and haptic
// feedback is fired at the start of a drag and when crossing axis
// thresholds. The active mode is reported via [onModeChanged] and the
// normalised input vector (range [-1, 1] × [-1, 1]) via [onInput].

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2;

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/state/editor_state.dart';

/// A floating 3D manipulation joystick.
class JoystickWidget extends StatefulWidget {
  const JoystickWidget({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.onInput,
    this.size = 140,
  });

  final JoystickMode mode;
  final ValueChanged<JoystickMode> onModeChanged;
  final ValueChanged<Vector2> onInput;
  final double size;

  @override
  State<JoystickWidget> createState() => _JoystickWidgetState();
}

class _JoystickWidgetState extends State<JoystickWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _return;
  Offset _knob = Offset.zero;
  bool _dragging = false;
  bool _hapticX = false;
  bool _hapticY = false;

  static const _modes = <JoystickMode, _ModeSpec>{
    JoystickMode.move: _ModeSpec('Move', Icons.open_with_rounded, AppTheme.accent),
    JoystickMode.rotate:
        _ModeSpec('Rotate', Icons.rotate_90_degrees_ccw_rounded, AppTheme.toolShape),
    JoystickMode.scale:
        _ModeSpec('Scale', Icons.transform_rounded, AppTheme.toolLiquify),
    JoystickMode.liquify:
        _ModeSpec('Liquify', Icons.water_drop_rounded, AppTheme.toolLiquify),
  };

  @override
  void initState() {
    super.initState();
    _return = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _return.addListener(() {
      setState(() {
        _knob = Offset.lerp(_knob, Offset.zero, _return.value)!;
      });
    });
  }

  @override
  void dispose() {
    _return.dispose();
    super.dispose();
  }

  double get _radius => widget.size / 2;

  void _onPanStart(DragStartDetails _) {
    _return.stop();
    setState(() => _dragging = true);
    HapticFeedback.lightImpact();
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final maxKnob = _radius - 22;
    final next = (_knob + d.delta);
    final dist = next.distance;
    final clamped = dist > maxKnob ? next.scale(maxKnob / dist, maxKnob / dist) : next;
    setState(() => _knob = clamped);

    // Haptic feedback when crossing the centre axes.
    if ((_knob.dx.abs() < 2) != _hapticX) {
      _hapticX = !_hapticX;
      HapticFeedback.selectionClick();
    }
    if ((_knob.dy.abs() < 2) != _hapticY) {
      _hapticY = !_hapticY;
      HapticFeedback.selectionClick();
    }

    final nx = (clamped.dx / maxKnob).clamp(-1.0, 1.0);
    final ny = (-clamped.dy / maxKnob).clamp(-1.0, 1.0);
    widget.onInput(Vector2(nx, ny));
  }

  void _onPanEnd(DragEndDetails _) {
    setState(() => _dragging = false);
    widget.onInput(Vector2.zero());
    _hapticX = _hapticY = false;
    _return.forward(from: 0);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final spec = _modes[widget.mode]!;
    return GlassContainer(
      width: widget.size + 16,
      padding: const EdgeInsets.all(8),
      borderRadius: AppTheme.radiusXLarge,
      color: AppTheme.darkGlass.withOpacity(0.55),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            spec.label,
            style: TextStyle(
              color: spec.color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Base.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.darkGlassLight.withOpacity(0.4),
                      border: Border.all(
                        color: _dragging ? spec.color : AppTheme.glassBorder,
                        width: _dragging ? 2 : 1,
                      ),
                      boxShadow: [
                        if (_dragging)
                          BoxShadow(
                            color: spec.color.withOpacity(0.45),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                      ],
                    ),
                  ),
                  // Cross hair.
                  CustomPaint(
                    size: Size(widget.size, widget.size),
                    painter: _CrossHairPainter(color: AppTheme.glassBorder),
                  ),
                  // Knob.
                  Transform.translate(
                    offset: _knob,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            spec.color.withOpacity(0.95),
                            spec.color.withOpacity(0.65),
                          ],
                        ),
                        border: Border.all(color: Colors.white60, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: spec.color.withOpacity(0.7),
                            blurRadius: _dragging ? 16 : 8,
                            spreadRadius: _dragging ? 2 : 0,
                          ),
                        ],
                      ),
                      child: Icon(spec.icon, color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Mode switcher.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in JoystickMode.values) ...[
                if (m != JoystickMode.values.first) const SizedBox(width: 4),
                _ModeChip(
                  icon: _modes[m]!.icon,
                  color: _modes[m]!.color,
                  isSelected: widget.mode == m,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onModeChanged(m);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeSpec {
  const _ModeSpec(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.icon,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.35) : AppTheme.darkGlass,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? color : AppTheme.glassBorder,
            width: isSelected ? 1.5 : 0.5,
          ),
        ),
        child: Icon(icon, size: 14, color: isSelected ? Colors.white : AppTheme.textTertiary),
      ),
    );
  }
}

class _CrossHairPainter extends CustomPainter {
  const _CrossHairPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.shortestSide / 2;
    canvas.drawLine(Offset(cx, cy - r), Offset(cx, cy + r), paint);
    canvas.drawLine(Offset(cx - r, cy), Offset(cx + r, cy), paint);
    canvas.drawCircle(Offset(cx, cy), r * 0.5, paint);
    canvas.drawCircle(Offset(cx, cy), r * 0.85, paint);
  }

  @override
  bool shouldRepaint(covariant _CrossHairPainter old) => old.color != color;
}

// (math import is used by callers that consume the input vector; keep the
// dart:math import available for future axis-angle maths on this widget.)
// ignore: unused_element
double _deg(double rad) => rad * 180.0 / math.pi;
