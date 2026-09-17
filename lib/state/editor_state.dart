// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// editor_state.dart — Shared UI state for the Feather-Krita editor.
//
// Holds the live engine instances (stroke manager, orbit camera, texture
// painter, guide surface, Krita brush engine) plus the per-session UI state
// (active tool, joystick mode, brush settings, mirror flags, pro status,
// file name) and forwards change notifications from the underlying
// [ChangeNotifier]s so a single [EditorState] listener can rebuild the
// whole editor.
//
// Widgets and screens consume this via construction injection; they should
// NOT mutate engine fields directly but use the setter helpers below so
// that the native brush engine and mirror configuration stay in sync.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:feather_krita/engine/stroke_manager.dart';
import 'package:feather_krita/engine/camera_controller.dart';
import 'package:feather_krita/engine/texture_painter.dart';
import 'package:feather_krita/engine/guide_surface.dart';
import 'package:feather_krita/engine/synthetic_dab.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/io/app_dirs.dart';
import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/models/stroke.dart';

/// The eight tools shown in the bottom toolbar.
enum Tool {
  draw,
  erase,
  shapes,
  liquify,
  select,
  light,
  export,
  settings,
}

/// The four modes of the floating 3D manipulation joystick. The first
/// three map 1:1 to [TransformMode]; [liquify] drives [StrokeManager.applyLiquify]
/// instead.
enum JoystickMode {
  move,
  rotate,
  scale,
  liquify,
}

/// Central editor state. Listens to [StrokeManager] and [CameraController]
/// and re-emits their change notifications so a single subscriber can
/// rebuild the editor chrome.
class EditorState extends ChangeNotifier {
  EditorState({
    StrokeManager? strokes,
    CameraController? camera,
    TexturePainter? texture,
    GuideSurface? guideSurface,
    List<BrushPreset>? presets,
    this.isPro = false,
    this.fileName = 'Untitled.feather',
  })  : _strokes = strokes ?? StrokeManager(),
        _camera = camera ?? CameraController(),
        texture = texture ?? TexturePainter(),
        guideSurface =
            guideSurface ?? GuideSurface.sphere(radius: 1.4, segments: 24, rings: 14),
        presets = presets ?? <BrushPreset>[] {
    _strokes.addListener(_forward);
    _camera.addListener(_forward);
    _tryLoadBrushEngine();
    _applyBrushToEngine();
  }

  final StrokeManager _strokes;
  final CameraController _camera;
  final TexturePainter texture;
  GuideSurface guideSurface;
  final List<BrushPreset> presets;

  KritaBrushEngine? _brushEngine;

  // ----- Session UI state -------------------------------------------------

  bool isPro;
  String fileName;
  bool showGrid = true;
  bool showMirrorPlanes = true;
  bool mirrorX = false;
  bool mirrorY = false;
  bool mirrorZ = false;

  Tool _activeTool = Tool.draw;
  JoystickMode _joystickMode = JoystickMode.move;

  double _brushSize = 32.0;
  double _brushOpacity = 1.0;
  double _brushSpacing = 0.10;
  double _brushSmudge = 0.0;
  int _brushColor = 0xFF1A1A1A;
  String _brushPresetName = 'Basic Round';

  // ----- Read accessors ---------------------------------------------------

  StrokeManager get strokes => _strokes;
  CameraController get camera => _camera;
  KritaBrushEngine? get brushEngine => _brushEngine;
  Tool get activeTool => _activeTool;
  JoystickMode get joystickMode => _joystickMode;
  double get brushSize => _brushSize;
  double get brushOpacity => _brushOpacity;
  double get brushSpacing => _brushSpacing;
  double get brushSmudge => _brushSmudge;
  int get brushColor => _brushColor;
  String get brushPresetName => _brushPresetName;

  bool get canUndo => _strokes.canUndo;
  bool get canRedo => _strokes.canRedo;

  // ----- Notification forwarding -----------------------------------------

  void _forward() => notifyListeners();

  /// Public change-notification wrapper. Widgets that mutate [EditorState]
  /// fields directly (e.g. grid toggles) call this to rebuild listeners.
  void notify() => notifyListeners();

  // ----- Brush engine lifecycle -----------------------------------------

  void _tryLoadBrushEngine() {
    try {
      _brushEngine = KritaBrushEngine();
    } catch (_) {
      // Native library unavailable (e.g. running without the bundled
      // krita_bridge). The UI falls back to a software-generated dab.
      _brushEngine = null;
    }
  }

  void _applyBrushToEngine() {
    final e = _brushEngine;
    if (e == null) return;
    e
      ..size = _brushSize
      ..opacity = _brushOpacity
      ..spacing = _brushSpacing
      ..smudge = _brushSmudge
      ..color = BrushColor.fromPacked(_brushColor);
  }

  // ----- Preset library -------------------------------------------------

  /// Bundled .kpp assets seeded into the user presets folder on first
  /// load so the picker always has something to show and users can drop
  /// their own .kpp files right next to them.
  static const List<String> kBundledPresetAssets = <String>[
    'basic_soft_round.kpp',
    'ink_fineliner.kpp',
    'airbrush_soft.kpp',
  ];

