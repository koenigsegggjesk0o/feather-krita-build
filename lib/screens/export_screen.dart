// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// export_screen.dart — Export dialog with freemium lock.
//
// A glassmorphism dialog that lets the user pick an export format, adjust
// quality, and run the export. Formats locked behind the Pro tier (GIF,
// MP4, glTF) are shown with a lock badge and an "Upgrade to Pro" button
// instead of the export button. The actual encoding is delegated to the
// [exporter] callback supplied by the host screen.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/io/app_dirs.dart';
import 'package:feather_krita/models/export_format.dart';
import 'package:feather_krita/widgets/glass_slider.dart';
import 'package:feather_krita/widgets/save_as_dialog.dart';

/// A callback that performs the actual export. Returns the output path
/// (or an error message prefixed with `error:`).
///
/// Pass a non-null [path] (via the Save-As dialog) to override the
/// default auto-named output location.
typedef ExportRunner = Future<String> Function(
  ExportFormat format,
  int quality,
  void Function(double progress) onProgress, {
  String? path,
});

/// The export dialog.
class ExportScreen extends StatefulWidget {
  const ExportScreen({
    super.key,
    required this.isPro,
    required this.exporter,
    required this.onUpgrade,
    required this.onClose,
    this.baseName = 'Untitled',
    this.guideSurfaceName,
    this.onToast,
  });

  final bool isPro;
  final ExportRunner exporter;
  final VoidCallback onUpgrade;
  final VoidCallback onClose;
  final String baseName;

  /// Loop-58: the live guide surface's canonical type name, threaded to
  /// the Save-As dialog's .feather disclosure row (parity with the open
  /// dialog's strip). Null keeps the row hidden.
  final String? guideSurfaceName;

