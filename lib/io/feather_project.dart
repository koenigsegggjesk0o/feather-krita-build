// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// feather_project.dart — The .feather project document format.
//
// A project file is a single JSON document with:
//   version        — format version (1 = loop-11 writer, 2 = adds per-point
//                    UVs + nextId + mirror snapshot)
//   fileName       — display name (with .feather extension)
//   texture        — {width, height} of the paint texture
//   guideSurface   — display name of the guide surface type
//   brush          — {preset, size, opacity, color, mirrorX/Y/Z}
//   strokes        — the full stroke-manager snapshot (strokes, selectedIds,
//                    nextId, mirror) — a superset of StrokeManager's own
//                    serialization, so [FeatherProjectDocument.applyTo] can
//                    rebuild stroke history through StrokeManager.fromJsonString.
//
// Parsing is tolerant: missing optional fields fall back to sane defaults
// so v1 documents keep loading after the v2 writer ships.

import 'dart:convert';

import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/models/stroke.dart';
import 'package:feather_krita/state/editor_state.dart';

/// Current on-disk format version written by
/// [FeatherProjectDocument.fromEditor].
const int kFeatherProjectVersion = 2;

/// A parsed .feather project document.
class FeatherProjectDocument {
  FeatherProjectDocument({
    this.version = kFeatherProjectVersion,
    this.fileName = 'Untitled.feather',
    this.textureWidth = 2048,
    this.textureHeight = 2048,
    this.guideSurfaceName = 'Sphere',
    this.brushPreset = 'Basic Round',
    this.brushSize = 32.0,
    this.brushOpacity = 1.0,
    this.brushColor = 0xFF1A1A1A,
    this.mirrorX = false,
    this.mirrorY = false,
    this.mirrorZ = false,
    List<Stroke>? strokes,
  }) : strokes = strokes ?? <Stroke>[];

  final int version;
  final String fileName;
  final int textureWidth;
  final int textureHeight;
  final String guideSurfaceName;
  final String brushPreset;
  final double brushSize;
  final double brushOpacity;
  final int brushColor;
  final bool mirrorX;
  final bool mirrorY;
  final bool mirrorZ;
  final List<Stroke> strokes;

  /// The guide surface type for [guideSurfaceName].
  GuideSurfaceType get surfaceType =>
      guideSurfaceTypeFromName(guideSurfaceName);

