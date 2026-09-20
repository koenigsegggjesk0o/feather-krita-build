// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// brush_preset.dart — Krita brush preset model.
//
// Krita brush presets (.kpp) are ZIP archives containing an XML
// description of the brush settings and a PNG thumbnail. This file
// implements:
//   - The [BrushPreset] data model (name, paintop, settings, thumbnail).
//   - A loader that opens .kpp files (or unpacked XML presets) and
//     extracts the relevant data.
//   - A directory scanner that lists all presets in a folder.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart' as xml;

/// A single brush setting value. Krita settings can be numeric, boolean,
/// or string-typed (e.g. "curve" definitions).
class BrushSettingValue {
  const BrushSettingValue({
    required this.name,
    required this.value,
    this.type = BrushSettingType.scalar,
    this.min = 0.0,
    this.max = 1.0,
    this.description = '',
  });

  /// Krita setting ID (e.g. "radius", "opacity", "pressure_curve").
  final String name;

  /// The serialized value. For scalars this is a double stored as a
  /// string; for curves it's the raw XML; for booleans it's "true"/"false".
  final String value;

  final BrushSettingType type;

  final double min;
  final double max;
  final String description;

  /// Parses the value as a double, or returns `null` if not numeric.
  double? get asScalar => double.tryParse(value);

  /// Parses the value as a boolean.
  bool get asBool =>
      value.toLowerCase() == 'true' || value == '1' || value == '1.0';

  /// Returns the value clamped to [min]..[max] as a double.
  double get clampedScalar {
    final v = asScalar ?? min;
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'type': type.name,
        'min': min,
        'max': max,
        'description': description,
      };

  factory BrushSettingValue.fromJson(Map<String, dynamic> json) {
    return BrushSettingValue(
      name: json['name'] as String,
      value: json['value'] as String,
      type: BrushSettingType.values.firstWhere(
        (t) => t.name == (json['type'] as String? ?? 'scalar'),
        orElse: () => BrushSettingType.scalar,
      ),
      min: (json['min'] as num?)?.toDouble() ?? 0.0,
      max: (json['max'] as num?)?.toDouble() ?? 1.0,
      description: json['description'] as String? ?? '',
    );
  }
}

/// Type of a brush setting value.
enum BrushSettingType {
  scalar,
  boolean,
  curve,
  string,
  integer,
}

/// A Krita brush preset.
///
/// A preset is identified by a unique [id] (typically the file name
/// without extension), a human-readable [name], the Krita paintop ID
/// (e.g. "basic_tip", "airbrush"), an optional thumbnail PNG, and a map
/// of [settings].
class BrushPreset {
  BrushPreset({
    required this.id,
    required this.name,
    required this.paintopId,
    Map<String, BrushSettingValue>? settings,
    this.thumbnail,
    this.filePath,
    this.description = '',
    this.isFavorite = false,
    this.category = 'Default',
  }) : settings = settings ?? <String, BrushSettingValue>{};

  /// Stable identifier (file name without extension).
  final String id;

  /// Human-readable display name.
  String name;

  /// Krita paint operation ID (e.g. "basic_tip", "airbrush", "pencil").
  String paintopId;

  /// Brush settings keyed by Krita setting name.
  final Map<String, BrushSettingValue> settings;

  /// Optional thumbnail PNG bytes (decoded lazily by the UI).
  Uint8List? thumbnail;

  /// Path to the source .kpp file, if loaded from disk.
  String? filePath;

  /// Free-form description shown in the preset browser.
  String description;

  /// Whether the user has marked this preset as favorite.
  bool isFavorite;

  /// Logical grouping shown in the preset browser (e.g. "Ink", "Pencil").
  String category;

  /// Returns the value of a scalar setting, or [fallback] if missing.
  double scalarSetting(String name, [double fallback = 0.0]) {
    final v = settings[name];
    if (v == null) return fallback;
    return v.clampedScalar;
  }

  /// Returns the value of a boolean setting, or [fallback] if missing.
  bool boolSetting(String name, [bool fallback = false]) {
    final v = settings[name];
    if (v == null) return fallback;
    return v.asBool;
  }

