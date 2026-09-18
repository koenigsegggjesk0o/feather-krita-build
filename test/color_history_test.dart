// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// color_history_test.dart — Loop-27 colour-history coverage.
//
// Pure state-logic tests for the EditorState colour-history API:
//   1. recordColor adds a new colour to the front.
//   2. recordColor dedups + moves an existing colour to the front.
//   3. recordColor caps the history at EditorState.kMaxColorHistory.
//   4. loadColorHistory replaces the list and clamps to the cap.
//   5. removeFromColorHistory removes a colour (no-op if absent).
//   6. clearColorHistory clears (no-op if already empty).
//   7. setBrushColor records the new colour into the history.
//   8. onColorHistoryChanged fires on record/remove/clear but NOT on load.
//   9. colorHistory getter returns an unmodifiable view.
//
// No widget pump (keeps the suite OOM-free on the 4 GB box); the widget
// surface (_ColorHistoryRow, _HistorySwatches) is covered by flutter
// analyze + the existing gui_test harness.

import 'package:flutter_test/flutter_test.dart';

import 'package:feather_krita/state/editor_state.dart';

void main() {
  late EditorState state;

  setUp(() {
    state = EditorState();
  });

  test('recordColor adds a new colour to the front', () {
    expect(state.colorHistory, isEmpty);
    state.recordColor(0xFFFF0000);
    expect(state.colorHistory, [0xFFFF0000]);
    state.recordColor(0xFF00FF00);
    expect(state.colorHistory, [0xFF00FF00, 0xFFFF0000]);
  });

  test('recordColor dedups and moves an existing colour to the front', () {
    state
      ..recordColor(0xFF111111)
      ..recordColor(0xFF222222)
      ..recordColor(0xFF333333);
    // Pre-condition: 333 at front, 111 at back.
    expect(state.colorHistory, [0xFF333333, 0xFF222222, 0xFF111111]);
    // Re-recording 111 moves it to the front, no duplicate.
    state.recordColor(0xFF111111);
    expect(state.colorHistory, [0xFF111111, 0xFF333333, 0xFF222222]);
    expect(state.colorHistory.length, 3);
  });

  test('recordColor caps the history at kMaxColorHistory', () {
    final max = EditorState.kMaxColorHistory;
    for (var i = 1; i <= max + 5; i++) {
      state.recordColor(0xFF000000 + i);
    }
    expect(state.colorHistory.length, max);
    // The most recent (max+5) is at the front; the oldest capped-out
    // colours (1..5) are gone.
    expect(state.colorHistory.first, 0xFF000000 + max + 5);
    expect(state.colorHistory.last, 0xFF000000 + 6);
    expect(state.colorHistory.contains(0xFF000000 + 1), isFalse);
  });

  test('loadColorHistory replaces the list and clamps to the cap', () {
    state.recordColor(0xFFAAAAAA);
    expect(state.colorHistory, [0xFFAAAAAA]);
    final max = EditorState.kMaxColorHistory;
    final big = List<int>.generate(max + 3, (i) => 0xFF000000 + i + 1);
    state.loadColorHistory(big);
    expect(state.colorHistory.length, max);
    // First `max` entries preserved in order; the overflow tail dropped.
    expect(state.colorHistory.first, big.first);
    expect(state.colorHistory.last, big[max - 1]);
    expect(state.colorHistory.contains(big[max]), isFalse);
    // The pre-load entry is gone (replaced, not appended).
    expect(state.colorHistory.contains(0xFFAAAAAA), isFalse);
  });

  test('removeFromColorHistory removes a colour; no-op if absent', () {
    state
      ..recordColor(0xFF111111)
      ..recordColor(0xFF222222)
      ..recordColor(0xFF333333);
    state.removeFromColorHistory(0xFF222222);
    expect(state.colorHistory, [0xFF333333, 0xFF111111]);
    // Removing an absent colour is a silent no-op.
    state.removeFromColorHistory(0xFF999999);
    expect(state.colorHistory, [0xFF333333, 0xFF111111]);
  });

  test('clearColorHistory clears; no-op if already empty', () {
    state
      ..recordColor(0xFF111111)
      ..recordColor(0xFF222222);
    expect(state.colorHistory, isNotEmpty);
    state.clearColorHistory();
    expect(state.colorHistory, isEmpty);
    // Clearing an already-empty history does not throw or notify.
    state.clearColorHistory();
    expect(state.colorHistory, isEmpty);
  });

  test('setBrushColor records the new colour into the history', () {
    final initial = state.brushColor;
    state.setBrushColor(0xFFFF0000);
    expect(state.brushColor, 0xFFFF0000);
    expect(state.colorHistory, [0xFFFF0000]);
    state.setBrushColor(0xFF00FF00);
    expect(state.colorHistory, [0xFF00FF00, 0xFFFF0000]);
    // The original default colour is never auto-recorded (only explicit
    // setBrushColor calls record).
    expect(state.colorHistory.contains(initial), isFalse);
  });

  test('onColorHistoryChanged fires on record/remove/clear but NOT on load', () {
    final fires = <List<int>>[];
    state.onColorHistoryChanged = (colors) => fires.add(colors);
    state.recordColor(0xFF111111);
    state.recordColor(0xFF222222);
    // loadColorHistory restores without firing (not a user mutation).
    final beforeLoad = fires.length;
    state.loadColorHistory([0xFF999999, 0xFF888888]);
    expect(fires.length, beforeLoad);
    state.removeFromColorHistory(0xFF999999);
    state.clearColorHistory();
    // record x2 + remove + clear = 4 fires; load added 0.
    expect(fires.length, 4);
    // Each fired snapshot is unmodifiable-length-correct.
    expect(fires.last, isEmpty);
  });

  test('colorHistory getter returns an unmodifiable view', () {
    state.recordColor(0xFF111111);
    final view = state.colorHistory;
    expect(
      () => view.add(0xFF222222),
      throwsUnsupportedError,
    );
    expect(
      () => view[0] = 0xFF222222,
      throwsUnsupportedError,
    );
  });
}
