// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// open_project_dialog.dart — "Open document" dialog.
//
// Lets the user type (or browse to) a .feather project file and returns
// the chosen path to the host screen, which performs the actual parse +
// restore. The file picker is wrapped in a try/catch: on platforms where
// the plugin is unavailable the manual path field keeps the dialog fully
// functional (and deterministic under widget tests).
//
// Loop-21 UX polish:
//   - Up to 10 quick-pick candidates (was 5), each showing file size +
//     relative modified time so the user can tell a 5-minute-old 2 MB
//     autosave from a 3-week-old 80 KB sketch.
//   - Per-row delete button (forwards to [onDelete]) so stale exports
//     can be cleared without leaving the dialog.
//   - A persisted "Recent projects" section (from recent_projects.dart)
//     is shown above "Recent exports" when the user has opened files
//     that aren't in the exports directory (e.g. files copied in from
//     email/cloud storage). Selecting any row fills the path field; a
//     dedicated "Open" tap on it loads the project.

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/io/file_meta.dart';
import 'package:feather_krita/io/recent_projects.dart';

/// A dialog that returns the path of the .feather file to open
/// (via `Navigator.pop(context, path)`), or null when cancelled.
class OpenProjectDialog extends StatefulWidget {
  const OpenProjectDialog({super.key, this.initialDir});

  /// Directory whose contents are offered as quick-pick candidates
  /// (typically the export directory where saved projects live).
  final String? initialDir;

  @override
  State<OpenProjectDialog> createState() => _OpenProjectDialogState();
}

class _OpenProjectDialogState extends State<OpenProjectDialog> {
  late final TextEditingController _path;
  List<FileMeta> _candidates = const [];
  List<FileMeta> _recents = const [];
  String? _hint;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController();
    _refreshAll();
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _refreshAll() {
    _refreshCandidates();
    _refreshRecents();
  }

  void _refreshCandidates() {
    final dir = widget.initialDir;
    if (dir == null || dir.isEmpty) return;
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return;
      final metas = <FileMeta>[];
      for (final e in d.listSync()) {
        if (e is File &&
            (e.path.endsWith('.feather') || e.path.endsWith('.json'))) {
          metas.add(FileMeta.fromPath(e.path));
        }
      }
      metas.sort((a, b) => b.modified.compareTo(a.modified));
      setState(() => _candidates = metas.take(10).toList(growable: false));
    } catch (_) {
      // Non-fatal: the path field remains usable.
    }
  }

  void _refreshRecents() {
    try {
      final paths = loadRecentProjects();
      // Only show recents that aren't already in the candidates list
      // (otherwise we'd duplicate entries the user can see above).
      final candidatePaths = _candidates.map((c) => c.path).toSet();
      final extras = paths
          .where((p) => !candidatePaths.contains(p))
          .map(FileMeta.fromPath)
          .where((m) => m.exists)
          .take(5)
          .toList(growable: false);
      setState(() => _recents = extras);
    } catch (_) {
      setState(() => _recents = const []);
    }
  }

  Future<void> _browse() async {
    setState(() => _hint = null);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
      );
      final p = result?.files.single.path;
      if (p != null && p.isNotEmpty) {
        _path.text = p;
      }
    } catch (_) {
      setState(() {
        _hint = 'File picker unavailable here — type the full path instead.';
      });
    }
  }

  void _load() {
    final p = _path.text.trim();
    if (p.isEmpty) {
      setState(() => _hint = 'Enter a .feather file path.');
      return;
    }
    if (!File(p).existsSync()) {
      setState(() => _hint = 'File not found: $p');
      return;
    }
    Navigator.of(context).pop(p);
  }

  void _deleteCandidate(FileMeta meta) async {
    try {
      final f = File(meta.path);
      if (f.existsSync()) f.deleteSync();
      forgetRecentProject(meta.path);
    } catch (_) {
      // Non-fatal: the row just stays.
    }
    _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: GlassContainer(
        width: 520,
        padding: const EdgeInsets.all(20),
        color: AppTheme.darkGlass.withOpacity(0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Open project',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: AppTheme.textTertiary),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                        fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: '/path/to/project.feather',
                      hintStyle: const TextStyle(
                          color: AppTheme.textTertiary, fontSize: 12),
                      filled: true,
                      fillColor: AppTheme.darkGlassLight.withOpacity(0.5),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMedium),
                        borderSide:
                            const BorderSide(color: AppTheme.glassBorder),
                      ),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Browse…',
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open_rounded,
                      color: AppTheme.textSecondary),
                ),
              ],
            ),
            if (_hint != null) ...[
              const SizedBox(height: 8),
              Text(
                _hint!,
                style:
                    const TextStyle(color: AppTheme.toolErase, fontSize: 11),
              ),
            ],
            if (_recents.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Recent projects',
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final c in _recents)
                        _CandidateTile(
                          meta: c,
                          onTap: () => _path.text = c.path,
                          onDelete: () => _deleteCandidate(c),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (_candidates.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Recent exports',
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final c in _candidates)
                        _CandidateTile(
                          meta: c,
                          onTap: () => _path.text = c.path,
                          onDelete: () => _deleteCandidate(c),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue),
                  onPressed: _load,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Open'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.meta,
    required this.onTap,
    required this.onDelete,
  });

  final FileMeta meta;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final name = meta.basename;
    final sizeStr = meta.exists ? formatFileSize(meta.size) : 'missing';
    final timeStr =
        meta.exists ? formatRelativeTime(meta.modified) : '—';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.insert_drive_file_outlined,
                size: 14, color: AppTheme.textTertiary),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '$sizeStr · $timeStr',
                    style: const TextStyle(
                        color: AppTheme.textTertiary, fontSize: 9),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: onDelete,
              icon: const Icon(Icons.close_rounded,
                  size: 14, color: AppTheme.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
