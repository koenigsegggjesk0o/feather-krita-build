// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// editor_shortcuts.dart — App-wide keyboard shortcuts for the editor.
//
// Wraps [CallbackShortcuts] around an auto-focusing [Focus] node so the
// bindings are live the moment the editor appears, without requiring the
// user to click the canvas first. The focus node is a *descendant* of
// [CallbackShortcuts] (this is required: Flutter key events bubble from
// the focused node UP to ancestor `Shortcuts` resolvers, never down).
// When a child widget such as the canvas or a button grabs focus later,
// it is still a descendant of this resolver, so the bindings keep firing;
// when a modal dialog opens it lives in its own focus scope and the
// editor bindings pause until it closes.
//
// The bindings map is supplied by the host screen ([MainScreen]); this
// widget holds no domain logic, which keeps the *wiring* trivial to test
// and the *actions* testable through the real [EditorState].
//
// Modifier policy: every Ctrl-shortcut is registered twice — once with
// `control: true` (Windows/Linux) and once with `meta: true` (macOS and
// Android physical keyboards that send Cmd). Plain-letter shortcuts
// (B/E/V/L/G/[ /]/Delete/Escape) are registered without modifiers; when a
// text field has focus those keys are consumed by the field and never
// reach this node, so typing in the Save-As filename box is unaffected.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A [CallbackShortcuts] wrapper that auto-focuses a descendant node so the
/// editor bindings are active immediately on mount.
class EditorShortcuts extends StatelessWidget {
  const EditorShortcuts({
    super.key,
    required this.bindings,
    required this.child,
    this.autofocus = true,
  });

  /// The shortcut → callback map (built by the host screen).
  final Map<ShortcutActivator, VoidCallback> bindings;

  /// The widget tree below the shortcut resolver.
  final Widget child;

  /// Whether to grab focus as soon as the widget mounts. Defaults to true
  /// so the editor is keyboard-driven on first paint.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(autofocus: autofocus, child: child),
    );
  }
}

/// Builds a cross-platform [ShortcutActivator] for a Ctrl/Cmd + key combo.
/// Use the [ctrlKey]/[metaKey] pair in every bindings map so the same
/// logical shortcut works on Windows/Linux (control) and macOS (meta).
ShortcutActivator ctrlKey(LogicalKeyboardKey key, {bool shift = false}) {
  return SingleActivator(key, control: true, shift: shift);
}

/// The macOS/Cmd twin of [ctrlKey].
ShortcutActivator metaKey(LogicalKeyboardKey key, {bool shift = false}) {
  return SingleActivator(key, meta: true, shift: shift);
}
