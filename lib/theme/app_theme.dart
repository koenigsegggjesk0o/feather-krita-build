// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// app_theme.dart — Glassmorphism theme seperti iOS 26 / macOS
//
// Mendefinisikan warna, efek kaca (glass), blur, dan style
// yang mirip dengan Apple Design Language.

import 'package:flutter/material.dart';
import 'dart:ui';

class AppTheme {
  // Primary colors (inspired by iOS/macOS)
  static const Color primaryBlue = Color(0xFF007AFF);
  static const Color primaryPurple = Color(0xFF5856D6);
  static const Color primaryPink = Color(0xFFFF2D55);
  static const Color primaryOrange = Color(0xFFFF9500);
  static const Color primaryGreen = Color(0xFF34C759);
  static const Color primaryTeal = Color(0xFF30B0C7);

  // Dark mode colors (like macOS dark)
  static const Color darkBackground = Color(0xFF1C1C1E);
  static const Color darkSurface = Color(0xFF2C2C2E);
  static const Color darkSurfaceLight = Color(0xFF3A3A3C);
  static const Color darkGlass = Color(0x403A3A3C);
  static const Color darkGlassLight = Color(0x60484848);

  // Light mode colors
  static const Color lightBackground = Color(0xFFF2F2F7);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightGlass = Color(0x40FFFFFF);
  static const Color lightGlassLight = Color(0x60FFFFFF);

  // Text colors
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFEBEBF5);
  static const Color textTertiary = Color(0xFFEBEBF599);
  static const Color textDark = Color(0xFF000000);
  static const Color textDarkSecondary = Color(0xFF3C3C4399);

  // Glass effect colors
  static const Color glassBlur = Color(0x30FFFFFF);
  static const Color glassBorder = Color(0x20FFFFFF);
  static const Color glassShadowColor = Color(0x40000000);

  // Accent
  static const Color accent = primaryBlue;
  static const Color accentSoft = Color(0x30007AFF);

  // Canvas / 3D viewport
  static const Color canvasBackground = Color(0xFF000000);
  static const Color canvasGrid = Color(0x20FFFFFF);

  // Tool colors
  static const Color toolDraw = primaryBlue;
  static const Color toolErase = primaryPink;
  static const Color toolShape = primaryPurple;
  static const Color toolLiquify = primaryOrange;
  static const Color toolSelect = primaryTeal;
  static const Color toolLight = Color(0xFFFFCC00);
  static const Color toolExport = primaryGreen;

  // Glass blur sigma
  static const double glassBlurSigma = 30.0;
  static const double glassBorderWidth = 0.5;

  // Border radius
  static const double radiusSmall = 8.0;
  static const double radiusMedium = 12.0;
  static const double radiusLarge = 16.0;
  static const double radiusXLarge = 24.0;
  static const double radiusCircular = 100.0;

  // Shadows
  static List<BoxShadow> get glassShadow => [
    BoxShadow(
      color: glassShadowColor,
      blurRadius: 20,
      offset: const Offset(0, 4),
    ),
  ];

  // Gradients
  static LinearGradient get toolbarGradient => const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x603A3A3C), Color(0x402C2C2E)],
  );

  static LinearGradient get buttonGradient => const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x60FFFFFF), Color(0x20FFFFFF)],
  );

  // Theme data
  static ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: darkBackground,
    colorScheme: const ColorScheme.dark(
      primary: primaryBlue,
      secondary: primaryPurple,
      surface: darkSurface,
      error: primaryPink,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.transparent,
      elevation: 0,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: primaryBlue,
      unselectedItemColor: textTertiary,
    ),
    fontFamily: 'Inter',
  );
}

// Glassmorphism widget — efek kaca seperti iOS/macOS
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final double borderRadius;
  final Color? color;
  final double blurSigma;
  final EdgeInsets? padding;
  final EdgeInsets? margin;
  final List<BoxShadow>? shadows;
  final Border? border;

  const GlassContainer({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.borderRadius = AppTheme.radiusLarge,
    this.color,
    this.blurSigma = AppTheme.glassBlurSigma,
    this.padding,
    this.margin,
    this.shadows,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: shadows ?? AppTheme.glassShadow,
        border: border ?? Border.all(
          color: AppTheme.glassBorder,
          width: AppTheme.glassBorderWidth,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: blurSigma,
            sigmaY: blurSigma,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: color ?? AppTheme.darkGlass,
              borderRadius: BorderRadius.circular(borderRadius),
            ),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}

// Glass button — tombol dengan efek kaca
class GlassButton extends StatefulWidget {
  final IconData icon;
  final String? label;
  final VoidCallback onTap;
  final bool isSelected;
  final Color? color;
  final double size;

  const GlassButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.label,
    this.isSelected = false,
    this.color,
    this.size = 56,
  });

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: child,
          );
        },
        child: GlassContainer(
          width: widget.size,
          height: widget.size,
          borderRadius: AppTheme.radiusMedium,
          color: widget.isSelected
              ? (widget.color ?? AppTheme.accent).withOpacity(0.3)
              : AppTheme.darkGlass,
          border: Border.all(
            color: widget.isSelected
                ? (widget.color ?? AppTheme.accent)
                : AppTheme.glassBorder,
            width: widget.isSelected ? 2 : 0.5,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                color: widget.isSelected
                    ? Colors.white
                    : (widget.color ?? Colors.white70),
                size: 24,
              ),
              if (widget.label != null) ...[
                const SizedBox(height: 2),
                Text(
                  widget.label!,
                  style: TextStyle(
                    color: widget.isSelected
                        ? Colors.white
                        : Colors.white60,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
