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
//   - Import .kpp button (delegates to [onImport]).
//   - Selecting a preset calls [onPick] and closes the sheet.

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/models/brush_preset.dart';

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

  static const _categories = [
    'All',
    'Basic',
    'Dry Media',
    'Wet Media',
    'Markers',
    'Erasers',
    'Custom',
  ];

  /// Map a preset's [BrushPreset.category] / paintop to one of our
  /// top-level categories.
  String _classify(BrushPreset p) {
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

  List<BrushPreset> get _filtered {
    final q = _query.toLowerCase();
    return widget.presets.where((p) {
      if (_category != 'All' && _classify(p) != _category) return false;
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q) ||
          p.paintopId.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q);
    }).toList();
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
            const SizedBox(height: 12),
            Expanded(
              child: _filtered.isEmpty
                  ? const _EmptyState()
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 160,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.85,
                      ),
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final p = _filtered[index];
                        return _PresetCard(
                          preset: p,
                          category: _classify(p),
                          isActive: p.id == widget.activePresetId,
                          onTap: () {
                            widget.onPick(p);
                          },
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
        prefixIcon:
            const Icon(Icons.search_rounded, size: 18, color: AppTheme.textTertiary),
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

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.category,
    required this.isActive,
    required this.onTap,
  });

  final BrushPreset preset;
  final String category;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
                  Text(
                    '$category · ${preset.paintopId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 9,
                    ),
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
        child: Icon(Icons.brush_rounded, color: AppTheme.textTertiary, size: 28),
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
