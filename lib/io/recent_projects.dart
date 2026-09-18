// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// recent_projects.dart — Persisted "recently opened" project list.
//
// The Open-project dialog offers the user a quick-pick of recently opened
// .feather files even when the exports directory is empty or has been
// cleaned. We persist at most [kMaxRecents] absolute paths in a small JSON
// file at the app data root, newest first. Missing files are pruned on
// load so the list never grows stale on disk.
//
// The store is intentionally tiny (plain JSON, synchronous IO) so widget
// tests can drive it deterministically under the fake event loop.

import 'dart:convert';
import 'dart:io';

import 'package:feather_krita/io/app_dirs.dart';

/// Maximum number of recent entries kept on disk.
const int kMaxRecents = 10;

/// The on-disk filename for the recents store.
const String kRecentsFileName = 'recent_projects.json';

/// Test-only override for the recents file location. When non-null,
/// [recentsFile] returns this instead of the canonical path so widget
/// tests can isolate the store per-test without touching the user's
/// real recents. Set to a temp file in `setUp`, reset to null in
/// `tearDown`.
File? testRecentsFileOverride;

/// Returns the absolute path of the recents store file.
File recentsFile() {
  if (testRecentsFileOverride != null) return testRecentsFileOverride!;
  final root = appDataRoot();
  return File('${root.path}${Platform.pathSeparator}$kRecentsFileName');
}

/// Loads the persisted recent-paths list, newest first, pruning any
/// entries that no longer exist on disk.
///
/// Returns an empty list when the store is missing, unreadable, or
/// contains no surviving entries (never throws).
List<String> loadRecentProjects() {
  final file = recentsFile();
  if (!file.existsSync()) return const [];
  try {
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map) return const [];
    final paths = raw['paths'];
    if (paths is! List) return const [];
    final out = <String>[];
    for (final p in paths) {
      if (p is String && p.isNotEmpty && File(p).existsSync()) {
        out.add(p);
      }
    }
    // De-duplicate while preserving order.
    return out.toSet().toList(growable: false).take(kMaxRecents).toList();
  } catch (_) {
    return const [];
  }
}

/// Records that the user opened [path]: moves it to the front of the
/// recents list, caps the list at [kMaxRecents], and persists. Silently
/// no-ops on IO failure (the open dialog remains usable).
void recordRecentProject(String path) {
  if (path.isEmpty) return;
  try {
    final current = loadRecentProjects();
    final next = [path, ...current.where((p) => p != path)]
        .take(kMaxRecents)
        .toList(growable: false);
    recentsFile().writeAsStringSync(jsonEncode({'paths': next}));
  } catch (_) {
    // Non-fatal: recents are a convenience, not a correctness requirement.
  }
}

/// Removes [path] from the recents store (used when the user deletes a
/// file from the quick-pick). Silently no-ops on IO failure.
void forgetRecentProject(String path) {
  if (path.isEmpty) return;
  try {
    final current = loadRecentProjects();
    final next = current.where((p) => p != path).toList(growable: false);
    recentsFile().writeAsStringSync(jsonEncode({'paths': next}));
  } catch (_) {
    // Non-fatal.
  }
}
