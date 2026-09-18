// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// undo_journal_test.dart — Unified undo journal (loop-20).
//
// Before loop-20 the app had TWO independent undo systems that could
// diverge: TexturePainter full-buffer snapshots (pixels) and
// StrokeManager JSON snapshots (strokes). EditorState.undo() only
// reverted the stroke list, so undoing a painted stroke left stale
// pixels on the canvas. The unified journal records BOTH states in one
// atomic entry per operation (pixels only for pixel-affecting ops).
//
// Tests run on a small 64x64 texture so snapshots are cheap.

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import 'package:feather_krita/engine/synthetic_dab.dart';
import 'package:feather_krita/engine/texture_painter.dart';
import 'package:feather_krita/io/feather_project.dart';
import 'package:feather_krita/models/stroke.dart';
import 'package:feather_krita/state/editor_state.dart';

EditorState _state() {
  return EditorState(
    texture: TexturePainter(width: 64, height: 64),
  );
}

/// Simulates the canvas paint flow (pointer-down .. pointer-up) through
/// the journal transaction API.
void _paintStroke(EditorState state, {int color = 0xFFFF0000}) {
  state.beginPaintStroke();
  final dab = syntheticDab(12, color);
  state.texture.paintDab(dab, 0.5, 0.5);
  state.endPaintStroke(Stroke(
    brushType: BrushType.basic,
    color: color,
    thickness: 12,
    points: [StrokePoint(position: Vector3(0.0, 0.0, 1.4), pressure: 1.0)],
  ));
}

Uint8List _pixels(EditorState state) =>
    Uint8List.fromList(state.texture.pixels);

void main() {
  group('Unified undo journal (loop-20)', () {
    test('undoing a painted stroke restores BOTH the stroke list and the '
        'texture pixels (the pre-loop-20 divergence bug)', () {
      final state = _state();
      _paintStroke(state);

      expect(state.strokes.strokeCount, 1);
      expect(state.texture.isEmpty, isFalse,
          reason: 'the stroke must have painted pixels');
      expect(state.canUndo, isTrue);

      state.undo();

      expect(state.strokes.strokeCount, 0,
          reason: 'the stroke list must revert');
      expect(state.texture.isEmpty, isTrue,
          reason: 'the painted pixels must revert too');
    });

    test('redo round-trips the painted stroke and pixels', () {
      final state = _state();
      _paintStroke(state);
      state.undo();
      expect(state.canRedo, isTrue);

      state.redo();

      expect(state.strokes.strokeCount, 1);
      expect(state.texture.isEmpty, isFalse);
      expect(state.canUndo, isTrue);

      // And undo again still works after the redo.
      state.undo();
      expect(state.strokes.strokeCount, 0);
      expect(state.texture.isEmpty, isTrue);
    });

    test('strokes-only ops (move) undo WITHOUT touching texture pixels '
        'and do not consume the paint entry', () {
      final state = _state();
      _paintStroke(state);
      final pixelsAfterPaint = _pixels(state);

      // A selection move records a strokes-only journal entry.
      final id = state.strokes.strokes.first.id;
      state.strokes.selectStroke(id);
      state.strokes.moveSelection(Vector3(0.3, 0.0, 0.0));
      final movedPoint = state.strokes.strokes.first
          .transform.transform3(Vector3.zero());
      expect(movedPoint.x, closeTo(0.3, 1e-9),
          reason: 'applyTranslation moves via the transform matrix');
      expect(_pixels(state), equals(pixelsAfterPaint),
          reason: 'a move must not alter pixels');

      // First undo reverts ONLY the move.
      state.undo();
      final restoredPoint = state.strokes.strokes.first
          .transform.transform3(Vector3.zero());
      expect(restoredPoint.x, closeTo(0.0, 1e-9));
      expect(state.strokes.strokeCount, 1,
          reason: 'the painted stroke must survive the move undo');
      expect(_pixels(state), equals(pixelsAfterPaint));

      // Second undo reverts the paint (pixels AND stroke).
      state.undo();
      expect(state.strokes.strokeCount, 0);
      expect(state.texture.isEmpty, isTrue);
    });

    test('journal caps at maxUndoSteps entries', () {
      final state = _state();
      for (var i = 0; i < EditorState.maxUndoSteps + 12; i++) {
        _paintStroke(state, color: 0xFF000000 | (i + 1) * 0x010101);
      }
      expect(state.strokes.strokeCount, EditorState.maxUndoSteps + 12);

      var undos = 0;
      while (state.canUndo) {
        state.undo();
        undos++;
      }
      expect(undos, EditorState.maxUndoSteps,
          reason: 'the journal must evict the oldest entries');
      // 30 undos of 42 strokes → 12 strokes remain.
      expect(state.strokes.strokeCount, 12);
    });

    test('undoing a project load restores the pre-load pixels too', () {
      final state = _state();
      _paintStroke(state, color: 0xFF00FF00);
      final preLoadPixels = _pixels(state);

      // Build and apply a project document with a different stroke.
      final doc = FeatherProjectDocument(
        fileName: 'Loaded.feather',
        guideSurfaceName: 'Sphere',
        brushPreset: 'Basic Round',
        brushSize: 12.0,
        brushOpacity: 1.0,
        brushColor: 0xFF0000FF,
        strokes: [
          Stroke(
            id: 1,
            brushType: BrushType.basic,
            color: 0xFF0000FF,
            thickness: 12,
            name: 'loaded',
            points: [
              StrokePoint(
                position: Vector3(0.0, 0.0, 1.4),
                pressure: 1.0,
                uv: Vector2(0.5, 0.5),
              ),
            ],
          ),
        ],
      );
      doc.applyTo(state);

      expect(state.strokes.strokeCount, 1);
      expect(state.strokes.strokes.first.name, 'loaded');
      expect(state.texture.isEmpty, isFalse,
          reason: 'the loaded stroke replays into the texture');
      expect(state.canUndo, isTrue);

      state.undo();

      expect(state.strokes.strokes.first.color, 0xFF00FF00,
          reason: 'the pre-load stroke must come back');
      expect(_pixels(state), equals(preLoadPixels),
          reason: 'undoing a load must restore the pre-load pixels');
    });

    test('newDocument is fully undoable (strokes and pixels)', () {
      final state = _state();
      _paintStroke(state);
      final preResetPixels = _pixels(state);

      state.newDocument();
      expect(state.strokes.strokeCount, 0);
      expect(state.texture.isEmpty, isTrue);

      state.undo();

      expect(state.strokes.strokeCount, 1);
      expect(_pixels(state), equals(preResetPixels));
    });

    test('begin without end (discarded stroke) leaves no undo entry', () {
      final state = _state();
      final before = _pixels(state);

      state.beginPaintStroke();
      final dab = syntheticDab(10, 0xFFFF0000);
      state.texture.paintDab(dab, 0.5, 0.5);
      state.discardPaintStroke();

      // The dab pixel changes are visible in the live texture but the
      // journal has nothing to undo (no stroke committed — the canvas
      // only calls this path when no stroke was drawable).
      expect(state.canUndo, isFalse);

      // Undo/redo while a transaction is left open (defensive path)
      // cancels it without corrupting state.
      state.beginPaintStroke();
      state.undo();
      expect(state.canUndo, isFalse);
      expect(_pixels(state), isNot(equals(before)),
          reason: 'undo must not restore from a cancelled pending entry');
    });
  });
}
