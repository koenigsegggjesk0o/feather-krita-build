// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_picker_screen.dart — 3D floating brush space (Feather-style).
//
// The Krita brush presets float as cards on a curved ring in a starlit
// 3D space: drag horizontally to fly along the ring, drag vertically to
// tilt the view, tap a card to pick the preset, long-press for the
// engine-authoritative preset inspector.
//
// Features preserved from the classic picker:
//   - Search + category chips (Basic, Dry Media, Wet Media, Markers,
//     Erasers, Custom).
//   - Sort toggle: Name (library order) or Family — the Family sort
//     re-orders the ring so each engine-declared paintop family forms a
//     contiguous cluster, with a legend chip per family ("<family> ·
//     <count>", alphabetical, undeclared last).
//   - Paintop family badge on every card with a declared family.
//   - Import .kpp button (delegates to [onImport]).
//   - Real Krita preset thumbnails (every stock .kpp carries its own
//     PNG thumbnail — the file itself IS the image).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/widgets/preset_inspector_sheet.dart';

/// The 3D brush preset picker.
class BrushPickerScreen extends StatefulWidget {
  const BrushPickerScreen({
    super.key,
    required this.presets,
    required this.activePresetId,
    required this.onPick,
    required this.onImport,
    required this.onClose,
    this.onOpenFullKrita,
  });

  final List<BrushPreset> presets;
  final String? activePresetId;
  final ValueChanged<BrushPreset> onPick;
  final VoidCallback onImport;
  final VoidCallback onClose;

  /// Launches the FULL official Krita application bundled with the
  /// package (complete krita.org install, unmodified). Nullable: when
  /// absent (dev/test builds without the bundle) the header button is
  /// hidden.
  final VoidCallback? onOpenFullKrita;

  @override
  State<BrushPickerScreen> createState() => _BrushPickerScreenState();
}