  /// Whether this preset selects eraser mode (5-loop-38).
  ///
  /// Mirrors the native bridge's detection (krita_bridge_real.cpp applies
  /// the same paintop-settings signals) plus the paintop identity itself:
  ///   - settings-level flags: Krita/erase, EraserMode, flat `eraser`
  ///   - CompositeOp == "erase" (how stock Krita eraser presets mark it)
  ///   - paintopid == "eraser" (Krita's per-paintop default eraser preset
  ///     carries no explicit flag — the paintop IS the eraser)
  ///
  /// Used by the editor to auto-switch the active tool when a preset is
  /// loaded, and by tests (pure Dart — no native engine required).
  bool get isEraserPreset {
    bool flag(String name) {
      final v = settings[name];
      if (v == null) return false;
      final s = v.value.toLowerCase();
      return s == 'true' || s == '1' || s == '1.0';
    }

    if (flag('Krita/erase') || flag('EraserMode') || flag('eraser')) {
      return true;
    }
    final composite = settings['CompositeOp']?.value.toLowerCase();
    if (composite == 'erase') return true;
    final paintop = paintopId.toLowerCase();
    return paintop == 'eraser' || paintop == 'erase';
  }

  /// The preset's flow (per-dab application rate) in [0, 1], default 1.0.
  ///
  /// Mirrors the native bridge's FlowValue mapping (krita_bridge_real.cpp
  /// reads the paintop FlowValue sensor base, falling back to 1.0 when the
  /// preset omits it). Pure Dart — no native engine required; used by the
  /// editor to seed the flow slider when a preset loads and by tests.
  double get flowValue {
    final v = settings['FlowValue'] ?? settings['flow'];
    if (v == null) return 1.0;
    final scalar = v.asScalar;
    if (scalar == null || scalar < 0.0 || scalar > 1.0) return 1.0;
    return scalar;
  }

  /// Sets a scalar setting, replacing any existing value.
  void setScalar(String name, double value,
      {double min = 0.0, double max = 1.0, String description = ''}) {
    settings[name] = BrushSettingValue(
      name: name,
      value: value.toString(),
      type: BrushSettingType.scalar,
      min: min,
      max: max,
      description: description,
    );
  }

  /// Sets a boolean setting.
  void setBool(String name, bool value, {String description = ''}) {
    settings[name] = BrushSettingValue(
      name: name,
      value: value ? 'true' : 'false',
      type: BrushSettingType.boolean,
      description: description,
    );
  }

