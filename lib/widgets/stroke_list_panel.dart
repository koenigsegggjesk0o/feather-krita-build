// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// stroke_list_panel.dart — Left sidebar stroke list.
//
// A glassmorphism panel showing every stroke in the document. Each row
// supports:
//   - Selection (tap; multi-select via toggle).
//   - Visibility toggle (eye icon).
//   - Delete (trash icon).
//   - Reorder via drag-and-drop (the underlying [StrokeManager] list is
//     reordered in place through the public JSON save/load API).
//
// The panel listens to [StrokeManager] (a [ChangeNotifier]) and rebuilds
// whenever the stroke list changes.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/engine/stroke_manager.dart';
import 'package:feather_krita/models/stroke.dart';

/// The left-side stroke list panel.
class StrokeListPanel extends StatelessWidget {
  const StrokeListPanel({
    super.key,
    required this.manager,
    this.onClose,
  });

  final StrokeManager manager;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      width: 260,
      padding: const EdgeInsets.all(12),
      borderRadius: AppTheme.radiusLarge,
      color: AppTheme.darkGlass.withOpacity(0.55),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            count: manager.strokeCount,
            selected: manager.selectedIds.length,
            onClose: onClose,
            onSelectAll: manager.selectAll,
            onClearSelection: manager.clearSelection,
          ),
          const SizedBox(height: 8),
          Flexible(
            child: AnimatedBuilder(
              animation: manager,
              builder: (context, _) {
                final strokes = manager.strokes;
                if (strokes.isEmpty) {
                  return const _EmptyState();
                }
                return ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: strokes.length,
                  onReorder: (oldIndex, newIndex) =>
                      _reorder(manager, oldIndex, newIndex),
                  itemBuilder: (context, index) {
                    final stroke = strokes[index];
                    return _StrokeRow(
                      key: ValueKey(stroke.id),
                      stroke: stroke,
                      index: index,
                      selected: manager.selectedIds.contains(stroke.id),
                      onTap: () => manager.toggleSelection(stroke.id),
                      onToggleVisible: () {
                        stroke.isVisible = !stroke.isVisible;
                        manager.notify();
                      },
                      onDelete: () => manager.removeStroke(stroke.id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Reorders the strokes list in the [manager] via its public JSON
  /// save/load API. Reorder is treated as a UI preference and does NOT
  /// record an undo entry.
  static void _reorder(StrokeManager m, int oldIndex, int newIndexRaw) {
    var newIndex = newIndexRaw;
    if (oldIndex < newIndex) newIndex -= 1;
    final strokes = m.strokes;
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 ||
        oldIndex >= strokes.length ||
        newIndex < 0 ||
        newIndex >= strokes.length) {
      return;
    }
    final reordered = List<Stroke>.from(strokes);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);

    var maxId = 0;
    for (final s in reordered) {
      if (s.id > maxId) maxId = s.id;
    }

    final json = {
      'strokes': reordered.map((s) => s.toJson()).toList(),
      'selectedIds': m.selectedIds.toList(),
      'nextId': maxId + 1,
      'mirror': m.mirror.toJson(),
    };
    m.fromJsonString(jsonEncode(json), recordUndo: false);
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets.
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.count,
    required this.selected,
    this.onClose,
    required this.onSelectAll,
    required this.onClearSelection,
  });

  final int count;
  final int selected;
  final VoidCallback? onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: AppTheme.toolSelect,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        // Expanded + ellipsis: keeps the header from overflowing when the
        // title (or a localized equivalent) is wider than the panel.
        const Expanded(
          child: Text(
            'Layers',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: AppTheme.darkGlassLight,
            borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              color: AppTheme.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.select_all_rounded, size: 16),
          color: AppTheme.textTertiary,
          tooltip: 'Select all',
          onPressed: onSelectAll,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: const Icon(Icons.deselect_rounded, size: 16),
          color: AppTheme.textTertiary,
          tooltip: 'Clear selection',
          onPressed: selected > 0 ? onClearSelection : null,
          visualDensity: VisualDensity.compact,
        ),
        if (onClose != null)
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 16),
            color: AppTheme.textTertiary,
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.brush_outlined,
              size: 32, color: AppTheme.textTertiary.withOpacity(0.5)),
          const SizedBox(height: 8),
          const Text(
            'No strokes yet',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
          ),
          const SizedBox(height: 2),
          const Text(
            'Draw on the canvas to add a stroke.',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _StrokeRow extends StatelessWidget {
  const _StrokeRow({
    super.key,
    required this.stroke,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onToggleVisible,
    required this.onDelete,
  });

  final Stroke stroke;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleVisible;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.toolSelect.withOpacity(0.22)
            : AppTheme.darkGlassLight.withOpacity(0.4),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: selected ? AppTheme.toolSelect : AppTheme.glassBorder,
          width: selected ? 1.5 : 0.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.drag_indicator_rounded,
                      size: 18, color: AppTheme.textTertiary),
                ),
              ),
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Color(stroke.color),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      stroke.name ??
                          (stroke.mirrorOfId != null
                              ? 'Stroke ${stroke.id} (mirror)'
                              : 'Stroke ${stroke.id}'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: stroke.isVisible
                            ? AppTheme.textPrimary
                            : AppTheme.textTertiary,
                        fontSize: 12,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    Text(
                      '${stroke.points.length} pts · ${stroke.brushType.name}',
                      style: const TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onToggleVisible,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    stroke.isVisible
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    size: 16,
                    color: stroke.isVisible
                        ? AppTheme.textSecondary
                        : AppTheme.textTertiary,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onDelete,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline_rounded,
                      size: 16, color: AppTheme.toolErase),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
