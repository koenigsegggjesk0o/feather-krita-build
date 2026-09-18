// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// main_screen.dart — The real editor screen.
//
// Composes every production component around the live [EditorState]:
//   - [CanvasWidget]   — full-viewport software-rendered 3D canvas that
//                        raycasts pointer input onto the guide surface and
//                        stamps native Krita brush dabs into the texture.
//   - [GlassAppBar]    — document name, undo/redo, open + rename.
//   - [BrushSettingsPanel] — right dock wired to the native brush engine.
//   - [StrokeListPanel] — left dock (toggled with the Select tool).
//   - [JoystickWidget]  — move/rotate/scale/liquify the selection.
//   - [GlassBottomBar]  — the eight primary tools.
//   - [ExportScreen] / [SettingsScreen] / [BrushPickerScreen] dialogs.
//
// The screen owns one [EditorState]; tests may inject their own instance.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart' show Vector2, Vector3;

import 'package:feather_krita/theme/app_theme.dart';
import 'package:feather_krita/state/editor_state.dart';
import 'package:feather_krita/engine/stroke_manager.dart';
import 'package:feather_krita/ffi/krita_bindings.dart';
import 'package:feather_krita/io/app_dirs.dart';
import 'package:feather_krita/io/feather_project.dart';
import 'package:feather_krita/io/gif_exporter.dart';
import 'package:feather_krita/io/mp4_exporter.dart';
import 'package:feather_krita/io/gltf_exporter.dart';
import 'package:feather_krita/models/brush_preset.dart';
import 'package:feather_krita/models/export_format.dart';
import 'package:feather_krita/models/stroke.dart';
import 'package:feather_krita/screens/brush_picker_screen.dart';
import 'package:feather_krita/screens/export_screen.dart';
import 'package:feather_krita/screens/settings_screen.dart';
import 'package:feather_krita/widgets/brush_settings_panel.dart';
import 'package:feather_krita/widgets/canvas_widget.dart';
import 'package:feather_krita/widgets/glass_app_bar.dart';
import 'package:feather_krita/widgets/glass_bottom_bar.dart';
import 'package:feather_krita/widgets/joystick_widget.dart';
import 'package:feather_krita/widgets/open_project_dialog.dart';
import 'package:feather_krita/widgets/stroke_list_panel.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.state});

  /// Optional injected state (used by tests). When null the screen creates
  /// (and disposes) its own [EditorState].
  final EditorState? state;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late final EditorState _state;
  late final bool _ownsState;
  bool _showStrokeList = false;
  JoystickMode _joystickMode = JoystickMode.move;

  @override
  void initState() {
    super.initState();
    _ownsState = widget.state == null;
    _state = widget.state ?? EditorState();
    // Fire-and-forget: the picker rebuilds via notifyListeners when the
    // scan completes.
    _state.loadPresetLibrary().catchError((_) {});
  }

  @override
  void dispose() {
    if (_ownsState) _state.dispose();
    super.dispose();
  }

  // ----- Tool handling ----------------------------------------------------

  void _onTool(Tool tool) {
    switch (tool) {
      case Tool.export:
        _showExportSheet();
        return;
      case Tool.settings:
        _showSettingsSheet();
        return;
      case Tool.select:
        setState(() => _showStrokeList = !_showStrokeList);
        break;
      case Tool.light:
        _state.showGrid = !_state.showGrid;
        _state.showMirrorPlanes = _state.showGrid;
        _state.notify();
        return;
      default:
        break;
    }
    _state.setActiveTool(tool);
  }

  // ----- Dialogs ----------------------------------------------------------

  void _showExportSheet() {
    HapticFeedback.selectionClick();
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => ExportScreen(
        isPro: _state.isPro,
        baseName: _state.fileName.replaceAll(RegExp(r'\.feather$'), ''),
        exporter: _runExport,
        onUpgrade: () => _toast('Pro upgrade is not wired yet — stay tuned!'),
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  void _showSettingsSheet() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => SettingsScreen(
        state: _state,
        onUpgrade: () => _toast('Pro upgrade is not wired yet — stay tuned!'),
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  Future<void> _pickPreset() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrushPickerScreen(
          presets: _state.presets,
          activePresetId: null,
          onPick: (BrushPreset preset) {
            _state.loadBrushPreset(preset);
            Navigator.of(context).pop();
          },
          onImport: () =>
              _toast('Copy .kpp files to ${presetsDir().path} — they appear in the picker on the next launch.'),
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xCC1A1A2E),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
  }

  // ----- Exporter ---------------------------------------------------------

  static Directory _exportDir() => exportsDir();

  /// Real export implementation behind [ExportScreen]'s [ExportRunner].
  ///
  /// All filesystem work is synchronous on purpose: the image encoder is
  /// synchronous anyway, and keeping the whole operation on microtasks
  /// makes the future complete under Flutter's fake-async widget tests
  /// (real async I/O never completes inside a fake event loop).
  Future<String> _runExport(
    ExportFormat format,
    int quality,
    void Function(double progress) onProgress,
  ) async {
    try {
      onProgress(0.1);
      final dir = _exportDir();
      final baseName =
          _state.fileName.replaceAll(RegExp(r'\.feather$'), '');
      final safe = baseName.replaceAll(RegExp(r'[^\w\- ]'), '_');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final info = exportInfo(format);
      final path =
          '${dir.path}${Platform.pathSeparator}$safe-$stamp.${info.extension}';

      switch (format) {
        case ExportFormat.png:
          onProgress(0.4);
          File(path).writeAsBytesSync(_encodeTexture());
          break;
        case ExportFormat.jpeg:
          onProgress(0.4);
          File(path).writeAsBytesSync(
              _encodeTexture(jpegQuality: quality));
          break;
        case ExportFormat.obj:
          onProgress(0.5);
          File(path).writeAsStringSync(_buildObj());
          break;
        case ExportFormat.featherProject:
          onProgress(0.5);
          File(path).writeAsStringSync(_buildProjectJson());
          break;
        case ExportFormat.gltf:
          onProgress(0.5);
          File(path).writeAsStringSync(
              buildGltf(_state.guideSurface.mesh, name: safe));
          break;
        case ExportFormat.gif:
          onProgress(0.2);
          final gif = GifExporter(
            frameCount: 8 + quality ~/ 10,
          ).export(
            strokes: _state.strokes.strokes,
            dabFor: _replayDab,
            brushSizePx: _state.brushSize,
            brushOpacity: _state.brushOpacity,
            sourceTextureSize: _state.texture.width,
            onProgress: (p) => onProgress(0.2 + p * 0.8),
          );
          File(path).writeAsBytesSync(gif);
          break;
        case ExportFormat.mp4:
          onProgress(0.2);
          final mp4 = Mp4Exporter(
            frameCount: 12 + quality ~/ 8,
          ).export(
            strokes: _state.strokes.strokes,
            dabFor: _replayDab,
            brushSizePx: _state.brushSize,
            brushOpacity: _state.brushOpacity,
            sourceTextureSize: _state.texture.width,
            onProgress: (p) => onProgress(0.2 + p * 0.8),
          );
          File(path).writeAsBytesSync(mp4);
          break;
      }
      onProgress(1.0);
      return path;
    } catch (e) {
      return 'error: $e';
    }
  }

  List<int> _encodeTexture({int? jpegQuality}) {
    final tex = _state.texture;
    final image = img.Image(tex.width, tex.height);
    final px = tex.pixels;
    for (var y = 0; y < tex.height; y++) {
      for (var x = 0; x < tex.width; x++) {
        final i = y * tex.stride + x * 4;
        // The image package (3.x) stores pixels as #AABBGGRR — R in the
        // LOW byte. Packing ARGB here would silently swap red and blue in
        // every exported PNG/JPEG.
        final packed = (px[i + 3] << 24) |
            (px[i + 2] << 16) |
            (px[i + 1] << 8) |
            px[i];
        image.setPixel(x, y, packed);
      }
    }
    if (jpegQuality != null) return img.encodeJpg(image, quality: jpegQuality);
    return img.encodePng(image);
  }

  /// Serialises the active guide surface as a Wavefront OBJ file with
  /// vertices, UVs, normals and triangulated faces.
  String _buildObj() {
    final mesh = _state.guideSurface.mesh;
    final buf = StringBuffer()
      ..writeln('# Feather-Krita OBJ export')
      ..writeln('# ${mesh.positions.length} vertices');
    for (final p in mesh.positions) {
      buf.writeln('v ${p.x.toStringAsFixed(6)} '
          '${p.y.toStringAsFixed(6)} ${p.z.toStringAsFixed(6)}');
    }
    for (final t in mesh.uvs) {
      buf.writeln('vt ${t.x.toStringAsFixed(6)} ${t.y.toStringAsFixed(6)}');
    }
    for (final n in mesh.normals) {
      buf.writeln('vn ${n.x.toStringAsFixed(6)} '
          '${n.y.toStringAsFixed(6)} ${n.z.toStringAsFixed(6)}');
    }
    for (var i = 0; i + 2 < mesh.indices.length; i += 3) {
      final a = mesh.indices[i] + 1;
      final b = mesh.indices[i + 1] + 1;
      final c = mesh.indices[i + 2] + 1;
      buf.writeln('f $a/$a/$a $b/$b/$b $c/$c/$c');
    }
    return buf.toString();
  }

  String _buildProjectJson() {
    return FeatherProjectDocument.fromEditor(_state).toJsonString();
  }

  /// Dab source for GIF stroke replay. Delegates to [EditorState]'s
  /// shared replay rule (synthetic dab at the stroke's recorded color —
  /// the native engine only holds the globally-configured color, which
  /// would repaint multi-color documents with the wrong palette).
  BrushDab _replayDab(Stroke stroke, double pressure, double sizePx) {
    return _state.replayDab(stroke, pressure, sizePx);
  }

  // ----- Open project -----------------------------------------------------

  Future<void> _showOpenProject() async {
    HapticFeedback.selectionClick();
    final path = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => OpenProjectDialog(initialDir: _exportDir().path),
    );
    if (path == null || !mounted) return;
    try {
      final doc = FeatherProjectDocument.parse(File(path).readAsStringSync());
      doc.applyTo(_state);
      if (mounted) setState(() {});
      _toast('Opened ${doc.fileName} — ${doc.strokes.length} strokes.');
    } catch (e) {
      _toast('Could not open project: $e');
    }
  }

  // ----- Joystick ---------------------------------------------------------

  void _onJoystickInput(Vector2 input) {
    final strokes = _state.strokes;
    if (strokes.selectedStrokes.isEmpty) return;
    switch (_joystickMode) {
      case JoystickMode.move:
        strokes
          ..applyJoystickTransform(input, TransformMode.move)
          ..notify();
        break;
      case JoystickMode.rotate:
        strokes
          ..applyJoystickTransform(input, TransformMode.rotate)
          ..notify();
        break;
      case JoystickMode.scale:
        strokes
          ..applyJoystickTransform(input, TransformMode.scale)
          ..notify();
        break;
      case JoystickMode.liquify:
        final center = _selectionCenter(strokes);
        if (center == null) return;
        final strength = input.length.clamp(0.0, 1.0) * 0.10;
        if (strength <= 0) return;
        strokes.applyLiquify(
          LiquifyMode.push,
          center,
          0.5,
          strength,
          _state.camera.forward,
        );
        strokes.notify();
        break;
    }
    setState(() {});
  }

  static Vector3? _selectionCenter(StrokeManager strokes) {
    final selected = strokes.selectedStrokes;
    if (selected.isEmpty) return null;
    var sum = Vector3.zero();
    for (final s in selected) {
      sum += s.worldCenter();
    }
    return sum / selected.length.toDouble();
  }

  // ----- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.canvasBackground,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _state,
          builder: (context, _) {
            final showJoystick =
                _state.activeTool == Tool.select ||
                    _state.activeTool == Tool.liquify;
            return Stack(
              children: [
                // The real 3D canvas viewport.
                Positioned.fill(child: CanvasWidget(state: _state)),

                // Top app bar.
                Positioned(
                  top: 8,
                  left: 12,
                  right: 12,
                  child: GlassAppBar(
                    fileName: _state.fileName,
                    canUndo: _state.canUndo,
                    canRedo: _state.canRedo,
                    onUndo: _state.undo,
                    onRedo: _state.redo,
                    onOpenFolder: _showOpenProject,
                    onRename: (name) => setState(() => _state.fileName = name),
                    onShowSettings: _showSettingsSheet,
                  ),
                ),

                // Left dock — stroke list (Select tool).
                if (_showStrokeList)
                  Positioned(
                    top: 76,
                    bottom: 108,
                    left: 12,
                    child: StrokeListPanel(
                      manager: _state.strokes,
                      onClose: () => setState(() => _showStrokeList = false),
                    ),
                  ),

                // Right dock — brush settings.
                Positioned(
                  top: 76,
                  bottom: 108,
                  right: 12,
                  child: BrushSettingsPanel(
                    state: _state,
                    onPickPreset: _pickPreset,
                  ),
                ),

                // Selection joystick.
                if (showJoystick)
                  Positioned(
                    right: 24,
                    bottom: 104,
                    child: JoystickWidget(
                      mode: _joystickMode,
                      onModeChanged: (m) => setState(() => _joystickMode = m),
                      onInput: _onJoystickInput,
                    ),
                  ),

                // Bottom tool dock.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: Center(
                    child: GlassBottomBar(
                      activeTool: _state.activeTool,
                      onToolSelected: _onTool,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}


