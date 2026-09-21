// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// preset_inspector_sheet.dart — engine-authoritative brush preset inspector.
//
// A glassmorphism dialog that shows EVERYTHING a .kpp preset really
// contains, in two views (5-loop-65, the user-visible payoff of the
// 5-loop-63 param-map ABI):
//
//   Curated — the ENGINE's resolved brush identity after loadPreset():
//     paintop family, eraser flag, size / opacity / spacing / hardness,
//     embedded preset name, the param-map size and its SOURCE badge.
//
//   Raw settings — the FULL paintop-settings <param> name/value map in
//     document order, projected by the C ABI exports
//     krita_brush_preset_param_count / _name(i) / _value(i) and surfaced
//     through [KritaBrushEngine.presetParams]. With the REAL engine this
//     is the engine's own parse (e.g. 169 entries on the stock basic-5
//     preset — including keys no curated getter exposes, like
//     ColorSource/Type and the per-sensor curve blobs). On fallback or
//     stripped builds (no native library / no loadable file) the
//     pure-Dart [BrushPreset.settings] parse stands in, so the inspector
//     degrades instead of breaking.
//
// The inspection runs on a THROWAWAY [KritaBrushEngine] instance so the
// user's active brush session is never clobbered (loadPreset mutates the
// engine it is called on). Opened by long-pressing a preset card in the
// brush picker.

import 'package:flutter/material.dart';

import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/theme/app_theme.dart';

/// Opens the inspector dialog for [preset].
Future<void> showPresetInspector(BuildContext context, BrushPreset preset) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.45),
    builder: (context) => PresetInspectorSheet(preset: preset),
  );
}

/// Everything the inspector renders, loaded once per open.
class _InspectData {
  _InspectData({
    required this.fromEngine,
    required this.params,
    this.engineError,
    this.loadError,
    this.presetName = '',
    this.paintopId = '',
    this.isEraser = false,
    this.size,
    this.opacity,
    this.spacing,
    this.hardness,
  });

  /// True when the map came from the native engine's C ABI projection;
  /// false when it is the pure-Dart [BrushPreset.settings] stand-in.
  final bool fromEngine;

  /// Raw settings map, document order (engine) or parse order (Dart).
  final Map<String, String> params;

  /// Non-null when the native engine could not be constructed at all
  /// (stripped build) — the Dart parse was used instead.
  final String? engineError;

  /// Non-null when the engine exists but loadPreset() failed.
  final String? loadError;

  final String presetName;
  final String paintopId;
  final bool isEraser;
  final double? size;
  final double? opacity;
  final double? spacing;
  final double? hardness;
}

class PresetInspectorSheet extends StatefulWidget {
  const PresetInspectorSheet({super.key, required this.preset});

  final BrushPreset preset;

  @override
  State<PresetInspectorSheet> createState() => _PresetInspectorSheetState();
}

class _PresetInspectorSheetState extends State<PresetInspectorSheet> {
  _InspectData? _data;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = _inspect(widget.preset);
    if (mounted) setState(() => _data = data);
  }

  /// Runs the inspection synchronously on a throwaway engine. The FFI
  /// calls are fast (file parse + map copy); no async gaps means the
  /// engine lifetime is fully contained in this function.
  static _InspectData _inspect(BrushPreset preset) {
    // Fallback surface: the pure-Dart parse (also the base when the
    // native engine exists but the preset carries no loadable path).
    Map<String, String> dartParams() => <String, String>{
          for (final s in preset.settings.values) s.name: s.value,
        };

    KritaBrushEngine? engine;
    try {
      engine = KritaBrushEngine();
    } catch (e) {
      return _InspectData(
        fromEngine: false,
        params: dartParams(),
        engineError: e.toString(),
        paintopId: preset.paintopId,
        isEraser: preset.isEraserPreset,
      );
    }
    try {
      final path = preset.filePath;
      if (path == null || path.isEmpty) {
        return _InspectData(
          fromEngine: false,
          params: dartParams(),
          engineError: 'preset has no file path (in-memory entry)',
          paintopId: preset.paintopId,
          isEraser: preset.isEraserPreset,
        );
      }
      if (!engine.loadPreset(path)) {
        return _InspectData(
          fromEngine: false,
          params: dartParams(),
          loadError: engine.lastError().isNotEmpty
              ? engine.lastError()
              : 'loadPreset returned false',
          paintopId: preset.paintopId,
          isEraser: preset.isEraserPreset,
        );
      }
      return _InspectData(
        fromEngine: true,
        params: engine.presetParams(),
        presetName: engine.currentPresetName,
        paintopId: engine.currentPaintopId,
        isEraser: engine.isEraserPreset,
        size: engine.currentSize,
        opacity: engine.currentOpacity,
        spacing: engine.currentSpacing,
        hardness: engine.currentHardness,
      );
    } catch (e) {
      // An older bridge without the param exports must not crash the
      // inspector — degrade to the Dart parse.
      return _InspectData(
        fromEngine: false,
        params: dartParams(),
        engineError: e.toString(),
        paintopId: preset.paintopId,
        isEraser: preset.isEraserPreset,
      );
    } finally {
      try {
        engine.dispose();
      } catch (_) {}
    }
  }

  List<MapEntry<String, String>> get _filteredParams {
    final d = _data;
    if (d == null) return const [];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return d.params.entries.toList();
    return d.params.entries
        .where((e) =>
            e.key.toLowerCase().contains(q) ||
            e.value.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: GlassContainer(
        width: double.infinity,
        height: 640,
        padding: const EdgeInsets.all(16),
        color: AppTheme.darkGlass.withOpacity(0.7),
        child: d == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    preset: widget.preset,
                    data: d,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(height: 10),
                  _CuratedGrid(data: d),
                  const SizedBox(height: 10),
                  _SearchField(
                    query: _query,
                    count: _filteredParams.length,
                    total: d.params.length,
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: _filteredParams.isEmpty
                        ? Center(
                            child: Text(
                              'no settings match “$_query”',
                              style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: 12,
                              ),
                            ),
                          )
                        : _ParamList(entries: _filteredParams),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Header: preset name, file, source badge.
// ---------------------------------------------------------------------
class _Header extends StatelessWidget {
  const _Header({
    required this.preset,
    required this.data,
    required this.onClose,
  });

  final BrushPreset preset;
  final _InspectData data;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final file = preset.filePath == null
        ? ''
        : preset.filePath!.replaceAll('\\', '/').split('/').last;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                preset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                file.isEmpty ? 'no file' : file,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ),
        _SourceBadge(fromEngine: data.fromEngine),
        const SizedBox(width: 6),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20),
          onPressed: onClose,
        ),
      ],
    );
  }
}

