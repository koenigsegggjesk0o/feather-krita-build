// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// main_screen.dart — Main editor screen (simplified for beta)
//

import 'package:flutter/material.dart';
import 'package:feather_krita/theme/app_theme.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedTool = 0;
  double _brushSize = 50;
  double _opacity = 100;
  Color _currentColor = const Color(0xFF007AFF);

  final List<_ToolItem> _tools = [
    _ToolItem(icon: Icons.brush, label: 'Draw', color: AppTheme.toolDraw),
    _ToolItem(icon: Icons.auto_fix_high, label: 'Erase', color: AppTheme.toolErase),
    _ToolItem(icon: Icons.category, label: 'Shapes', color: AppTheme.toolShape),
    _ToolItem(icon: Icons.waves, label: 'Liquify', color: AppTheme.toolLiquify),
    _ToolItem(icon: Icons.select_all, label: 'Select', color: AppTheme.toolSelect),
    _ToolItem(icon: Icons.light_mode, label: 'Light', color: AppTheme.toolLight),
    _ToolItem(icon: Icons.download, label: 'Export', color: AppTheme.toolExport),
    _ToolItem(icon: Icons.settings, label: 'Settings', color: Colors.grey),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.canvasBackground,
      body: SafeArea(
        child: Stack(
          children: [
            // 3D Canvas placeholder
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.8,
                    colors: [Color(0xFF1A1A2E), Color(0xFF000000)],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.view_in_ar,
                        size: 80,
                        color: Colors.white24,
                      ),
                      SizedBox(height: 16),
                      Text(
                        '3D Canvas',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 24,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Touch to draw on 3D surface',
                        style: TextStyle(
                          color: Colors.white24,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Top bar
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: GlassContainer(
                height: 50,
                borderRadius: AppTheme.radiusMedium,
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.brush, color: AppTheme.primaryBlue, size: 24),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Untitled.feather',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.undo, color: Colors.white70),
                      onPressed: () {},
                    ),
                    IconButton(
                      icon: Icon(Icons.redo, color: Colors.white70),
                      onPressed: () {},
                    ),
                    IconButton(
                      icon: Icon(Icons.folder_open, color: Colors.white70),
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),

            // Right panel — brush settings
            Positioned(
              top: 75,
              right: 12,
              bottom: 100,
              width: 260,
              child: GlassContainer(
                borderRadius: AppTheme.radiusLarge,
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Brush Settings',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 20),
                    // Brush size
                    Text('Size: ${_brushSize.round()}px',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                    Slider(
                      value: _brushSize,
                      min: 1,
                      max: 500,
                      activeColor: AppTheme.primaryBlue,
                      onChanged: (v) => setState(() => _brushSize = v),
                    ),
                    SizedBox(height: 8),
                    // Opacity
                    Text('Opacity: ${_opacity.round()}%',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                    Slider(
                      value: _opacity,
                      min: 0,
                      max: 100,
                      activeColor: AppTheme.primaryBlue,
                      onChanged: (v) => setState(() => _opacity = v),
                    ),
                    SizedBox(height: 16),
                    // Color
                    Text('Color',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                    SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AppTheme.primaryBlue,
                        AppTheme.primaryPurple,
                        AppTheme.primaryPink,
                        AppTheme.primaryOrange,
                        AppTheme.primaryGreen,
                        AppTheme.primaryTeal,
                        Colors.white,
                        Colors.black,
                      ].map((c) {
                        return GestureDetector(
                          onTap: () => setState(() => _currentColor = c),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: c,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _currentColor == c
                                    ? Colors.white
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    Spacer(),
                    // Brush preset
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.brush, color: Colors.white70, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Basic Round',
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Colors.white54),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom toolbar
            Positioned(
              bottom: 12,
              left: 12,
              right: 12,
              child: GlassContainer(
                height: 72,
                borderRadius: AppTheme.radiusXLarge,
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(_tools.length, (i) {
                    final tool = _tools[i];
                    return GestureDetector(
                      onTap: () => setState(() => _selectedTool = i),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: _selectedTool == i
                              ? tool.color.withOpacity(0.3)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _selectedTool == i
                                ? tool.color
                                : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              tool.icon,
                              color: _selectedTool == i
                                  ? Colors.white
                                  : Colors.white60,
                              size: 22,
                            ),
                            SizedBox(height: 2),
                            Text(
                              tool.label,
                              style: TextStyle(
                                color: _selectedTool == i
                                    ? Colors.white
                                    : Colors.white54,
                                fontSize: 9,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolItem {
  final IconData icon;
  final String label;
  final Color color;

  _ToolItem({required this.icon, required this.label, required this.color});
}