  /// Loads the brush-preset library: seeds the bundled .kpp presets into
  /// the user presets folder (idempotent), then scans that folder for
  /// every .kpp file. Failures are non-fatal (the synthetic dab fallback
  /// still works). Call once after construction; notifies on completion.
  ///
  /// [directory] overrides the scan folder (tests); defaults to
  /// [presetsDir()].
  Future<void> loadPresetLibrary({String? directory}) async {
    final found = <BrushPreset>[];
    try {
      final dir = directory != null
          ? Directory(directory)
          : presetsDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Seed bundled presets (skip anything already on disk).
      for (final name in kBundledPresetAssets) {
        final target = File('${dir.path}${Platform.pathSeparator}$name');
        if (target.existsSync()) continue;
        try {
          final data = await rootBundle.load('assets/brushes/$name');
          target.writeAsBytesSync(data.buffer.asUint8List(), flush: true);
        } catch (_) {
          // Asset missing (e.g. stripped build) — skip silently.
        }
      }

      found.addAll(await BrushPreset.listFromDirectory(dir.path));
    } catch (_) {
      // A broken folder must never take the editor down.
    }
    presets
      ..clear()
      ..addAll(found);
    notifyListeners();
  }

  // ----- Tool / mode setters --------------------------------------------

  void setActiveTool(Tool tool) {
    if (_activeTool == tool) return;
    _activeTool = tool;
    notifyListeners();
  }

  void setJoystickMode(JoystickMode mode) {
    if (_joystickMode == mode) return;
    _joystickMode = mode;
    notifyListeners();
  }

  // ----- Brush setters (sync to native engine) --------------------------

  void setBrushSize(double value) {
    final v = value.clamp(1.0, 500.0);
    if (_brushSize == v) return;
    _brushSize = v;
    _brushEngine?.size = v;
    notifyListeners();
  }

  void setBrushOpacity(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_brushOpacity == v) return;
    _brushOpacity = v;
    _brushEngine?.opacity = v;
    notifyListeners();
  }

  void setBrushSpacing(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_brushSpacing == v) return;
    _brushSpacing = v;
    _brushEngine?.spacing = v * 0.5; // engine accepts 0..5
    notifyListeners();
  }

  void setBrushSmudge(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_brushSmudge == v) return;
    _brushSmudge = v;
    _brushEngine?.smudge = v;
    notifyListeners();
  }

  void setBrushColor(int argb) {
    if (_brushColor == argb) return;
    _brushColor = argb;
    _brushEngine?.color = BrushColor.fromPacked(argb);
    notifyListeners();
  }

  void setBrushPresetName(String name) {
    if (_brushPresetName == name) return;
    _brushPresetName = name;
    notifyListeners();
  }

  /// Loads [preset] into the native brush engine (if available), reflects
  /// the preset's parameter values into the UI state (sliders, name) and
  /// updates the displayed preset name. Non-fatal if the engine rejects
  /// the preset — the synthetic dab fallback still works.
  void loadBrushPreset(BrushPreset preset) {
    _brushPresetName = preset.name;
    final path = preset.filePath;
    if (_brushEngine != null && path != null) {
      try {
        final e = _brushEngine!;
        if (e.loadPreset(path)) {
          // Reflect the native engine's values (parsed from the .kpp)
          // back into the session state so the UI stays in sync.
          if (e.currentSize > 0) _brushSize = e.currentSize.clamp(1.0, 500.0);
          if (e.currentOpacity > 0) {
            _brushOpacity = e.currentOpacity.clamp(0.0, 1.0);
          }
          if (e.currentSpacing > 0) {
            _brushSpacing = e.currentSpacing.clamp(0.0, 1.0);
          }
        }
      } catch (_) {
        // Ignore — the synthetic dab fallback still works.
      }
    }
    notifyListeners();
  }

  // ----- Mirror ----------------------------------------------------------

  /// Updates the X/Y/Z mirror flags and rewrites the [StrokeManager]'s
  /// [MirrorConfig], which regenerates any mirror copies of existing
  /// strokes.
  void setMirror({bool? x, bool? y, bool? z}) {
    if (x != null) mirrorX = x;
    if (y != null) mirrorY = y;
    if (z != null) mirrorZ = z;
    _strokes.setMirror(MirrorConfig(
      enabledX: mirrorX,
      enabledY: mirrorY,
      enabledZ: mirrorZ,
    ));
    notifyListeners();
  }

  // ----- Document operations --------------------------------------------

  void undo() => _strokes.undo();
  void redo() => _strokes.redo();

  /// Dab source for stroke replay (GIF export, project-open texture
  /// restore). Strokes always replay with the pure-Dart synthetic dab at
  /// their own recorded color: the native engine only holds the single
  /// globally-configured color, which would repaint multi-color
  /// documents with the wrong palette.
  BrushDab replayDab(Stroke stroke, double pressure, double sizePx) {
    return syntheticDab(sizePx, stroke.color);
  }

  /// Clears the document and texture for a fresh canvas.
  void newDocument() {
    _strokes.clearAll();
    texture.clear();
    fileName = 'Untitled.feather';
    notifyListeners();
  }

  /// Replaces the active guide surface with [surface].
  void setGuideSurface(GuideSurface surface) {
    guideSurface = surface;
    notifyListeners();
  }

  @override
  void dispose() {
    _strokes.removeListener(_forward);
    _camera.removeListener(_forward);
    _brushEngine?.dispose();
    _brushEngine = null;
    super.dispose();
  }
}