  /// Optional toast channel (host screen's ScaffoldMessenger). When
  /// provided, copy-path/show-in-folder confirmations route through it
  /// so the snackbar lands on the host's Scaffold (where the user
  /// expects it) instead of the dialog's overlay context.
  final void Function(String message)? onToast;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  ExportFormat? _selected;
  int _quality = 90;
  bool _busy = false;
  double _progress = 0;
  String? _resultPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = ExportFormat.featherProject;
  }

  bool get _locked => _selected != null && exportInfo(_selected!).isProOnly && !widget.isPro;

  Future<void> _run({String? path}) async {
    if (_selected == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _resultPath = null;
      _error = null;
    });
    try {
      final out = await widget.exporter(
        _selected!,
        _quality,
        (p) => setState(() => _progress = p),
        path: path,
      );
      if (out.startsWith('error:')) {
        setState(() => _error = out.substring(6).trim());
      } else {
        setState(() => _resultPath = out);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _saveAs() async {
    if (_selected == null) return;
    final info = exportInfo(_selected!);
    final chosen = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => SaveAsDialog(
        format: _selected!,
        baseName: widget.baseName,
        initialDir: _defaultDir(),
        guideSurfaceName: widget.guideSurfaceName,
      ),
    );
    if (chosen == null || chosen.isEmpty) return;
    // Validate the extension one more time (the dialog does too, but a
    // user-edited path could still slip through).
    if (!chosen.toLowerCase().endsWith('.${info.extension}')) {
      setState(() => _error = 'File name must end with .${info.extension}.');
      return;
    }
    await _run(path: chosen);
  }

  /// Best-effort default directory for the Save-As dialog pre-fill.
  /// Defaults to the canonical exports directory; falls back to the
  /// system temp directory if that can't be resolved (never throws).
  String _defaultDir() {
    try {
      return exportsDir().path;
    } catch (_) {
      try {
        return Directory.systemTemp.absolute.path;
      } catch (_) {
        return '';
      }
    }
  }

  Future<void> _copyPath() async {
    final p = _resultPath;
    if (p == null) return;
    // Fire-and-forget the clipboard write so the confirmation is
    // immediate even on platforms where the channel is slow.
    unawaited(Clipboard.setData(ClipboardData(text: p))
        .catchError((Object _) {}));
    if (!mounted) return;
    final toast = widget.onToast;
    if (toast != null) {
      toast('Path copied to clipboard');
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: const Text('Path copied to clipboard',
            style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xCC1A1A2E),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _showInFolder() async {
    final p = _resultPath;
    if (p == null) return;
    final dir = File(p).parent.path;
    var opened = false;
    try {
      if (Platform.isMacOS) {
        await Process.start('open', [dir]);
        opened = true;
      } else if (Platform.isWindows) {
        await Process.start('explorer', [dir]);
        opened = true;
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [dir]);
        opened = true;
      }
    } catch (_) {
      // Non-fatal: fall through to the toast.
    }
    if (!mounted) return;
    final toast = widget.onToast;
    final msg = opened ? 'Opened folder' : 'Folder: $dir';
    if (toast != null) {
      toast(msg);
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xCC1A1A2E),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: GlassContainer(
        width: 560,
        padding: const EdgeInsets.all(20),
        color: AppTheme.darkGlass.withOpacity(0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onClose: widget.onClose),
            const Divider(height: 24, color: AppTheme.glassBorder),
            // Scrollable body: on short screens (landscape phones, small
            // desktop windows) the dialog would otherwise overflow and push
            // the action buttons out of the hit-test region.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _FormatGrid(
                      selected: _selected,
                      isPro: widget.isPro,
                      onSelected: (f) => setState(() {
                        _selected = f;
                        _resultPath = null;
                        _error = null;
                      }),
                    ),
                    const SizedBox(height: 16),
                    _QualityRow(
                      quality: _quality,
                      enabled: _qualityApplicable(),
                      onChanged: (q) => setState(() => _quality = q.round()),
                    ),
                    const SizedBox(height: 16),
                    _SummaryRow(
                      format: _selected,
                      baseName: widget.baseName,
                      quality: _quality,
                    ),
                    const SizedBox(height: 16),
                    _ActionArea(
                      busy: _busy,
                      progress: _progress,
                      locked: _locked,
                      resultPath: _resultPath,
                      error: _error,
                      onExport: () => _run(),
                      onSaveAs: _saveAs,
                      onCopyPath: _copyPath,
                      onShowInFolder: _showInFolder,
                      onUpgrade: widget.onUpgrade,
                      onClose: widget.onClose,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _qualityApplicable() {
    switch (_selected) {
      case ExportFormat.jpeg:
      case ExportFormat.gif:
      case ExportFormat.mp4:
        return true;
      case ExportFormat.png:
      case ExportFormat.obj:
      case ExportFormat.gltf:
      case ExportFormat.featherProject:
      case null:
        return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets.
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
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
          'Export',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close_rounded, color: AppTheme.textTertiary),
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _FormatGrid extends StatelessWidget {
  const _FormatGrid({
    required this.selected,
    required this.isPro,
    required this.onSelected,
  });

  final ExportFormat? selected;
  final bool isPro;
  final ValueChanged<ExportFormat> onSelected;

  @override
  Widget build(BuildContext context) {
    final formats = ExportFormat.values;
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.0,
      children: [
        for (final f in formats)
          _FormatCard(
            info: exportInfo(f),
            isSelected: selected == f,
            locked: exportInfo(f).isProOnly && !isPro,
            onTap: () => onSelected(f),
          ),
      ],
    );
  }
}

class _FormatCard extends StatelessWidget {
  const _FormatCard({
    required this.info,
    required this.isSelected,
    required this.locked,
    required this.onTap,
  });

  final ExportFormatInfo info;
  final bool isSelected;
  final bool locked;
  final VoidCallback onTap;

  IconData get _icon {
    switch (info.category) {
      case ExportCategory.image:
        return Icons.image_outlined;
      case ExportCategory.animation:
        return Icons.movie_outlined;
      case ExportCategory.model:
        return Icons.view_in_ar_outlined;
      case ExportCategory.project:
        return Icons.save_outlined;
    }
  }

  Color get _accent {
    switch (info.category) {
      case ExportCategory.image:
        return AppTheme.toolExport;
      case ExportCategory.animation:
        return AppTheme.toolLiquify;
      case ExportCategory.model:
        return AppTheme.toolShape;
      case ExportCategory.project:
        return AppTheme.primaryBlue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isSelected
              ? _accent.withOpacity(0.25)
              : AppTheme.darkGlassLight.withOpacity(0.4),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: isSelected ? _accent : AppTheme.glassBorder,
            width: isSelected ? 1.5 : 0.5,
          ),
        ),
        padding: const EdgeInsets.all(8),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon, color: isSelected ? Colors.white : _accent, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    info.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected
                          ? Colors.white
                          : AppTheme.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '.${info.extension}',
                    style: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
            if (locked)
              const Positioned(
                right: 0,
                top: 0,
                child: Icon(Icons.lock_rounded,
                    size: 12, color: AppTheme.toolLiquify),
              ),
          ],
        ),
      ),
    );
  }
}

