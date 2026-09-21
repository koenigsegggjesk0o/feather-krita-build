// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_picker_screen.dart — Brush preset picker.
//
// A glassmorphism full-screen sheet that browses the available Krita brush
// presets. Features:
//   - Searchable grid of preset cards (thumbnail + name + category).
//   - Category filter chips: Basic, Dry Media, Wet Media, Markers, Erasers,
//     Custom.
//   - Sort toggle (5-loop-42): Name (library order) or Family.
//   - Family-grouped browsing (5-loop-48): with the Family sort active
//     the grid becomes SECTIONS — one per engine-declared paintop family
//     ([BrushPreset.paintopId], upgraded with the real engine's
//     scan-ABI families by EditorState.loadPresetLibrary) — each with a
//     "family · count" header, alphabetical, undeclared last.
//     Each card also carries the paintop family badge (5-loop-42).
//   - Import .kpp button (delegates to [onImport]).
//   - Selecting a preset calls [onPick] and closes the sheet.
//   - Preset inspector (5-loop-65): LONG-PRESS a preset card to open the
//     engine-authoritative inspector ([showPresetInspector]) — curated
//     identity fields plus the full raw paintop-settings map from the
//     5-loop-63 param-map ABI. Picking still works with a plain tap.

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/widgets/preset_inspector_sheet.dart';

/// The brush preset picker.
class BrushPickerScreen extends StatefulWidget {
  const BrushPickerScreen({
    super.key,
    required this.presets,
    required this.activePresetId,
    required this.onPick,
    required this.onImport,
    required this.onClose,
  });

  final List<BrushPreset> presets;
  final String? activePresetId;
  final ValueChanged<BrushPreset> onPick;
  final VoidCallback onImport;
  final VoidCallback onClose;

  @override
  State<BrushPickerScreen> createState() => _BrushPickerScreenState();
}

class _BrushPickerScreenState extends State<BrushPickerScreen> {
  String _query = '';
  String _category = 'All';

  /// Active sort: 'Name' keeps the library order (file scan), 'Family'
  /// groups presets by paintop family (5-loop-42).
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