  /// Parses a project document from [json]. Throws [FormatException] when
  /// the payload is not a JSON object or comes from an incompatible future
  /// version.
  factory FeatherProjectDocument.parse(String json) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Project root must be a JSON object.');
    }
    final version = (decoded['version'] as num?)?.toInt() ?? 1;
    if (version > kFeatherProjectVersion) {
      throw FormatException(
        'Project was saved by a newer app version '
        '(format v$version, supported v$kFeatherProjectVersion).',
      );
    }
    final texture = decoded['texture'];
    final brush = decoded['brush'];
    final strokesJson = decoded['strokes'];
    final strokeList = strokesJson is Map<String, dynamic>
        ? (strokesJson['strokes'] as List? ?? [])
        : (strokesJson is List ? strokesJson : []);
    return FeatherProjectDocument(
      version: version,
      fileName: decoded['fileName'] as String? ?? 'Untitled.feather',
      textureWidth: texture is Map<String, dynamic>
          ? (texture['width'] as num?)?.toInt() ?? 2048
          : 2048,
      textureHeight: texture is Map<String, dynamic>
          ? (texture['height'] as num?)?.toInt() ?? 2048
          : 2048,
      guideSurfaceName: decoded['guideSurface'] as String? ?? 'Sphere',
      brushPreset: brush is Map<String, dynamic>
          ? brush['preset'] as String? ?? 'Basic Round'
          : 'Basic Round',
      brushSize: brush is Map<String, dynamic>
          ? (brush['size'] as num?)?.toDouble() ?? 32.0
          : 32.0,
      brushOpacity: brush is Map<String, dynamic>
          ? (brush['opacity'] as num?)?.toDouble() ?? 1.0
          : 1.0,
      brushColor: brush is Map<String, dynamic>
          ? (brush['color'] as num?)?.toInt() ?? 0xFF1A1A1A
          : 0xFF1A1A1A,
      mirrorX: brush is Map<String, dynamic>
          ? brush['mirrorX'] as bool? ?? false
          : false,
      mirrorY: brush is Map<String, dynamic>
          ? brush['mirrorY'] as bool? ?? false
          : false,
      mirrorZ: brush is Map<String, dynamic>
          ? brush['mirrorZ'] as bool? ?? false
          : false,
      strokes: strokeList
          .whereType<Map<String, dynamic>>()
          .map(Stroke.fromJson)
          .toList(),
    );
  }

  /// Captures the current editor state as a project document.
  factory FeatherProjectDocument.fromEditor(EditorState state) {
    return FeatherProjectDocument(
      fileName: state.fileName,
      textureWidth: state.texture.width,
      textureHeight: state.texture.height,
      guideSurfaceName: guideSurfaceTypeName(state.guideSurface.type),
      brushPreset: state.brushPresetName,
      brushSize: state.brushSize,
      brushOpacity: state.brushOpacity,
      brushColor: state.brushColor,
      mirrorX: state.mirrorX,
      mirrorY: state.mirrorY,
      mirrorZ: state.mirrorZ,
      strokes: state.strokes.strokes.map((s) => s.copy()).toList(),
    );
  }

  /// Serializes to the on-disk JSON representation.
  String toJsonString() {
    String esc(String s) => s.replaceAll('"', r'\"');
    final nextId = strokes.fold<int>(1, (m, s) => m > s.id ? m : s.id + 1);
    final strokesJson = jsonEncode(strokes.map((s) => s.toJson()).toList());
    return '{"version":$version,'
        '"fileName":"${esc(fileName)}",'
        '"texture":{"width":$textureWidth,"height":$textureHeight},'
        '"guideSurface":"${esc(guideSurfaceName)}",'
        '"brush":{"preset":"${esc(brushPreset)}",'
        '"size":${brushSize.toStringAsFixed(2)},'
        '"opacity":${brushOpacity.toStringAsFixed(3)},'
        '"color":$brushColor,'
        '"mirrorX":$mirrorX,"mirrorY":$mirrorY,"mirrorZ":$mirrorZ},'
        '"strokes":{"strokes":$strokesJson,'
        '"selectedIds":[],"nextId":$nextId}}';
  }

  /// Restores this document into [state].
  ///
  /// Stroke data is applied through a StrokeManager snapshot so the load
  /// itself is undoable and mirror copies / ids are restored exactly as
  /// saved. Brush parameters and the guide surface are applied first so
  /// the restored document renders with the saved settings.
  void applyTo(EditorState state) {
    state
      ..fileName = fileName
      ..setBrushSize(brushSize)
      ..setBrushOpacity(brushOpacity)
      ..setBrushColor(brushColor)
      ..setBrushPresetName(brushPreset);
    state.setGuideSurface(GuideSurface.forType(surfaceType));

    final nextId = strokes.fold<int>(1, (m, s) => m > s.id ? m : s.id + 1);
    final snapshot = jsonEncode({
      'strokes': strokes.map((s) => s.toJson()).toList(),
      'selectedIds': <int>[],
      'nextId': nextId,
      'mirror': {
        'x': mirrorX,
        'y': mirrorY,
        'z': mirrorZ,
        'origin': [0.0, 0.0, 0.0],
      },
    });
    state.strokes.fromJsonString(snapshot, recordUndo: true);
    state
      ..mirrorX = mirrorX
      ..mirrorY = mirrorY
      ..mirrorZ = mirrorZ
      ..notify();
  }
}