class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.quality,
    required this.enabled,
    required this.onChanged,
  });

  final int quality;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: AbsorbPointer(
        absorbing: !enabled,
        child: GlassSlider(
          value: quality.toDouble(),
          min: 10,
          max: 100,
          divisions: 90,
          label: 'Quality',
          icon: Icons.tune_rounded,
          accent: AppTheme.toolExport,
          onChanged: onChanged,
          valueFormatter: (v) => '${v.round()}%',
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.format,
    required this.baseName,
    required this.quality,
  });

  final ExportFormat? format;
  final String baseName;
  final int quality;

  @override
  Widget build(BuildContext context) {
    final info = format == null ? null : exportInfo(format!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.darkGlassLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: AppTheme.glassBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.description_outlined,
              size: 16, color: AppTheme.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              info == null ? '—' : info.suggestFileName(baseName),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (info != null)
            Text(
              info.mimeType,
              style: const TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionArea extends StatelessWidget {
  const _ActionArea({
    required this.busy,
    required this.progress,
    required this.locked,
    required this.resultPath,
    required this.error,
    required this.onExport,
    required this.onSaveAs,
    required this.onCopyPath,
    required this.onShowInFolder,
    required this.onUpgrade,
    required this.onClose,
  });

  final bool busy;
  final double progress;
  final bool locked;
  final String? resultPath;
  final String? error;
  final VoidCallback onExport;
  final VoidCallback onSaveAs;
  final VoidCallback onCopyPath;
  final VoidCallback onShowInFolder;
  final VoidCallback onUpgrade;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: AppTheme.darkGlassLight,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppTheme.toolExport),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Exporting… ${(progress * 100).round()}%',
            style: const TextStyle(color: AppTheme.textTertiary, fontSize: 11),
          ),
        ],
      );
    }

    if (resultPath != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.toolSelect.withOpacity(0.18),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(color: AppTheme.toolSelect),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: AppTheme.toolSelect, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Saved: $resultPath',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onCopyPath,
                child: const Text('Copy path'),
              ),
              TextButton(
                onPressed: onShowInFolder,
                child: const Text('Show in folder'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.toolExport),
                onPressed: onClose,
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      );
    }

    if (error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.toolErase.withOpacity(0.18),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(color: AppTheme.toolErase),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: AppTheme.toolErase, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error!,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 3,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: onExport,
                child: const Text('Retry'),
              ),
            ],
          ),
        ],
      );
    }

    if (locked) {
      return _UpgradeCard(onUpgrade: onUpgrade);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: onClose,
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        TextButton(
          onPressed: onSaveAs,
          child: const Text('Save As…'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: AppTheme.toolExport),
          onPressed: onExport,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Export'),
        ),
      ],
    );
  }
}

class _UpgradeCard extends StatelessWidget {
  const _UpgradeCard({required this.onUpgrade});

  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x66FF9500), Color(0x66FF2D55)],
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: AppTheme.toolLiquify),
      ),
      child: Row(
        children: [
          const Icon(Icons.workspace_premium_rounded,
              color: AppTheme.toolLiquify, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Pro format',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Upgrade to Feather-Krita Pro to unlock this format and more.',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.toolLiquify),
            onPressed: onUpgrade,
            child: const Text('Upgrade to Pro'),
          ),
        ],
      ),
    );
  }
}