  List<BrushPreset> get _filtered {
    final q = _query.toLowerCase();
    final list = widget.presets.where((p) {
      if (_category != 'All' && _classifyPreset(p) != _category) return false;
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q) ||
          p.paintopId.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q);
    }).toList();
    if (_sort == 'Family') {
      // Group by paintop family: declared families alphabetically, then
      // name within a family. Undeclared families sort last so presets
      // without a root attribute never break the grouping up.
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

  /// Family-grouped browsing (5-loop-48): when the Family sort is active
  /// the picker renders one section per engine-declared paintop family
  /// ([BrushPreset.paintopId] — upgraded with the real engine's scan-ABI
  /// families by [EditorState.loadPresetLibrary]) instead of a flat grid.
  /// Families alphabetical, the undeclared group last — the same ordering
  /// contract as the former flat Family sort; within a family, presets
  /// sort by name.
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
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: GlassContainer(
        width: double.infinity,
        height: 640,
        padding: const EdgeInsets.all(16),
        color: AppTheme.darkGlass.withOpacity(0.7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onClose: widget.onClose),
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
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _filtered.isEmpty
                  ? const _EmptyState()
                  : _sort == 'Family'
                      ? _FamilySectionedGrid(
                          groups: _grouped,
                          activePresetId: widget.activePresetId,
                          onPick: widget.onPick,
                          onInspect: (p) => showPresetInspector(context, p),
                        )
                      : GridView.builder(
                          gridDelegate: _kPresetGridDelegate,
                          itemCount: _filtered.length,
                          itemBuilder: (context, index) {
                            final p = _filtered[index];
                            return _PresetCard(
                              preset: p,
                              category: _classifyPreset(p),
                              isActive: p.id == widget.activePresetId,
                              onTap: () {
                                widget.onPick(p);
                              },
                              onInspect: () => showPresetInspector(context, p),
                            );
                          },
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
  if (name.contains('marker') || name.contains('airbrush')) return 'Markers';
  if (p.category.toLowerCase() == 'custom' || name.contains('custom')) {
    return 'Custom';
  }
  return 'Basic';
}

/// Shared grid geometry for the flat browse grid and the per-family
/// section grids (5-loop-48).
const SliverGridDelegateWithMaxCrossAxisExtent _kPresetGridDelegate =
    SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 160,
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  childAspectRatio: 0.85,
);

/// Sentinel family key used by [_BrushPickerScreenState._familyKey] for
/// presets with no declared paintop family (sorts last).
const String kNoFamilyKey = '\uFFFD';

/// Family-grouped browsing (5-loop-48): one header + one grid per
/// engine-declared paintop family, replacing the flat grid while the
/// Family sort is active. Filtering/search still applies (the groups
/// come from the picker's filtered list).
class _FamilySectionedGrid extends StatelessWidget {
  const _FamilySectionedGrid({
    required this.groups,
    required this.activePresetId,
    required this.onPick,
    required this.onInspect,
  });

  final List<MapEntry<String, List<BrushPreset>>> groups;
  final String? activePresetId;
  final ValueChanged<BrushPreset> onPick;

  /// Long-press on any card in this family section opens the inspector
  /// for that preset (5-loop-65).
  final void Function(BrushPreset) onInspect;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        for (final group in groups) ...[
          SliverToBoxAdapter(
            child: _FamilyHeader(
              family: group.key,
              count: group.value.length,
            ),
          ),
          SliverGrid(
            gridDelegate: _kPresetGridDelegate,
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final p = group.value[index];
                return _PresetCard(
                  preset: p,
                  category: _classifyPreset(p),
                  isActive: p.id == activePresetId,
                  onTap: () => onPick(p),
                  onInspect: () => onInspect(p),
                );
              },
              childCount: group.value.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
        ],
      ],
    );
  }
}

/// Section header for one paintop family group: an accent bar, the
/// family name and the preset count ("paintbrush · 2"). The undeclared
/// sentinel group is displayed as "No family".
class _FamilyHeader extends StatelessWidget {
  const _FamilyHeader({required this.family, required this.count});

  final String family;
  final int count;

  @override
  Widget build(BuildContext context) {
    final label = family == kNoFamilyKey ? 'No family' : family;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: AppTheme.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$label · $count',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets.
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
        const Spacer(),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.toolDraw.withOpacity(0.3)
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

/// Sort toggle (5-loop-42): Name keeps the library order, Family groups
/// presets by paintop family.
class _SortRow extends StatelessWidget {
  const _SortRow({
    required this.sorts,
    required this.selected,
    required this.onSelected,
  });

  final List<String> sorts;
  final String selected;
  final ValueChanged<String> onSelected;

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
      ],
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.category,
    required this.isActive,
    required this.onTap,
    required this.onInspect,
  });

  final BrushPreset preset;
  final String category;
  final bool isActive;
  final VoidCallback onTap;

  /// Long-press: opens the engine-authoritative preset inspector
  /// ([showPresetInspector]) without picking the preset (5-loop-65).
  final VoidCallback onInspect;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onInspect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.toolDraw.withOpacity(0.22)
              : AppTheme.darkGlassLight.withOpacity(0.5),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: isActive ? AppTheme.toolDraw : AppTheme.glassBorder,
            width: isActive ? 1.5 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail.
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppTheme.radiusMedium - 0.5)),
                child: _Thumbnail(preset: preset),
              ),
            ),
            // Label.
            Padding(
              padding: const EdgeInsets.all(8),
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
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          category,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: 9,
                          ),
                        ),
                      ),
                      // Paintop family badge (5-loop-42) — mirrors the
                      // panel chip; hidden for presets without a
                      // declared family.
                      if (preset.paintopId.trim().isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
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
                              fontSize: 8,
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
              size: 40, color: AppTheme.textTertiary.withOpacity(0.5)),
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
