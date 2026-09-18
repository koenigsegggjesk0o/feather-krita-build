// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// file_meta.dart — Small human-readable formatters for the open/save
// dialogs: file size (bytes → KB/MB) and relative modified time
// ("just now", "5m ago", "3h ago", "2d ago", else absolute date).
//
// Kept dependency-free and pure so widget tests can assert exact output.

import 'dart:io';

/// Formats [bytes] as a compact human-readable size.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var size = bytes.toDouble() / 1024.0;
  var unit = 0;
  while (size >= 1024.0 && unit < units.length - 1) {
    size /= 1024.0;
    unit++;
  }
  return '${size.toStringAsFixed(size < 10 ? 1 : 0)} ${units[unit]}';
}

/// Formats the difference between [modified] and [now] as a short
/// relative-time string. Falls back to an absolute YYYY-MM-DD for
/// anything older than 7 days.
String formatRelativeTime(DateTime modified, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final delta = ref.difference(modified);
  if (delta.isNegative || delta.inSeconds < 30) return 'just now';
  if (delta.inMinutes < 1) return '${delta.inSeconds}s ago';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  if (delta.inDays < 7) return '${delta.inDays}d ago';
  final y = modified.year.toString();
  final m = modified.month.toString().padLeft(2, '0');
  final d = modified.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Snapshot of a quick-pick candidate's display fields.
class FileMeta {
  const FileMeta({
    required this.path,
    required this.size,
    required this.modified,
    required this.exists,
  });

  final String path;
  final int size;
  final DateTime modified;
  final bool exists;

  /// Builds a [FileMeta] from [path]. Missing files yield a sentinel
  /// (exists=false, size=0, modified=epoch) so the dialog can still
  /// show the path with a "(missing)" hint.
  static FileMeta fromPath(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) {
        return FileMeta(
          path: path,
          size: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          exists: false,
        );
      }
      final stat = f.statSync();
      return FileMeta(
        path: path,
        size: stat.size,
        modified: stat.modified,
        exists: true,
      );
    } catch (_) {
      return FileMeta(
        path: path,
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        exists: false,
      );
    }
  }

  /// Returns the trailing filename segment of [path] (no directory).
  String get basename {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }
}
