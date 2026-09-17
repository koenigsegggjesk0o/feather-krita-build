// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// glass_bottom_bar.dart — Feather 3D style bottom tool dock.
//
// A floating glassmorphism toolbar pinned to the bottom centre of the
// editor. It exposes the eight primary tools (Draw, Erase, Shapes,
// Liquify, Select, Light, Export, Settings) as [GlassButton]s. The active
// tool is rendered with its accent colour and a soft glow.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/state/editor_state.dart';

/// A floating glass bottom dock with the eight primary tools.
class GlassBottomBar extends StatelessWidget {
  const GlassBottomBar({
    super.key,
    required this.activeTool,
    required this.onToolSelected,
  });

  final Tool activeTool;
  final ValueChanged<Tool> onToolSelected;

  static const _tools = <_ToolSpec>[
    _ToolSpec(Tool.draw, Icons.brush_rounded, 'Draw', AppTheme.toolDraw),
    _ToolSpec(Tool.erase, Icons.auto_fix_high_rounded, 'Erase', AppTheme.toolErase),
    _ToolSpec(Tool.shapes, Icons.category_rounded, 'Shapes', AppTheme.toolShape),
    _ToolSpec(Tool.liquify, Icons.water_drop_rounded, 'Liquify', AppTheme.toolLiquify),
    _ToolSpec(Tool.select, Icons.near_me_rounded, 'Select', AppTheme.toolSelect),
    _ToolSpec(Tool.light, Icons.wb_incandescent_rounded, 'Light', AppTheme.toolLight),
    _ToolSpec(Tool.export, Icons.ios_share_rounded, 'Export', AppTheme.toolExport),
    _ToolSpec(Tool.settings, Icons.settings_rounded, 'Settings', AppTheme.primaryPurple),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      borderRadius: AppTheme.radiusXLarge,
      color: AppTheme.darkGlass.withOpacity(0.55),
      shadows: const [
        BoxShadow(color: Color(0x55000000), blurRadius: 24, offset: Offset(0, 8)),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _tools.length; i++) ...[
            if (i == 6) const _Divider(),
            if (i > 0 && i != 6) const SizedBox(width: 6),
            _ToolButton(
              spec: _tools[i],
              isSelected: activeTool == _tools[i].tool,
              onTap: () {
                HapticFeedback.selectionClick();
                onToolSelected(_tools[i].tool);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolSpec {
  const _ToolSpec(this.tool, this.icon, this.label, this.color);
  final Tool tool;
  final IconData icon;
  final String label;
  final Color color;
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.spec,
    required this.isSelected,
    required this.onTap,
  });

  final _ToolSpec spec;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isSelected ? 1.08 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: GlassButton(
        icon: spec.icon,
        label: spec.label,
        isSelected: isSelected,
        color: spec.color,
        size: 56,
        onTap: onTap,
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: AppTheme.glassBorder,
    );
  }
}