/// Where the raw map came from: the native engine's C ABI projection or
/// the pure-Dart parse stand-in.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.fromEngine});

  final bool fromEngine;

  @override
  Widget build(BuildContext context) {
    final ok = fromEngine;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (ok ? AppTheme.toolDraw : AppTheme.accent).withOpacity(0.18),
        borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
        border: Border.all(
          color: ok ? AppTheme.toolDraw : AppTheme.accent,
          width: 0.6,
        ),
      ),
      child: Text(
        ok ? 'ENGINE' : 'DART PARSE',
        style: TextStyle(
          color: ok ? AppTheme.toolDraw : AppTheme.accent,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Curated view: the engine's resolved identity fields.
// ---------------------------------------------------------------------
class _CuratedGrid extends StatelessWidget {
  const _CuratedGrid({required this.data});

  final _InspectData data;

  String _fmt(double? v) =>
      v == null ? '—' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  @override
  Widget build(BuildContext context) {
    final err = data.loadError ?? data.engineError;
    final fields = <(String, String)>[
      ('paintop', data.paintopId.isEmpty ? '—' : data.paintopId),
      ('size', _fmt(data.size)),
      ('opacity', data.opacity == null ? '—' : '${(data.opacity! * 100).toStringAsFixed(0)}%'),
      ('spacing', _fmt(data.spacing)),
      ('hardness', _fmt(data.hardness)),
      ('eraser', data.isEraser ? 'yes' : 'no'),
      ('embedded name',
          data.presetName.isEmpty ? '—' : data.presetName),
      ('params', data.params.length.toString()),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final f in fields)
              _CuratedChip(label: f.$1, value: f.$2),
          ],
        ),
        if (err != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              border: Border.all(color: Colors.redAccent.withOpacity(0.4), width: 0.6),
            ),
            child: Text(
              err,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }
}

class _CuratedChip extends StatelessWidget {
  const _CuratedChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.darkGlassLight.withOpacity(0.55),
        borderRadius: BorderRadius.circular(AppTheme.radiusCircular),
        border: Border.all(color: AppTheme.glassBorder, width: 0.5),
      ),
      child: Text.rich(
        TextSpan(
          text: '$label  ',
          style: const TextStyle(
            color: AppTheme.textTertiary,
            fontSize: 10.5,
          ),
          children: [
            TextSpan(
              text: value,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Raw settings view: search + document-ordered map rows.
// ---------------------------------------------------------------------
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.query,
    required this.count,
    required this.total,
    required this.onChanged,
  });

  final String query;
  final int count;
  final int total;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: TextField(
        onChanged: onChanged,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12.5),
        decoration: InputDecoration(
          hintText: 'filter name or value…',
          hintStyle: const TextStyle(color: AppTheme.textTertiary, fontSize: 12),
          prefixIcon: const Icon(Icons.search,
              color: AppTheme.textTertiary, size: 16),
          prefixIconConstraints: const BoxConstraints(minWidth: 30),
          isDense: true,
          filled: true,
          fillColor: AppTheme.darkGlassLight.withOpacity(0.5),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            borderSide: BorderSide.none,
          ),
          suffixText: '$count/$total',
          suffixStyle: const TextStyle(
              color: AppTheme.textTertiary, fontSize: 10.5),
        ),
      ),
    );
  }
}

class _ParamList extends StatelessWidget {
  const _ParamList({required this.entries});

  final List<MapEntry<String, String>> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.darkGlassLight.withOpacity(0.35),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: AppTheme.glassBorder, width: 0.5),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: entries.length,
        separatorBuilder: (_, __) =>
            Container(height: 0.5, color: AppTheme.glassBorder),
        itemBuilder: (context, i) => _ParamRow(
          name: entries[i].key,
          value: entries[i].value,
          index: i,
        ),
      ),
    );
  }
}

/// One raw setting row: document index, param name, CDATA value. Values
/// can be long (sensor curves embed whole XML blobs) — tapping toggles
/// between the 2-line preview and the full text.
class _ParamRow extends StatefulWidget {
  const _ParamRow({
    required this.name,
    required this.value,
    required this.index,
  });

  final String name;
  final String value;
  final int index;

  @override
  State<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends State<_ParamRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final value = widget.value.trim();
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${widget.index + 1}',
                style: const TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 10,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.name,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    value.isEmpty ? '∅' : value,
                    maxLines: _expanded ? null : 2,
                    overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      height: 1.25,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontStyle: value.isEmpty ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
