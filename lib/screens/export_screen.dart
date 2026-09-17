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

import 'package:flutter/material.dart';

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/models/export_format.dart';
import 'package:feather_krita/widgets/glass_slider.dart';

/// A callback that performs the actual export. Returns the output path
/// (or an error message prefixed with `error:`).
typedef ExportRunner = Future<String> Function(
  ExportFormat format,
  int quality,
  void Function(double progress) onProgress,
);

/// The export dialog.
class ExportScreen extends StatefulWidget {
  const ExportScreen({
    super.key,
    required this.isPro,
    required this.exporter,
    required this.onUpgrade,
    required this.onClose,
    this.baseName = 'Untitled',
  });

  final bool isPro;
  final ExportRunner exporter;
  final VoidCallback onUpgrade;
  final VoidCallback onClose;
  final String baseName;

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

  Future<void> _run() async {
    if (_selected == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _resultPath = null;
      _error = null;
    });
    try {
      final path = await widget.exporter(
        _selected!,
        _quality,
        (p) => setState(() => _progress = p),
      );
      if (path.startsWith('error:')) {
        setState(() => _error = path.substring(6).trim());
      } else {
        setState(() => _resultPath = path);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
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
              onExport: _run,
              onUpgrade: widget.onUpgrade,
              onClose: widget.onClose,
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
    required this.onUpgrade,
    required this.onClose,
  });

  final bool busy;
  final double progress;
  final bool locked;
  final String? resultPath;
  final String? error;
  final VoidCallback onExport;
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
