// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// krita_launcher.dart — Locates and launches the FULL official Krita
// application bundled with the Feather package.
//
// The Windows package ships the complete, UNMODIFIED official Krita
// 6.0.4 portable install (downloaded from krita.org at build time,
// SHA256-pinned by CI) inside `krita/` next to the Feather executable.
// This helper finds it and launches the real krita.exe — the 100%
// original application, every file exactly as KDE ships it. Nothing is
// patched, wrapped or modified.

import 'dart:io';

/// Locates and launches the bundled full official Krita application.
class KritaLauncher {
  /// Absolute path of the bundled `krita.exe`, when the full official
  /// install is present next to the Feather executable.
  static String? bundledKritaExePath() {
    if (Platform.isWindows) {
      final exe = Platform.resolvedExecutable;
      final dir = File(exe).parent.path;
      final sep = Platform.pathSeparator;
      final base = dir.endsWith(sep) ? dir : '$dir$sep';
      final candidate = File('${base}krita${sep}bin${sep}krita.exe');
      return candidate.existsSync() ? candidate.path : null;
    }
    return null;
  }

  /// Whether the full official Krita application is bundled here.
  static bool get isBundled => bundledKritaExePath() != null;

  /// A short honest label describing the bundled install (for badges).
  static String get badgeLabel => 'FULL KRITA 6.0.4 BUNDLED';

  /// Launches the real krita.exe (detached — Feather stays usable).
  ///
  /// Returns false when the bundled install is absent or the OS refused
  /// to start the process.
  static Future<bool> launch() async {
    final exe = bundledKritaExePath();
    if (exe == null) return false;
    try {
      await Process.start(exe, const <String>[],
          mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }
}