class _BrushPickerScreenState extends State<BrushPickerScreen>
    with SingleTickerProviderStateMixin {
  String _query = '';
  String _category = 'All';

  /// Active sort: 'Name' keeps the library order (file scan), 'Family'
  /// clusters the ring by engine-declared paintop family.
  String _sort = 'Name';

  static const _sorts = ['Name', 'Family'];

  static const _categories = [
    'All',
    'Basic',
    'Dry Media',
    'Wet Media',
    'Markers',
    'Erasers',
    'Custom',
  ];

  /// Ring rotation (radians). Card i sits at angle `i * spacing - spin`.
  late final AnimationController _spin;

  /// Vertical view tilt (radians) applied to the whole ring plane.
  double _tilt = 0.0;

  List<BrushPreset> get _ringPresets {
    final list = _filtered;
    if (_sort == 'Family') {
      // Flatten the family groups: each family stays contiguous on the
      // ring (the same grouping as the legend chips).
      return [for (final g in _grouped) ...g.value];
    }
    return list;
  }

  List<BrushPreset> get _filtered {
    final q = _query.toLowerCase();
    final list = widget.presets.where((p) {
      if (_category != 'All' && _classifyPreset(p) != _category) {
        return false;
      }
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q) ||
          p.paintopId.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q);
    }).toList();
    if (_sort == 'Family') {
      list.sort((a, b) {
        final fa = _familyKey(a);
        final fb = _familyKey(b);
        if (fa != fb) return fa.compareTo(fb);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    }
    return list;
  }

  String _familyKey(BrushPreset p) {
    final f = p.paintopId.trim().toLowerCase();
    return f.isEmpty ? kNoFamilyKey : f;
  }

  /// Family clustering for the ring order + legend chips: families
  /// alphabetical, undeclared last, presets by name inside a family.
  List<MapEntry<String, List<BrushPreset>>> get _grouped {
    final map = <String, List<BrushPreset>>{};
    for (final p in _filtered) {
      map.putIfAbsent(_familyKey(p), () => <BrushPreset>[]).add(p);
    }
    for (final list in map.values) {
      list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    final keys = map.keys.toList()..sort();
    return <MapEntry<String, List<BrushPreset>>>[
      for (final k in keys) MapEntry(k, map[k]!),
    ];
  }

  @override
  void initState() {
    super.initState();
    // Initial value FIRST (before any listener exists) so centring the
    // ring can never fire setState during initState.
    _spin = AnimationController.unbounded(
      vsync: this,
      value: ((widget.presets.length - 1) * _kRingSpacing) / 2,
    );
    // Start centred on the middle of the (unfiltered) library so the
    // first thing the user sees is the ring curving away on both sides.
    _spin.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  double get _maxSpin =>
      math.max(0.0, (_ringPresets.length - 1) * _kRingSpacing);

  void _recentreSpin() {
    // Centre the ring on the middle of the current selection.
    _spin.animateTo(
      _maxSpin / 2,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: GlassContainer(
        width: double.infinity,
        height: math.min(640, mq.size.height - 80),
        padding: const EdgeInsets.all(16),
        color: AppTheme.darkGlass.withValues(alpha: 0.7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              onClose: widget.onClose,
              onOpenFullKrita: widget.onOpenFullKrita,
            ),
            const SizedBox(height: 12),
            _SearchBar(
              value: _query,
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 10),
            _CategoryRow(
              categories: _categories,
              selected: _category,
              onSelected: (c) => setState(() => _category = c),
            ),
            const SizedBox(height: 10),
            _SortRow(
              sorts: _sorts,
              selected: _sort,
              onSelected: (s) => setState(() => _sort = s),
              onRecentre: _recentreSpin,
            ),
            if (_sort == 'Family') ...[
              const SizedBox(height: 8),
              _FamilyLegend(groups: _grouped),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _filtered.isEmpty
                  ? const _EmptyState()
                  : _FloatingRing(
                      presets: _ringPresets,
                      activePresetId: widget.activePresetId,
                      spin: _spin,
                      onTilt: (t) => setState(() => _tilt = t),
                      tilt: _tilt,
                      maxSpin: _maxSpin,
                      onPick: widget.onPick,
                      onInspect: (p) => showPresetInspector(context, p),
                    ),
            ),
            const SizedBox(height: 12),
            _BottomBar(
              count: _filtered.length,
              total: widget.presets.length,
              onImport: widget.onImport,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The 3D floating ring.
// ---------------------------------------------------------------------------

/// A starlit space with the preset cards floating on a curved ring.
///
/// Geometry: the viewer floats OUTSIDE a virtual cylinder whose axis is
/// vertical. Card i sits at angle `a = i * spacing - spin`; the front
/// card (a = 0) faces the viewer at full scale, cards toward the arc
/// edge (|a| → [_kArc]) recede, shrink and fade — the classic 3D
/// carousel, hand-projected so hit-testing and text finding stay exact.
class _FloatingRing extends StatefulWidget {
  const _FloatingRing({
    required this.presets,
    required this.activePresetId,
    required this.spin,
    required this.tilt,
    required this.maxSpin,
    required this.onTilt,
    required this.onPick,
    required this.onInspect,
  });

  final List<BrushPreset> presets;
  final String? activePresetId;
  final AnimationController spin;
  final double tilt;
  final double maxSpin;
  final ValueChanged<double> onTilt;
  final ValueChanged<BrushPreset> onPick;
  final void Function(BrushPreset) onInspect;

  @override
  State<_FloatingRing> createState() => _FloatingRingState();
}

class _FloatingRingState extends State<_FloatingRing> {
  void _onPanStart(DragStartDetails details) {
    widget.spin.stop();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final spin = widget.spin;
    spin.value = (spin.value - details.delta.dx * 0.0038)
        .clamp(0.0, widget.maxSpin);
    final tilt = (widget.tilt - details.delta.dy * 0.0016)
        .clamp(-0.22, 0.22);
    widget.onTilt(tilt);
  }

  void _onPanEnd(DragEndDetails details) {
    final v = details.velocity.pixelsPerSecond.dx;
    final target =
        (widget.spin.value - v * 0.00028).clamp(0.0, widget.maxSpin);
    widget.spin.animateTo(
      target,
      duration: const Duration(milliseconds: 640),
      curve: Curves.decelerate,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (w.isNaN || h.isNaN || w < 40 || h < 40) {
          return const SizedBox.shrink();
        }

        // Ring radius + camera distance scale with the stage.
        final radius = (w * 0.5).clamp(240.0, 520.0);
        final camera = w * 1.3;
        final cardW = (w * 0.155).clamp(88.0, 128.0);
        final cardH = cardW * 1.24;

        // Spin is clamped at LAYOUT time (never mutated inside build).
        final spin = widget.spin.value.clamp(0.0, widget.maxSpin);
        final presets = widget.presets;

        // Project every card; keep the visible arc.
        final projections = <_CardProjection>[];
        for (var i = 0; i < presets.length; i++) {
          final a = i * _kRingSpacing - spin;
          if (a.abs() > _kRingArc) continue;
          final z = radius * (1 - math.cos(a));
          final s = camera / (camera + z);
          final sx = camera * radius * math.sin(a) / (camera + z);
          final fade = math.pow(1 - a.abs() / _kRingArc, 1.15).toDouble();
          projections.add(_CardProjection(
            preset: presets[i],
            angle: a,
            screenX: sx,
            scale: s,
            fade: fade,
            // Gentle alternating vertical float so the ring is not a
            // flat conveyor — cards drift up/down like feathers.
            floatY: (i.isEven ? -1.0 : 1.0) * 7.0 * s,
          ));
        }
        // Paint far cards first so the front card wins hit-testing.
        projections.sort((a, b) => b.angle.abs().compareTo(a.angle.abs()));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: ClipRect(
            child: CustomPaint(
              painter: _SpaceDust(spin: spin),
              child: Transform.rotate(
                angle: widget.tilt,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    for (final p in projections)
                      Center(
                        child: Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, 0.0014)
                            ..translate(p.screenX, p.floatY)
                            ..rotateY(p.angle)
                            ..scale(p.scale),
                          child: Opacity(
                            opacity: p.fade.clamp(0.0, 1.0),
                            child: _FloatingCard(
                              preset: p.preset,
                              width: cardW,
                              height: cardH,
                              isActive:
                                  p.preset.id == widget.activePresetId,
                              onTap: () => widget.onPick(p.preset),
                              onInspect: () =>
                                  widget.onInspect(p.preset),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One projected card on the ring.
class _CardProjection {
  const _CardProjection({
    required this.preset,
    required this.angle,
    required this.screenX,
    required this.scale,
    required this.fade,
    required this.floatY,
  });

  final BrushPreset preset;
  final double angle;
  final double screenX;
  final double scale;
  final double fade;
  final double floatY;
}

/// Angular distance between neighbouring cards on the ring (radians).
const double _kRingSpacing = 0.35;

/// Half-width of the visible arc (radians).
const double _kRingArc = 1.15;

/// A single floating preset card: thumbnail, name, category + family
/// badge. Tap picks; long-press opens the preset inspector.
class _FloatingCard extends StatelessWidget {
  const _FloatingCard({
    required this.preset,
    required this.width,
    required this.height,
    required this.isActive,
    required this.onTap,
    required this.onInspect,
  });

  final BrushPreset preset;
  final double width;
  final double height;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onInspect;

  @override
  Widget build(BuildContext context) {
    final accent = isActive ? AppTheme.toolDraw : AppTheme.glassBorder;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onInspect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.toolDraw.withValues(alpha: 0.22)
              : const Color(0xFF202028).withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: accent,
            width: isActive ? 1.6 : 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppTheme.radiusMedium - 0.5)),
                child: _Thumbnail(preset: preset),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    preset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? Colors.white : AppTheme.textPrimary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _classifyPreset(preset),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: 8.5,
                          ),
                        ),
                      ),
                      if (preset.paintopId.trim().isNotEmpty) ...[
                        const SizedBox(width: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.accentSoft,
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusSmall),
                          ),
                          child: Text(
                            preset.paintopId.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.accent,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dim starfield behind the ring. Static dust that parallaxes with the
/// spin (cheap: no ticking animation — it only moves when the ring
/// moves).
class _SpaceDust extends CustomPainter {
  const _SpaceDust({required this.spin});

  final double spin;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.16);
    final rng = math.Random(7);
    final drift = (spin * 26.0) % size.width;
    for (var i = 0; i < 46; i++) {
      final x = (rng.nextDouble() * size.width - drift) % size.width;
      final y = rng.nextDouble() * size.height;
      final r = 0.6 + rng.nextDouble() * 1.6;
      canvas.drawCircle(
        Offset(x < 0 ? x + size.width : x, y),
        r,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpaceDust oldDelegate) => oldDelegate.spin != spin;
}

/// Legend for the Family sort: one chip per engine-declared paintop
/// family with its preset count ("<family> · <count>"), alphabetical,
/// the undeclared sentinel group last (rendered as "No family").
class _FamilyLegend extends StatelessWidget {
  const _FamilyLegend({required this.groups});

  final List<MapEntry<String, List<BrushPreset>>> groups;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final group = groups[index];
          final label =
              group.key == kNoFamilyKey ? 'No family' : group.key;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.accentSoft,
              borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
              border: Border.all(color: AppTheme.accent.withValues(alpha: 0.5)),
            ),
            child: Center(
              child: Text(
                '$label · ${group.value.length}',
                style: const TextStyle(
                  color: AppTheme.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

/// Map a preset's [BrushPreset.category] / paintop to one of our
/// top-level categories.
String _classifyPreset(BrushPreset p) {
  final name = '${p.category} ${p.paintopId} ${p.name}'.toLowerCase();
  if (name.contains('eraser') || name.contains('erase')) return 'Erasers';
  if (name.contains('pencil') ||
      name.contains('chalk') ||
      name.contains('charcoal') ||
      name.contains('pastel')) return 'Dry Media';
  if (name.contains('water') ||
      name.contains('wet') ||
      name.contains('ink') ||
      name.contains('smudge') ||
      name.contains('colorsmudge')) return 'Wet Media';
  if (name.contains('marker') || name.contains('airbrush')) {
    return 'Markers';
  }
  if (p.category.toLowerCase() == 'custom' || name.contains('custom')) {
    return 'Custom';
  }
  return 'Basic';
}

/// Sentinel family key for presets with no declared paintop family
/// (sorts last).
const String kNoFamilyKey = '\uFFFD';

// ---------------------------------------------------------------------------
// Sub-widgets.
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.onClose, this.onOpenFullKrita});

  final VoidCallback onClose;

  /// Launches the bundled full official Krita (hidden when null).
  final VoidCallback? onOpenFullKrita;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: AppTheme.toolDraw,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'Brushes',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'floating in 3D space',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        if (onOpenFullKrita != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.toolExport,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: onOpenFullKrita,
              icon: const Icon(Icons.open_in_new_rounded, size: 15),
              label: const Text(
                'Open full Krita',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.close_rounded, color: AppTheme.textTertiary),
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded,
            size: 18, color: AppTheme.textTertiary),
        suffixIcon: value.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear_rounded,
                    size: 16, color: AppTheme.textTertiary),
                onPressed: () => onChanged(''),
              )
            : null,
        hintText: 'Search brushes…',
        hintStyle: const TextStyle(color: AppTheme.textTertiary, fontSize: 13),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        filled: true,
        fillColor: AppTheme.darkGlassLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final c = categories[index];
          final active = c == selected;
          return GestureDetector(
            onTap: () => onSelected(c),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.toolDraw.withValues(alpha: 0.3)
                    : AppTheme.darkGlassLight,
                borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
                border: Border.all(
                  color: active ? AppTheme.toolDraw : AppTheme.glassBorder,
                  width: active ? 1.2 : 0.5,
                ),
              ),
              child: Center(
                child: Text(
                  c,
                  style: TextStyle(
                    color: active ? Colors.white : AppTheme.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Sort toggle: Name keeps the library order, Family clusters the ring
/// by paintop family (with the legend chips above the ring). The
/// trailing control recentres the ring on the current selection.
class _SortRow extends StatelessWidget {
  const _SortRow({
    required this.sorts,
    required this.selected,
    required this.onSelected,
    required this.onRecentre,
  });

  final List<String> sorts;
  final String selected;
  final ValueChanged<String> onSelected;
  final VoidCallback onRecentre;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Sort',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        ...sorts.map(
          (s) => Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => onSelected(s),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: s == selected
                      ? AppTheme.accentSoft
                      : AppTheme.darkGlassLight,
                  borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
                  border: Border.all(
                    color:
                        s == selected ? AppTheme.accent : AppTheme.glassBorder,
                    width: s == selected ? 1.0 : 0.5,
                  ),
                ),
                child: Text(
                  s,
                  style: TextStyle(
                    color:
                        s == selected ? AppTheme.accent : AppTheme.textTertiary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        const Text(
          'drag to fly',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 9.5,
          ),
        ),
        const SizedBox(width: 4),
        _RecentreButton(onPressed: onRecentre),
      ],
    );
  }
}

/// Small icon control that recentres the floating ring.
class _RecentreButton extends StatelessWidget {
  const _RecentreButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26,
      height: 26,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 15,
        tooltip: 'Centre the ring',
        icon: const Icon(Icons.filter_center_focus_rounded,
            color: AppTheme.textTertiary),
        onPressed: onPressed,
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.preset});

  final BrushPreset preset;

  @override
  Widget build(BuildContext context) {
    if (preset.thumbnail != null && preset.thumbnail!.isNotEmpty) {
      return Image.memory(
        preset.thumbnail!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackIcon(),
      );
    }
    return _fallbackIcon();
  }

  Widget _fallbackIcon() {
    return Container(
      color: const Color(0xFF1A1A22),
      child: const Center(
        child:
            Icon(Icons.brush_rounded, color: AppTheme.textTertiary, size: 28),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded,
              size: 40, color: AppTheme.textTertiary.withValues(alpha: 0.5)),
          const SizedBox(height: 8),
          const Text(
            'No brushes match your search.',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.count,
    required this.total,
    required this.onImport,
  });

  final int count;
  final int total;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          '$count / $total brushes',
          style: const TextStyle(color: AppTheme.textTertiary, fontSize: 11),
        ),
        const Spacer(),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.toolDraw,
            side: const BorderSide(color: AppTheme.toolDraw),
          ),
          onPressed: onImport,
          icon: const Icon(Icons.file_upload_outlined, size: 16),
          label: const Text('Import .kpp'),
        ),
      ],
    );
  }
}
