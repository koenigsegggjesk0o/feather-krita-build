// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// save_as_dialog.dart — "Save As…" dialog for explicit export paths.
//
// Lets the user name an export (or browse to a full path) and returns the
// resolved absolute path via `Navigator.pop(context, path)`. The host
// screen then runs the actual encode through the existing exporter with
// that path. The dialog never writes files itself.
//
// The browse button wraps `file_picker.saveFile` in a try/catch: on
// platforms where the plugin is unavailable the manual filename field
// keeps the dialog fully functional (and deterministic under tests).

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/models/export_format.dart';

/// A dialog that returns the absolute path the user wants to save to,
/// or null when cancelled. Pre-fills [initialDir] + a sanitized
/// [baseName] + the format's extension.
class SaveAsDialog extends StatefulWidget {
  const SaveAsDialog({
    super.key,
    required this.format,
    required this.baseName,
    this.initialDir,
  });

  final ExportFormat format;
  final String baseName;
  final String? initialDir;

  @override
  State<SaveAsDialog> createState() => _SaveAsDialogState();
}

class _SaveAsDialogState extends State<SaveAsDialog> {
  late final TextEditingController _name;
  String? _hint;
  bool _hintIsError = false;

  @override
  void initState() {
    super.initState();
    final info = exportInfo(widget.format);
    final safe = widget.baseName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    _name = TextEditingController(text: '$safe.${info.extension}');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Joins [initialDir] with [_name] into an absolute path. When the
  /// user typed a path with a separator, treat it as already-absolute
  /// (or relative to the app cwd) and use it verbatim.
  String _resolvePath() {
    final typed = _name.text.trim();
    if (typed.isEmpty) return '';
    final sep = Platform.pathSeparator;
    if (typed.contains('/') || typed.contains('\\')) {
      return typed;
    }
    final dir = widget.initialDir;
    if (dir == null || dir.isEmpty) return typed;
    final cleanDir = dir.endsWith(sep) ? dir : '$dir$sep';
    return '$cleanDir$typed';
  }

  Future<void> _browse() async {
    setState(() {
      _hint = null;
      _hintIsError = false;
    });
    try {
      final info = exportInfo(widget.format);
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save ${info.label}',
        fileName: _name.text.isEmpty
            ? 'untitled.${info.extension}'
            : _name.text,
        type: FileType.any,
      );
      if (result != null && result.isNotEmpty) {
        // saveFile returns a full path; show just the basename in the
        // field so the user can still edit it, but remember the
        // directory by re-stitching if the user accepts.
        final parts = result.split(RegExp(r'[\\/]'));
        setState(() {
          _name.text = parts.isEmpty ? result : parts.last;
          _hint = 'Folder: ${result.substring(0, result.length - (_name.text.length + 1))}';
        });
        // Stash the chosen directory by overriding initialDir through a
        // pop-with-full-path: simplest is to return the full path
        // immediately so the host uses it verbatim.
        if (mounted) Navigator.of(context).pop(result);
      }
    } catch (_) {
      setState(() {
        _hint = 'File picker unavailable here — type the full path instead.';
        _hintIsError = false;
      });
    }
  }

  void _save() {
    final path = _resolvePath();
    if (path.isEmpty) {
      setState(() {
        _hint = 'Enter a file name.';
        _hintIsError = true;
      });
      return;
    }
    final info = exportInfo(widget.format);
    if (!path.toLowerCase().endsWith('.${info.extension}')) {
      setState(() {
        _hint = 'Name must end with .${info.extension}';
        _hintIsError = true;
      });
      return;
    }
    Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    final info = exportInfo(widget.format);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: GlassContainer(
        width: 480,
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
                    color: AppTheme.toolExport,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Save As',
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
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.darkGlassLight.withOpacity(0.5),
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                border: Border.all(color: AppTheme.glassBorder),
              ),
              child: Row(
                children: [
                  const Icon(Icons.save_as_outlined,
                      size: 14, color: AppTheme.textTertiary),
                  const SizedBox(width: 6),
                  Text(
                    '${info.label} · .${info.extension}',
                    style: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    autofocus: true,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                    decoration: InputDecoration(
                      hintText: 'filename.${info.extension}',
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
                    onSubmitted: (_) => _save(),
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
                style: TextStyle(
                  color: _hintIsError
                      ? AppTheme.toolErase
                      : AppTheme.textTertiary,
                  fontSize: 11,
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
                      backgroundColor: AppTheme.toolExport),
                  onPressed: _save,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