  // ----- Serialization --------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'paintopId': paintopId,
        'settings': settings.map((k, v) => MapEntry(k, v.toJson())),
        'thumbnail': thumbnail != null
            ? base64Encode(thumbnail!)
            : null,
        'filePath': filePath,
        'description': description,
        'isFavorite': isFavorite,
        'category': category,
      };

  factory BrushPreset.fromJson(Map<String, dynamic> json) {
    final settingsMap = (json['settings'] as Map?)?.map(
          (k, v) => MapEntry(
            k.toString(),
            BrushSettingValue.fromJson(v as Map<String, dynamic>),
          ),
        ) ??
        <String, BrushSettingValue>{};
    final thumb = json['thumbnail'] as String?;
    return BrushPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      paintopId: json['paintopId'] as String,
      settings: settingsMap,
      thumbnail: thumb != null ? base64Decode(thumb) : null,
      filePath: json['filePath'] as String?,
      description: json['description'] as String? ?? '',
      isFavorite: json['isFavorite'] as bool? ?? false,
      category: json['category'] as String? ?? 'Default',
    );
  }

  /// Returns a deep copy of this preset.
  BrushPreset copy() => BrushPreset(
        id: id,
        name: name,
        paintopId: paintopId,
        settings: Map.fromEntries(
            settings.entries.map((e) => MapEntry(e.key, e.value))),
        thumbnail: thumbnail != null ? Uint8List.fromList(thumbnail!) : null,
        filePath: filePath,
        description: description,
        isFavorite: isFavorite,
        category: category,
      );

  // ----- .kpp loading ---------------------------------------------------

  /// Loads a brush preset from a .kpp file (ZIP) or an unpacked XML
  /// preset file.
  ///
  /// Throws [FormatException] if the file cannot be parsed.
  static Future<BrushPreset> loadFromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Brush preset file not found', path);
    }
    final bytes = await file.readAsBytes();
    return loadFromBytes(bytes, filePath: path);
  }

  /// Loads a brush preset from in-memory bytes.
  static BrushPreset loadFromBytes(Uint8List bytes, {String? filePath}) {
    final id = filePath != null
        ? filePath.split(Platform.pathSeparator).last.replaceAll('.kpp', '')
        : 'preset_${bytes.length.hashCode.toRadixString(16)}';

    // Detect ZIP signature (PK\x03\x04).
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      return _loadFromZip(bytes, id: id, filePath: filePath);
    }

    // Detect the legacy PNG preset container: Krita's stock presets are
    // PNG thumbnails whose preset XML lives in a compressed zTXt chunk
    // keyed "preset" (format version "2.2"). The PNG itself doubles as
    // the preset thumbnail.
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return _loadFromPng(bytes, id: id, filePath: filePath);
    }

    // Otherwise try parsing as plain XML.
    final xmlString = utf8.decode(bytes, allowMalformed: true);
    return _loadFromXmlString(xmlString, id: id, filePath: filePath);
  }

  /// Parses a ZIP-packaged .kpp file using the `archive` package.
  static BrushPreset _loadFromZip(
    Uint8List bytes, {
    required String id,
    String? filePath,
  }) {
    final archive = ZipDecoder().decodeBytes(bytes);
    String? presetXml;
    Uint8List? thumbnail;
    for (final entry in archive) {
      if (entry.isFile) {
        final name = entry.name.toLowerCase();
        final data = entry.content as Uint8List;
        if (name.endsWith('.png') ||
            name.contains('thumbnail') ||
            name.contains('preview')) {
          thumbnail = data;
        } else if (name.endsWith('.xml') ||
            name == 'preset' ||
            name.endsWith('preset')) {
          presetXml = utf8.decode(data, allowMalformed: true);
        }
      }
    }
    if (presetXml == null) {
      throw FormatException('No preset XML found inside .kpp archive');
    }
    final preset = _loadFromXmlString(presetXml, id: id, filePath: filePath);
    preset.thumbnail = thumbnail;
    return preset;
  }

  /// Parses a legacy PNG preset container (Krita's own stock presets):
  /// the preset XML is carried in a zTXt chunk with the keyword "preset"
  /// (one compression-method byte 0 + zlib stream) or a tEXt chunk with
  /// the same keyword (raw). The PNG image itself is used as the preset
  /// thumbnail.
  static BrushPreset _loadFromPng(
    Uint8List bytes, {
    required String id,
    String? filePath,
  }) {
    String? presetXml;
    var pos = 8; // skip the PNG signature
    while (pos + 8 <= bytes.length) {
      final length =
          (bytes[pos] << 24) | (bytes[pos + 1] << 16) |
          (bytes[pos + 2] << 8) | bytes[pos + 3];
      final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
      if (pos + 12 + length > bytes.length) break; // corrupt chunk
      final data = bytes.sublist(pos + 8, pos + 8 + length);
      if (type == 'zTXt' || type == 'tEXt') {
        final nul = data.indexOf(0);
        if (nul > 0) {
          final keyword = String.fromCharCodes(data.sublist(0, nul));
          if (keyword.toLowerCase() == 'preset') {
            if (type == 'tEXt') {
              presetXml = utf8.decode(data.sublist(nul + 1), allowMalformed: true);
            } else if (data.length > nul + 2 && data[nul + 1] == 0) {
              // zTXt: method byte 0 (zlib) then the zlib-wrapped stream.
              final inflated = ZLibDecoder().decodeBytes(
                data.sublist(nul + 2),
              );
              presetXml = utf8.decode(inflated, allowMalformed: true);
            }
          }
        }
      }
      if (type == 'IEND') break;
      pos += 12 + length; // length + type + data + crc
    }
    if (presetXml == null || presetXml.isEmpty) {
      throw const FormatException(
          'PNG preset container has no "preset" zTXt/tEXt chunk');
    }
    final preset = _loadFromXmlString(presetXml, id: id, filePath: filePath);
    preset.thumbnail = bytes;
    return preset;
  }

  /// Parses an unpacked preset XML string.
  static BrushPreset _loadFromXmlString(
    String xmlString, {
    required String id,
    String? filePath,
  }) {
    final document = xml.XmlDocument.parse(xmlString);

    // Tolerant root lookup: Krita ships several shapes — <Preset>,
    // <brush_definition>, and <Paintop> (the shape the native bridge
    // parses). Fall back to the document root when none match so
    // param-scanning still runs.
    Iterable<xml.XmlElement> presets = document.findAllElements('Preset');
    if (presets.isEmpty) {
      presets = document.findAllElements('brush_definition');
    }
    if (presets.isEmpty) {
      presets = document.findAllElements('Paintop');
    }
    if (presets.isEmpty) {
      presets = [document.rootElement];
    }
    final root = presets.first;

    final paintop = root.getAttribute('paintopid') ??
        root.getAttribute('paintop') ??
        root.findElements('paintop').firstOrNull?.getAttribute('id') ??
        (root.localName == 'Paintop' ? root.getAttribute('id') : null) ??
        'basic';

    var name = root.getAttribute('name') ?? root.getAttribute('id') ?? id;
    // A <Paintop id="paintbrush" name="paintbrush"> root is generic; the
    // file name is the meaningful preset name in that shape.
    if (root.localName == 'Paintop' && name == root.getAttribute('id')) {
      name = id;
    }

    final settings = <String, BrushSettingValue>{};
    // Krita stores each setting as <param name="...">value</param> — but
    // real files (and this app's bundled presets) use
    // <param id="..." value="..."/>. Accept both spellings, matching the
    // native bridge's parsePresetXml.
    void readParams(Iterable<xml.XmlElement> nodes) {
      for (final param in nodes) {
        final pname =
            param.getAttribute('name') ?? param.getAttribute('id');
        if (pname == null) continue;
        final value =
            param.getAttribute('value') ?? param.innerText.trim();
        settings[pname] = _classifySetting(pname, value);
      }
    }

    readParams(root.findAllElements('param'));
    readParams(root.findAllElements('brush_parameter'));
    // Some presets use <Setting name="...">...</Setting>.
    for (final s in root.findAllElements('Setting')) {
      final pname = s.getAttribute('name');
      if (pname == null) continue;
      final value = s.getAttribute('value') ?? s.innerText.trim();
      settings[pname] = _classifySetting(pname, value);
    }

    final description =
        root.findElements('description').firstOrNull?.innerText.trim() ?? '';

    return BrushPreset(
      id: id,
      name: name,
      paintopId: paintop,
      settings: settings,
      thumbnail: null,
      filePath: filePath,
      description: description,
    );
  }

  /// Heuristically classifies a setting value into the right
  /// [BrushSettingType] based on its content. Used during XML loading
  /// because Krita's XML format doesn't tag value types explicitly.
  static BrushSettingValue _classifySetting(String name, String value) {
    final lower = name.toLowerCase();
    if (lower.contains('curve')) {
      return BrushSettingValue(
        name: name,
        value: value,
        type: BrushSettingType.curve,
      );
    }
    if (lower == 'erase' || lower == 'smudge' || lower.contains('bool')) {
      return BrushSettingValue(
        name: name,
        value: value,
        type: BrushSettingType.boolean,
      );
    }
    final asDouble = double.tryParse(value);
    if (asDouble != null) {
      final isInt = asDouble.round() == asDouble && !value.contains('.');
      return BrushSettingValue(
        name: name,
        value: value,
        type: isInt ? BrushSettingType.integer : BrushSettingType.scalar,
        min: 0.0,
        max: name.toLowerCase().contains('size') ||
                name.toLowerCase().contains('radius')
            ? 1000.0
            : 1.0,
      );
    }
    return BrushSettingValue(
      name: name,
      value: value,
      type: BrushSettingType.string,
    );
  }

  // ----- Directory scanning ---------------------------------------------

  /// Scans [directory] for .kpp files and returns the loaded presets.
  /// Files that fail to parse are skipped (with the error reported via
  /// [onError] if provided).
  static Future<List<BrushPreset>> listFromDirectory(
    String directory, {
    void Function(String path, Object error)? onError,
  }) async {
    final dir = Directory(directory);
    if (!await dir.exists()) {
      return const <BrushPreset>[];
    }
    final out = <BrushPreset>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.kpp')) continue;
      try {
        final preset = await loadFromFile(entity.path);
        out.add(preset);
      } catch (e) {
        onError?.call(entity.path, e);
      }
    }
    return out;
  }

  /// Returns the default Krita preset paths for the current platform.
  /// These are the well-known locations where Krita installs its bundled
  /// presets.
  static List<String> defaultPresetSearchPaths() {
    if (Platform.isWindows) {
      final home = Platform.environment['APPDATA'] ?? '';
      return [
        '$home\\krita\\brushes',
        'C:\\Program Files\\krita\\share\\krita\\brushes',
      ];
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '/Users/Shared';
      return [
        '$home/Library/Application Support/krita/brushes',
        '/Applications/krita.app/Contents/Resources/brushes',
      ];
    }
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      return [
        '$home/.local/share/krita/brushes',
        '/usr/share/krita/brushes',
      ];
    }
    return const <String>[];
  }
}
