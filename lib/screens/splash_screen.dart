// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// splash_screen.dart — Splash / loading screen.
//
// A glassmorphism splash with an animated feather logo (rotating +
// pulsing), a determinate loading progress bar, and the "Feather-Krita"
// title. After [duration] it calls [onLoadingComplete].

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';

/// The splash / loading screen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    this.duration = const Duration(milliseconds: 2600),
    this.onLoadingComplete,
  });

  final Duration duration;
  final VoidCallback? onLoadingComplete;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoController;
  late final AnimationController _progressController;
  late final Animation<double> _rotation;
  late final Animation<double> _scale;
  late final Animation<double> _progress;
  late final Animation<double> _fadeIn;

  @override
  void initState() {
    super.initState();
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _rotation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeInOutCubic),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.6, end: 1.1)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.1, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 60,
      ),
    ]).animate(_logoController);

    _progressController = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _progress = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _progressController, curve: Curves.easeInOut),
    );
    _fadeIn = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _progressController,
        curve: const Interval(0.0, 0.35, curve: Curves.easeIn),
      ),
    );

    _logoController.forward();
    _progressController.forward().whenComplete(() {
      if (mounted) widget.onLoadingComplete?.call();
    });
  }

  @override
  void dispose() {
    _logoController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0B0B10),
              Color(0xFF1A1A24),
              Color(0xFF0E0E16),
            ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // Ambient glow orbs.
              const _AmbientOrb(
                alignment: Alignment(-0.6, -0.4),
                color: AppTheme.primaryBlue,
                size: 280,
              ),
              const _AmbientOrb(
                alignment: Alignment(0.7, 0.5),
                color: AppTheme.primaryPurple,
                size: 320,
              ),
              const _AmbientOrb(
                alignment: Alignment(0.2, -0.7),
                color: AppTheme.toolLiquify,
                size: 200,
              ),

              Center(
                child: FadeTransition(
                  opacity: _fadeIn,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Animated logo.
                      AnimatedBuilder(
                        animation: _logoController,
                        builder: (context, _) {
                          return Transform.rotate(
                            angle: _rotation.value * 2 * 3.14159265,
                            child: Transform.scale(
                              scale: _scale.value,
                              child: _LogoBadge(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 28),
                      // Title.
                      GlassContainer(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        borderRadius: AppTheme.radiusXLarge,
                        color: AppTheme.darkGlass.withOpacity(0.5),
                        child: Column(
                          children: const [
                            Text(
                              'Feather-Krita',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '3D Drawing · Krita Brush Engine',
                              style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 36),
                      // Progress.
                      SizedBox(
                        width: 260,
                        child: AnimatedBuilder(
                          animation: _progress,
                          builder: (context, _) {
                            return Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                      AppTheme.radiusCircular),
                                  child: LinearProgressIndicator(
                                    value: _progress.value,
                                    minHeight: 6,
                                    backgroundColor: AppTheme.darkGlassLight,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                            AppTheme.accent),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _phaseFor(_progress.value),
                                      style: const TextStyle(
                                        color: AppTheme.textTertiary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      '${(_progress.value * 100).round()}%',
                                      style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Version footer.
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: FadeTransition(
                  opacity: _fadeIn,
                  child: Center(
                    child: Text(
                      'v1.0.0 · GPL-2.0-or-later',
                      style: TextStyle(
                        color: AppTheme.textTertiary.withOpacity(0.6),
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _phaseFor(double t) {
    if (t < 0.25) return 'Loading brush engine…';
    if (t < 0.5) return 'Loading presets…';
    if (t < 0.75) return 'Preparing guide surfaces…';
    if (t < 1.0) return 'Initializing canvas…';
    return 'Ready';
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets.
// ---------------------------------------------------------------------------

class _LogoBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primaryBlue, AppTheme.primaryPurple],
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusXLarge),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryBlue.withOpacity(0.55),
            blurRadius: 32,
            spreadRadius: 2,
          ),
        ],
        border: Border.all(color: Colors.white24, width: 1.5),
      ),
      child: const Icon(Icons.brush, color: Colors.white, size: 56),
    );
  }
}

class _AmbientOrb extends StatelessWidget {
  const _AmbientOrb({
    required this.alignment,
    required this.color,
    required this.size,
  });

  final Alignment alignment;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: IgnorePointer(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [color.withOpacity(0.35), color.withOpacity(0.0)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
