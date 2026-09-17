// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// settings_screen.dart — Settings screen.
//
// A glassmorphism settings dialog with five cards:
//   - Canvas (resolution, background colour, default guide surface).
//   - Performance (anti-aliasing, max texture size, FPS target).
//   - Stylus (pressure curve, tilt sensitivity, palm rejection).
//   - License / Pro status (current tier + upgrade button).
//   - About (version, credits, links).
//
// All preferences are persisted to [SharedPreferences] and reflected into
// the live [EditorState] where applicable.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/widgets/glass_slider.dart';

/// The settings dialog.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.state,
    required this.onUpgrade,
    required this.onClose,
  });

  final EditorState state;
  final VoidCallback onUpgrade;
  final VoidCallback onClose;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SharedPreferences _prefs;

  // Canvas.
  int _resolution = 2048;
  int _bgColor = 0xFF000000;
  String _guideSurface = 'sphere';

  // Performance.
  bool _antiAlias = true;
  int _maxTexture = 2048;
  int _fpsTarget = 60;

  // Stylus.
  double _pressureCurve = 0.5;
  double _tiltSensitivity = 0.5;
  bool _palmRejection = true;

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _resolution = _prefs.getInt('canvas.resolution') ?? 2048;
      _bgColor = _prefs.getInt('canvas.bgColor') ?? 0xFF000000;
      _guideSurface = _prefs.getString('canvas.guideSurface') ?? 'sphere';
      _antiAlias = _prefs.getBool('perf.antiAlias') ?? true;
      _maxTexture = _prefs.getInt('perf.maxTexture') ?? 2048;
      _fpsTarget = _prefs.getInt('perf.fpsTarget') ?? 60;
      _pressureCurve = _prefs.getDouble('stylus.pressureCurve') ?? 0.5;
      _tiltSensitivity = _prefs.getDouble('stylus.tiltSensitivity') ?? 0.5;
      _palmRejection = _prefs.getBool('stylus.palmRejection') ?? true;
      _loaded = true;
    });
    _applyGuideSurface();
  }

  Future<void> _save(String key, Object value) async {
    if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is double) {
      await _prefs.setDouble(key, value);
    } else if (value is String) {
      await _prefs.setString(key, value);
    }
  }

  void _applyGuideSurface() {
    final g = widget.state.guideSurface;
    if (g.type.name == _guideSurface) return;
    GuideSurface next;
    switch (_guideSurface) {
      case 'cylinder':
        next = GuideSurface.cylinder(radius: 1.2, height: 2.4);
        break;
      case 'cone':
        next = GuideSurface.cone(radius: 1.2, height: 2.4);
        break;
      case 'ring':
        next = GuideSurface.ring(majorRadius: 1.2, minorRadius: 0.25);
        break;
      case 'plane':
        next = GuideSurface.plane(size: 3.0);
        break;
      case 'sphere':
      default:
        next = GuideSurface.sphere(radius: 1.4, segments: 24, rings: 14);
        break;
    }
    widget.state.setGuideSurface(next);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: GlassContainer(
        width: 560,
        height: 640,
        padding: const EdgeInsets.all(16),
        color: AppTheme.darkGlass.withOpacity(0.7),
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(onClose: widget.onClose),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        _CanvasCard(
                          resolution: _resolution,
                          bgColor: _bgColor,
                          guideSurface: _guideSurface,
                          onChanged: (k, v) {
                            setState(() {
                              if (k == 'canvas.resolution') _resolution = v as int;
                              if (k == 'canvas.bgColor') _bgColor = v as int;
                              if (k == 'canvas.guideSurface') {
                                _guideSurface = v as String;
                                _applyGuideSurface();
                              }
                            });
                            _save(k, v);
                          },
                        ),
                        const SizedBox(height: 10),
                        _PerformanceCard(
                          antiAlias: _antiAlias,
                          maxTexture: _maxTexture,
                          fpsTarget: _fpsTarget,
                          onChanged: (k, v) {
                            setState(() {
                              if (k == 'perf.antiAlias') _antiAlias = v as bool;
                              if (k == 'perf.maxTexture') _maxTexture = v as int;
                              if (k == 'perf.fpsTarget') _fpsTarget = v as int;
                            });
                            _save(k, v);
                          },
                        ),
                        const SizedBox(height: 10),
                        _StylusCard(
                          pressureCurve: _pressureCurve,
                          tiltSensitivity: _tiltSensitivity,
                          palmRejection: _palmRejection,
                          onChanged: (k, v) {
                            setState(() {
                              if (k == 'stylus.pressureCurve') {
                                _pressureCurve = v as double;
                              }
                              if (k == 'stylus.tiltSensitivity') {
                                _tiltSensitivity = v as double;
                              }
                              if (k == 'stylus.palmRejection') {
                                _palmRejection = v as bool;
                              }
                            });
                            _save(k, v);
                          },
                        ),
                        const SizedBox(height: 10),
                        _LicenseCard(
                          isPro: widget.state.isPro,
                          onUpgrade: widget.onUpgrade,
                        ),
                        const SizedBox(height: 10),
                        const _AboutCard(),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header + cards.
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: AppTheme.primaryPurple,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'Settings',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close_rounded, color: AppTheme.textTertiary),
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: const EdgeInsets.all(14),
      borderRadius: AppTheme.radiusLarge,
      color: AppTheme.darkGlassLight.withOpacity(0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                  color: AppTheme.textTertiary, fontSize: 11),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _CanvasCard extends StatelessWidget {
  const _CanvasCard({
    required this.resolution,
    required this.bgColor,
    required this.guideSurface,
    required this.onChanged,
  });

  final int resolution;
  final int bgColor;
  final String guideSurface;
  final void Function(String key, Object value) onChanged;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      title: 'Canvas',
      icon: Icons.crop_landscape_rounded,
      child: Column(
        children: [
          _Row(
            label: 'Resolution',
            child: DropdownButton<int>(
              value: resolution,
              dropdownColor: AppTheme.darkSurface,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              underline: const SizedBox(),
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 1024, child: Text('1024 × 1024')),
                DropdownMenuItem(value: 2048, child: Text('2048 × 2048')),
                DropdownMenuItem(value: 4096, child: Text('4096 × 4096')),
              ],
              onChanged: (v) {
                if (v != null) onChanged('canvas.resolution', v);
              },
            ),
          ),
          _Row(
            label: 'Background',
            child: Row(
              children: [
                GestureDetector(
                  onTap: () async {
                    // Cycle background colour through a small palette.
                    const palette = [
                      0xFF000000, 0xFF1A1A1A, 0xFFFFFFFF,
                      0xFF2B2B3A, 0xFF102018,
                    ];
                    final idx = (palette.indexOf(bgColor) + 1) % palette.length;
                    onChanged('canvas.bgColor', palette[idx]);
                  },
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(bgColor),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppTheme.glassBorder),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '#${(bgColor & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          _Row(
            label: 'Guide surface',
            child: DropdownButton<String>(
              value: guideSurface,
              dropdownColor: AppTheme.darkSurface,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              underline: const SizedBox(),
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'sphere', child: Text('Sphere')),
                DropdownMenuItem(value: 'cylinder', child: Text('Cylinder')),
                DropdownMenuItem(value: 'cone', child: Text('Cone')),
                DropdownMenuItem(value: 'ring', child: Text('Ring / Torus')),
                DropdownMenuItem(value: 'plane', child: Text('Plane')),
              ],
              onChanged: (v) {
                if (v != null) onChanged('canvas.guideSurface', v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({
    required this.antiAlias,
    required this.maxTexture,
    required this.fpsTarget,
    required this.onChanged,
  });

  final bool antiAlias;
  final int maxTexture;
  final int fpsTarget;
  final void Function(String key, Object value) onChanged;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      title: 'Performance',
      icon: Icons.speed_rounded,
      child: Column(
        children: [
          _Row(
            label: 'Anti-aliasing',
            child: Align(
              alignment: Alignment.centerRight,
              child: Switch.adaptive(
                value: antiAlias,
                activeColor: AppTheme.accent,
                onChanged: (v) => onChanged('perf.antiAlias', v),
              ),
            ),
          ),
          _Row(
            label: 'Texture size',
            child: DropdownButton<int>(
              value: maxTexture,
              dropdownColor: AppTheme.darkSurface,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              underline: const SizedBox(),
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 1024, child: Text('1024 px')),
                DropdownMenuItem(value: 2048, child: Text('2048 px')),
                DropdownMenuItem(value: 4096, child: Text('4096 px')),
              ],
              onChanged: (v) {
                if (v != null) onChanged('perf.maxTexture', v);
              },
            ),
          ),
          _Row(
            label: 'FPS target',
            child: DropdownButton<int>(
              value: fpsTarget,
              dropdownColor: AppTheme.darkSurface,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              underline: const SizedBox(),
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 30, child: Text('30 FPS (battery)')),
                DropdownMenuItem(value: 60, child: Text('60 FPS (balanced)')),
                DropdownMenuItem(value: 120, child: Text('120 FPS (smooth)')),
              ],
              onChanged: (v) {
                if (v != null) onChanged('perf.fpsTarget', v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StylusCard extends StatelessWidget {
  const _StylusCard({
    required this.pressureCurve,
    required this.tiltSensitivity,
    required this.palmRejection,
    required this.onChanged,
  });

  final double pressureCurve;
  final double tiltSensitivity;
  final bool palmRejection;
  final void Function(String key, Object value) onChanged;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      title: 'Stylus',
      icon: Icons.draw_rounded,
      child: Column(
        children: [
          GlassSlider(
            value: pressureCurve,
            min: 0,
            max: 1,
            divisions: 100,
            label: 'Pressure curve',
            icon: Icons.show_chart_rounded,
            accent: AppTheme.toolDraw,
            onChanged: (v) => onChanged('stylus.pressureCurve', v),
            valueFormatter: (v) => v.toStringAsFixed(2),
          ),
          const SizedBox(height: 6),
          GlassSlider(
            value: tiltSensitivity,
            min: 0,
            max: 1,
            divisions: 100,
            label: 'Tilt sensitivity',
            icon: Icons.rounded_corner,
            accent: AppTheme.toolSelect,
            onChanged: (v) => onChanged('stylus.tiltSensitivity', v),
            valueFormatter: (v) => '${(v * 100).round()}%',
          ),
          _Row(
            label: 'Palm rejection',
            child: Align(
              alignment: Alignment.centerRight,
              child: Switch.adaptive(
                value: palmRejection,
                activeColor: AppTheme.accent,
                onChanged: (v) => onChanged('stylus.palmRejection', v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LicenseCard extends StatelessWidget {
  const _LicenseCard({required this.isPro, required this.onUpgrade});

  final bool isPro;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      title: 'License',
      icon: Icons.workspace_premium_rounded,
      child: Row(
        children: [
          Icon(
            isPro ? Icons.verified_rounded : Icons.lock_outline_rounded,
            color: isPro ? AppTheme.toolExport : AppTheme.textTertiary,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isPro ? 'Feather-Krita Pro' : 'Free tier',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isPro
                      ? 'All formats and tools unlocked. Thank you!'
                      : 'Upgrade to unlock GIF, MP4, glTF and more.',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
          if (!isPro)
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.toolExport),
              onPressed: onUpgrade,
              child: const Text('Upgrade'),
            ),
        ],
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      title: 'About',
      icon: Icons.info_outline_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Feather-Krita · v1.0.0',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 4),
          Text(
            '3D drawing app with the Krita brush engine. Inspired by Feather 3D.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
          ),
          SizedBox(height: 6),
          Text(
            'Licensed under GPL-2.0-or-later. © 2026 Feather-Krita App Contributors.',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
