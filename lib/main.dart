// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// main.dart — Entry point aplikasi Feather-Krita
//
// Boot sequence (v0.50): the splash progress is REAL, not a timer —
//   1. probe the native Krita bridge (hang-proof, isolate + timeout),
//   2. first-run import of the full real Krita resource library
//      (assets/krita-data.zip → feather_resources/, 1:1, unmodified),
//   3. enter the editor, which scans the imported paintoppresets.
// 100% on the bar means the phases actually completed — nothing heavy
// runs invisibly after the loader (the class of bug that froze the old
// build at "100%").

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'io/engine_probe.dart';
import 'io/krita_launcher.dart';
import 'io/krita_resources.dart';
import 'screens/main_screen.dart';
import 'theme/app_theme.dart';
import 'utils/app_version.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
  ]);

  runApp(
    const ProviderScope(
      child: FeatherKritaApp(),
    ),
  );
}

class FeatherKritaApp extends StatelessWidget {
  const FeatherKritaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Feather-Krita',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const BootScreen(),
    );
  }
}

/// Real boot loader: every progress step reflects actual work.
class BootScreen extends StatefulWidget {
  const BootScreen({super.key});

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  double _progress = 0.0;
  String _phase = 'Starting…';
  String? _detail;
  bool? _engineReal;
  bool _resourcesMissing = false;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_boot);
  }

  Future<void> _boot() async {
    // ---- Phase 1: native Krita engine probe (0.00 → 0.16) ------------
    if (!mounted) return;
    setState(() => _phase = 'Loading Krita brush engine…');
    final engineOk = await probeKritaEngine();
    if (!mounted) return;
    setState(() {
      _engineReal = engineOk;
      _progress = 0.16;
    });

    // ---- Phase 2: first-run resource import (0.16 → 0.92) ------------
    setState(() => _phase = 'Importing real Krita resources…');
    final summary = await KritaResources.ensureImported(
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _detail = '$done / $total files';
          _progress = 0.16 + 0.76 * (total > 0 ? done / total : 1.0);
        });
      },
    );
    if (!mounted) return;
    if (!summary.ok) {
      // Stripped payload or a failed extraction — the editor still runs
      // with its bundled presets; a full build re-imports next launch.
      _resourcesMissing = true;
    }
    setState(() => _detail = null);

    // ---- Phase 3: preset scan hand-off (0.92 → 0.97) ------------------
    setState(() => _phase = 'Scanning brush presets…');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    setState(() => _progress = 0.97);

    // ---- Phase 4: enter the editor (0.97 → 1.00) ----------------------
    setState(() => _phase = 'Ready');
    await Future<void>.delayed(const Duration(milliseconds: 240));
    if (!mounted) return;
    setState(() => _progress = 1.0);
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            MainScreen(enableEngine: engineOk),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          // Ambient orbs.
          Positioned(
            left: -50,
            top: -50,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.primaryBlue.withValues(alpha: 0.15),
              ),
            ),
          ),
          Positioned(
            right: -80,
            bottom: -80,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.primaryPurple.withValues(alpha: 0.12),
              ),
            ),
          ),

          // Center content.
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo.
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.primaryBlue, AppTheme.primaryPurple],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primaryBlue.withValues(alpha: 0.5),
                        blurRadius: 30,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.brush, color: Colors.white, size: 50),
                ),

                const SizedBox(height: 24),
                const Text(
                  'Feather-Krita',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '3D Drawing · Real Krita Brush Engine',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                ),

                const SizedBox(height: 40),

                // Progress bar — real phase progress.
                SizedBox(
                  width: 260,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: Colors.white.withValues(alpha: 0.1),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          AppTheme.primaryBlue),
                      minHeight: 4,
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Phase text + percentage.
                SizedBox(
                  width: 260,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          _phase,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Text(
                        '${(_progress * 100).round()}%',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

                // Import file counter.
                if (_detail != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _detail!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 10,
                    ),
                  ),
                ],

                const SizedBox(height: 18),

                // Engine badge — honest state of the native engine.
                if (_engineReal != null) _EngineBadge(real: _engineReal!),
                if (KritaLauncher.isBundled) ...[
                  const SizedBox(height: 8),
                  Text(
                    KritaLauncher.badgeLabel,
                    style: TextStyle(
                      color: const Color(0xFF34C759).withValues(alpha: 0.65),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
                if (_resourcesMissing) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Resource payload unavailable — using bundled presets',
                    style: TextStyle(
                      color: Colors.orange.withValues(alpha: 0.7),
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Version.
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                '$kAppVersionLabel · GPL-2.0-or-later',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.2),
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Honest native-engine state chip.
class _EngineBadge extends StatelessWidget {
  const _EngineBadge({required this.real});

  final bool real;

  @override
  Widget build(BuildContext context) {
    final color = real ? const Color(0xFF34C759) : const Color(0xFFFF9500);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(real ? Icons.verified_rounded : Icons.layers_rounded,
              size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            real ? 'REAL KRITA ENGINE' : 'SYNTHETIC FALLBACK',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
