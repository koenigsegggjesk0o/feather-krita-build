// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// app_dirs.dart — Canonical per-user directories (exports, presets).
//
// Everything routes through the user documents directory, with an env
// override so tests and portable installs stay deterministic:
//   FEATHER_DATA_DIR  — overrides the documents root entirely
//   (FEATHER_EXPORT_DIR keeps its legacy meaning for the exporter and is
//   still honored when set.)

import 'dart:io';

/// Resolves the app data root: FEATHER_DATA_DIR, then the platform home
/// directory, then the system temp directory.
Directory appDataRoot() {
  final override = Platform.environment['FEATHER_DATA_DIR'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  try {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return Directory(home);
    }
  } catch (_) {}
  return Directory.systemTemp;
}

/// The directory exported files are written to (created on demand).
///
/// Honors the legacy FEATHER_EXPORT_DIR override used by tests.
Directory exportsDir() {
  final override = Platform.environment['FEATHER_EXPORT_DIR'];
  final base =
      (override != null && override.isNotEmpty) ? Directory(override) : appDataRoot();
  final dir =
      Directory('${base.path}${Platform.pathSeparator}feather_exports');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// The directory user brush presets are scanned from (created on demand).
///
/// Honors FEATHER_PRESETS_DIR for tests; bundled .kpp assets are seeded
/// here on first run so users can drop their own files next to them.
Directory presetsDir() {
  final override = Platform.environment['FEATHER_PRESETS_DIR'];
  final base = (override != null && override.isNotEmpty)
      ? Directory(override)
      : appDataRoot();
  final dir =
      Directory('${base.path}${Platform.pathSeparator}feather_presets');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}
