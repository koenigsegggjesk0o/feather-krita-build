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
    // Unified undo journal (loop-20): StrokeManager mutations record
    // their pre-op state here instead of the manager's private stacks,
    // so strokes AND texture undo/redo in lockstep.
    _strokes.onBeforeMutate = _captureStrokeMutation;
    _tryLoadBrushEngine();
    _applyBrushToEngine();
  }

  final StrokeManager _strokes;
  final CameraController _camera;
  final TexturePainter texture;
  GuideSurface guideSurface;
  final List<BrushPreset> presets;

  KritaBrushEngine? _brushEngine;

  // ----- Unified undo journal (loop-20) -----------------------------------

  /// Max unified undo steps. Paint-stroke entries carry a full texture
  /// snapshot (16 MB at the default 2048x2048), matching the old
  /// TexturePainter budget; strokes-only entries are just JSON.
  static const int maxUndoSteps = 30;

  final List<_UndoEntry> _undoJournal = <_UndoEntry>[];
  final List<_UndoEntry> _redoJournal = <_UndoEntry>[];

  /// Pending pre-stroke state between [beginPaintStroke] and
  /// [endPaintStroke] (canvas pointer-down .. pointer-up).
  String? _pendingStrokeJson;
  Uint8List? _pendingTexture;

  /// Journal hook for StrokeManager-driven mutations (move / rotate /
  /// scale / liquify / delete / mirror / split). These never touch the
  /// texture, so the entry records strokes-only state.
  void _captureStrokeMutation() {
    _pushJournal(_UndoEntry(strokes: _strokes.toJsonString()));
  }

  void _pushJournal(_UndoEntry entry) {
    _undoJournal.add(entry);
    if (_undoJournal.length > maxUndoSteps) _undoJournal.removeAt(0);
    _redoJournal.clear();
  }

  /// Captures an explicit unified undo entry. Used by callers that
  /// perform a texture-affecting operation outside the paint-stroke
  /// flow (project load, new document).
  void captureUndo({bool withTexture = false}) {
    _pushJournal(_UndoEntry(
      strokes: _strokes.toJsonString(),
      texture: withTexture ? texture.snapshot() : null,
    ));
  }

  /// Opens a paint-stroke undo transaction (canvas pointer-down). The
  /// pre-stroke strokes+texture state is held pending; [endPaintStroke]
  /// commits it as ONE journal entry, or [discardPaintStroke] drops it.
  /// Replaces the old TexturePainter-internal stroke transaction so the
  /// pixels and the stroke list can never diverge across undo (loop-20).
  void beginPaintStroke() {
    _pendingStrokeJson ??= _strokes.toJsonString();
    _pendingTexture ??= texture.snapshot();
  }

  /// Commits the pending paint-stroke transaction: records ONE journal
  /// entry covering the whole stroke, then adds [stroke] to the document
  /// (without a second manager-side entry).
  void endPaintStroke(Stroke stroke) {
    final strokesJson = _pendingStrokeJson;
    final textureSnapshot = _pendingTexture;
    _pendingStrokeJson = null;
    _pendingTexture = null;
    if (strokesJson == null) {
      // No matching begin (defensive) — fall back to manager-side
      // history so the stroke add is still undoable.
      _strokes.addStroke(stroke, recordUndo: true);
      return;
    }
    _pushJournal(_UndoEntry(strokes: strokesJson, texture: textureSnapshot));
    _strokes.addStroke(stroke, recordUndo: false);
  }

  /// Drops the pending paint-stroke transaction (pointer released
  /// without a drawable hit — nothing to undo).
  void discardPaintStroke() {
    _pendingStrokeJson = null;
    _pendingTexture = null;
  }

  /// Cancels an in-flight paint transaction before an undo/redo: its
  /// pending snapshot belongs to an operation that never committed.
  void _cancelPendingStroke() {
    _pendingStrokeJson = null;
    _pendingTexture = null;
  }

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
  double _brushSmoothing = 0.0; // loop-25: 0 = off, 1 = max stabilizer.
  // 5-loop-40: flow (per-dab application rate) and hardness (mask fade).
  // Defaults match the native bridge: flow 1.0 (full build-up), hardness
  // 0.85 (the real wrapper's default auto-brush hardness).
  double _brushFlow = 1.0;
  double _brushHardness = 0.85;
  int _brushColor = 0xFF1A1A1A;
  String _brushPresetName = 'Basic Round';

  /// Recently-used brush colours (most-recent-first). Loop-27.
  /// Capped at [kMaxColorHistory]. Mutated by [recordColor] (called from
  /// [setBrushColor]) and persisted via [onColorHistoryChanged].
  static const int kMaxColorHistory = 12;
  final List<int> _colorHistory = <int>[];

  /// Optional persistence hook — set by the settings screen to write the
  /// colour history to SharedPreferences whenever it mutates. Not fired
  /// by [loadColorHistory] (a restore, not a user mutation).
  ValueChanged<List<int>>? onColorHistoryChanged;

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
  double get brushSmoothing => _brushSmoothing;

  /// The brush flow (per-dab application rate) in [0, 1] (5-loop-40).
  /// Flow < 1 scales every dab's alpha so paint builds up gradually —
  /// orthogonal to [brushOpacity], which scales the whole stroke at the
  /// compositor level (Krita's flow-vs-opacity semantics).
  double get brushFlow => _brushFlow;

  /// The brush hardness in [0, 1] (5-loop-40). 0 = fully soft gaussian
  /// falloff, 1 = hard-edged disk. Setting it rebuilds the real engine's
  /// mask generator (explicit override supersedes the preset brush until
  /// the next preset load).
  double get brushHardness => _brushHardness;

  int get brushColor => _brushColor;
  String get brushPresetName => _brushPresetName;

  /// The recently-used brush colours, most-recent-first (loop-27).
  /// Unmodifiable view; mutate via [recordColor] / [loadColorHistory] /
  /// [removeFromColorHistory] / [clearColorHistory].
  List<int> get colorHistory => List.unmodifiable(_colorHistory);

  bool get canUndo => _undoJournal.isNotEmpty;
  bool get canRedo => _redoJournal.isNotEmpty;

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
    // Flow/hardness (5-loop-40) are newer ABI entry points than the rest:
    // a bridge library built before them lacks the symbols, and the FFI
    // bindings are deliberately strict so the CI smoke gates catch that.
    // The UI, however, must never crash on an older bridge — degrade
    // gracefully (engine keeps its built-in values).
    try {
      e
        ..flow = _brushFlow
        ..hardness = _brushHardness;
    } catch (_) {
      // Pre-flow/hardness bridge — ignore.
    }
  }

  // ----- Preset library -------------------------------------------------

  /// Bundled .kpp assets seeded into the user presets folder on first
  /// load so the picker always has something to show and users can drop
  /// their own .kpp files right next to them.
  ///
  /// Since 5-loop-38 the bundle includes UNMODIFIED stock presets from
  /// the Krita project (per-paintop defaults + named stock presets,
  /// legacy PNG preset containers) — see assets/brushes/README.md for
  /// provenance and license.
  static const List<String> kBundledPresetAssets = <String>[
    // Real Krita stock presets (PNG preset containers).
    'krita_paintbrush.kpp',
    'krita_eraser.kpp',
    'krita_roundmarker.kpp',
    'krita_spraybrush.kpp',
    'krita_smudge.kpp',
    'krita_colorsmudge.kpp',
    'krita_sketchbrush.kpp',
    'krita_curvebrush.kpp',
    'krita_particlebrush.kpp',
    'krita_deformbrush.kpp',
    'krita_hairybrush.kpp',
    'krita_waterc_round_grain.kpp',
    'krita_waterc_round_fringe.kpp',
    'krita_waterc_spread.kpp',
    'stock_basic_5_size.kpp',
    'stock_eraser_circle.kpp',
    // Synthetic minimal presets (pre-5-loop-38 bundle).
    'basic_soft_round.kpp',
    'ink_fineliner.kpp',
    'airbrush_soft.kpp',
  ];

  /// Display names for bundled presets whose embedded XML name is a
  /// generic internal default (e.g. "defaultPreset", "my_round_preset")
  /// or carries file-name noise ("b)_Basic-5_Size"). Keyed by asset file
  /// name; applied after the folder scan in [loadPresetLibrary]. Presets
  /// not listed here keep the name parsed from their preset XML.
  static const Map<String, String> kBundledPresetDisplayNames = <String, String>{
    'krita_paintbrush.kpp': 'Paintbrush',
    'krita_eraser.kpp': 'Eraser',
    'krita_roundmarker.kpp': 'Round Marker',
    'krita_spraybrush.kpp': 'Airbrush Spray',
    'krita_smudge.kpp': 'Smudge',
    'krita_colorsmudge.kpp': 'Color Smudge',
    'krita_sketchbrush.kpp': 'Sketch',
    'krita_curvebrush.kpp': 'Curve',
    'krita_particlebrush.kpp': 'Particle',
    'krita_deformbrush.kpp': 'Deform',
    'krita_hairybrush.kpp': 'Hairy',
    'krita_waterc_round_grain.kpp': 'Watercolor Round Grain',
    'krita_waterc_round_fringe.kpp': 'Watercolor Fringe',
    'krita_waterc_spread.kpp': 'Watercolor Spread',
    'stock_basic_5_size.kpp': 'Basic-5 Size',
    'stock_eraser_circle.kpp': 'Eraser Circle',
  };

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
    _applyBundledDisplayNames(found);
    presets
      ..clear()
      ..addAll(found);
    notifyListeners();
  }

  /// Upgrades generic embedded preset names to the curated bundled
  /// display names (5-loop-38). Only bundled assets listed in
  /// [kBundledPresetDisplayNames] are affected; user presets and any
  /// preset whose file name is not in the map keep their parsed name.
  void _applyBundledDisplayNames(List<BrushPreset> list) {
    for (final p in list) {
      final file = p.filePath?.split(Platform.pathSeparator).last;
      if (file == null) continue;
      final display = kBundledPresetDisplayNames[file];
      if (display != null && display.isNotEmpty) p.name = display;
    }
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

  /// Sets the brush flow (per-dab application rate) in [0, 1] (5-loop-40).
  /// Syncs to the native engine, where flow scales each dab's alpha
  /// (mask_alpha × pressure × flow) — the opacity slider stays
  /// orthogonal at the compositor level.
  void setBrushFlow(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_brushFlow == v) return;
    _brushFlow = v;
    try {
      _brushEngine?.flow = v;
    } catch (_) {
      // Older bridge without the flow ABI — state stays authoritative.
    }
    notifyListeners();
  }

  /// Sets the brush hardness in [0, 1] (5-loop-40). Syncs to the native
  /// engine, which rebuilds its mask generator with fade (1 - hardness)
  /// — an explicit user override that supersedes the preset brush until
  /// the next preset load re-seeds the slider.
  void setBrushHardness(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_brushHardness == v) return;
    _brushHardness = v;
    try {
      _brushEngine?.hardness = v;
    } catch (_) {
      // Older bridge without the hardness ABI — state stays authoritative.
    }
    notifyListeners();
  }

  /// Sets the brush-smoothing (stabilizer) strength in [0, 1]. Loop-25.
  /// 0 disables smoothing (raw stroke path); 1 applies the maximum
  /// symmetric moving-average window. The value is read by
  /// [CanvasWidget] when a stroke commits, so live dabbing is unaffected
  /// — only the recorded stroke geometry is smoothed.
  void setBrushSmoothing(double value) {
    final v = value.clamp(0.0, 1.0);
    if (_brushSmoothing == v) return;
    _brushSmoothing = v;
    notifyListeners();
  }

  void setBrushColor(int argb) {
    if (_brushColor == argb) return;
    _brushColor = argb;
    _brushEngine?.color = BrushColor.fromPacked(argb);
    // loop-27: record into the colour history (notifies + persists).
    recordColor(argb);
  }

  /// Records [argb] at the front of the colour history (loop-27). If the
  /// colour is already present it is moved to the front (no duplicate).
  /// The list is capped at [kMaxColorHistory]. Fires [onColorHistoryChanged]
  /// for persistence and notifies listeners.
  void recordColor(int argb) {
    _colorHistory.remove(argb);
    _colorHistory.insert(0, argb);
    if (_colorHistory.length > kMaxColorHistory) {
      _colorHistory.removeLast();
    }
    onColorHistoryChanged?.call(colorHistory);
    notifyListeners();
  }

  /// Restores the colour history from persisted storage (loop-27). Replaces
  /// the in-memory list (clamped to [kMaxColorHistory]); does NOT fire
  /// [onColorHistoryChanged] (this is a load, not a user mutation).
  void loadColorHistory(List<int> colors) {
    _colorHistory
      ..clear()
      ..addAll(colors.take(kMaxColorHistory));
    notifyListeners();
  }

  /// Removes [argb] from the colour history (loop-27). No-op if absent.
  void removeFromColorHistory(int argb) {
    if (_colorHistory.remove(argb)) {
      onColorHistoryChanged?.call(colorHistory);
      notifyListeners();
    }
  }

  /// Clears the colour history (loop-27). No-op if already empty.
  void clearColorHistory() {
    if (_colorHistory.isEmpty) return;
    _colorHistory.clear();
    onColorHistoryChanged?.call(colorHistory);
    notifyListeners();
  }

  void setBrushPresetName(String name) {
    if (_brushPresetName == name) return;
    _brushPresetName = name;
    notifyListeners();
  }

  /// Whether the last preset auto-switched the tool into eraser mode
  /// (5-loop-38). Used so that loading a NON-eraser preset afterwards
  /// returns the editor to the draw tool — but only when eraser mode was
  /// entered by preset auto-switching, never overriding a manual choice.
  bool _eraserAutoSwitched = false;

  /// Loads [preset] into the native brush engine (if available), reflects
  /// the preset's parameter values into the UI state (sliders, name) and
  /// updates the displayed preset name. Non-fatal if the engine rejects
  /// the preset — the synthetic dab fallback still works.
  ///
  /// Eraser presets (5-loop-38) auto-switch the active tool to
  /// [Tool.erase]; loading a non-eraser preset afterwards switches back
  /// to [Tool.draw] iff the eraser tool was entered by that auto-switch
  /// (see [_eraserAutoSwitched]). The decision is made from the preset's
  /// own paintop-settings ([BrushPreset.isEraserPreset], pure Dart) so it
  /// works identically with the real engine, the fallback bridge and in
  /// tests.
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
          // Flow + hardness seeding (5-loop-40). Flow: the pure-Dart
          // [BrushPreset.flowValue] parse is authoritative (mirrors the
          // engine's FlowValue mapping, works without a native engine and
          // in tests); it is pushed back to the engine so UI and engine
          // agree even if the two parses ever diverge. Hardness: the
          // ENGINE is authoritative — it resolved the real brush
          // definition (fade / hardness / Softness variants) — so the
          // slider is seeded from the engine's effective value. Both
          // engine round-trips are guarded: an older bridge library
          // without these symbols must not crash the preset load.
          _brushFlow = preset.flowValue.clamp(0.0, 1.0);
          try {
            e.flow = _brushFlow;
          } catch (_) {}
          try {
            _brushHardness = e.currentHardness.clamp(0.0, 1.0);
          } catch (_) {}
        } else {
          // Engine present but preset rejected: still seed flow from the
          // preset XML (pure Dart) so the slider tracks the selection.
          _brushFlow = preset.flowValue.clamp(0.0, 1.0);
        }
      } catch (_) {
        // Ignore — the synthetic dab fallback still works.
      }
    }

    // Engine absent (synthetic-dab fallback): flow still seeds from the
    // preset XML so the slider tracks the selection (5-loop-40).
    if (_brushEngine == null) {
      _brushFlow = preset.flowValue.clamp(0.0, 1.0);
    }

    // Auto-switch the tool to match the preset's eraser mode (5-loop-38).
    if (preset.isEraserPreset) {
      _eraserAutoSwitched = true;
      setActiveTool(Tool.erase);
    } else if (_eraserAutoSwitched) {
      _eraserAutoSwitched = false;
      if (_activeTool == Tool.erase) setActiveTool(Tool.draw);
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

  /// Reverts the last unified journal entry: strokes always, and the
  /// texture too when the entry recorded pixels (paint strokes, project
  /// loads, document resets). Before loop-20 this only reverted the
  /// stroke list, leaving stale painted pixels on the canvas.
  void undo() {
    _cancelPendingStroke();
    if (_undoJournal.isEmpty) return;
    final entry = _undoJournal.removeLast();
    _redoJournal.add(_UndoEntry(
      strokes: _strokes.toJsonString(),
      texture: entry.texture != null ? texture.snapshot() : null,
    ));
    final restoreTex = entry.texture;
    if (restoreTex != null) texture.restore(restoreTex);
    _strokes.fromJsonString(entry.strokes, recordUndo: false);
    notifyListeners();
  }

  /// Redoes a previously undone journal entry (see [undo]).
  void redo() {
    _cancelPendingStroke();
    if (_redoJournal.isEmpty) return;
    final entry = _redoJournal.removeLast();
    _undoJournal.add(_UndoEntry(
      strokes: _strokes.toJsonString(),
      texture: entry.texture != null ? texture.snapshot() : null,
    ));
    final restoreTex = entry.texture;
    if (restoreTex != null) texture.restore(restoreTex);
    _strokes.fromJsonString(entry.strokes, recordUndo: false);
    notifyListeners();
  }

  /// Dab source for stroke replay (GIF export, project-open texture
  /// restore). Strokes always replay with the pure-Dart synthetic dab at
  /// their own recorded color: the native engine only holds the single
  /// globally-configured color, which would repaint multi-color
  /// documents with the wrong palette.
  BrushDab replayDab(Stroke stroke, double pressure, double sizePx) {
    return syntheticDab(sizePx, stroke.color);
  }

  /// Clears the document and texture for a fresh canvas. Fully undoable
  /// since loop-20: the journal entry carries both the stroke list and
  /// the pre-reset pixels.
  void newDocument() {
    captureUndo(withTexture: true);
    _strokes.clearAll(recordUndo: false);
    texture.clear(pushUndo: false);
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
    _strokes.onBeforeMutate = null;
    _brushEngine?.dispose();
    _brushEngine = null;
    super.dispose();
  }
}

/// One unified undo step (loop-20): the pre-operation state of the
/// [StrokeManager] as JSON plus — for operations that modify canvas
/// pixels — a full [TexturePainter] snapshot. A null [texture] means the
/// operation never touched pixels, so undo/redo skips the (16 MB at the
/// default size) pixel restore entirely.
class _UndoEntry {
  _UndoEntry({required this.strokes, this.texture});
  final String strokes;
  final Uint8List? texture;
}
