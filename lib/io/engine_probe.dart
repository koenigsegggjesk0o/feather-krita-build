// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// engine_probe.dart — Hang-proof pre-flight check for the native Krita
// bridge.
//
// [EditorState] constructs the [KritaBrushEngine] synchronously on the UI
// isolate. If `DynamicLibrary.open` blocks on the user's machine (a DLL
// whose load path deadlocks — the class of bug that froze the old build
// at a fake "100%" screen), the whole app freezes with no way out.
//
// This probe opens the same candidate libraries inside a THROWAWAY
// isolate with a hard timeout:
//   - probe finishes true  → the library loads cleanly; the editor may
//     construct the real engine on the UI isolate.
//   - probe finishes false → the library is absent; the editor runs on
//     the honest synthetic-dab fallback (no behavior change vs. today).
//   - probe TIMES OUT      → the library load is wedged on this machine;
//     the editor skips the native engine for this session (the app stays
//     usable; next launch retries).
//
// The candidate lists mirror `krita_bindings.dart` exactly — the probe
// must accept exactly what the real loader would accept.

import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io' show OSError, Platform;
import 'dart:isolate';

/// Probes whether the native Krita bridge loads cleanly on this machine.
///
/// Android and iOS bundle the library inside the package and the OS
/// loader resolves it without the filesystem candidates, so the probe
/// short-circuits to `true` there (a missing bundled library still fails
/// fast inside [EditorState]'s own try/catch — the hang class this probe
/// guards against does not apply to bundled libraries).
Future<bool> probeKritaEngine(
    {Duration timeout = const Duration(seconds: 12)}) async {
  if (Platform.isAndroid || Platform.isIOS) return true;
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    return false;
  }
  try {
    return await Isolate.run(_tryOpen).timeout(timeout);
  } on TimeoutException {
    return false;
  } catch (_) {
    return false;
  }
}

bool _tryOpen() {
  for (final candidate in _candidates()) {
    try {
      DynamicLibrary.open(candidate);
      return true;
    } on ArgumentError {
      continue;
    } on OSError {
      continue;
    }
  }
  return false;
}

List<String> _candidates() {
  if (Platform.isWindows) {
    return const <String>[
      'krita_bridge.dll',
      'lib\\krita_bridge.dll',
      '.\\krita_bridge.dll',
    ];
  }
  if (Platform.isLinux) {
    return const <String>[
      'lib/libkrita_bridge.so',
      'libkrita_bridge.so',
      './libkrita_bridge.so',
      'assets/native/linux/libkrita_bridge.so',
      'assets/native/libkrita_bridge.so',
      '../assets/native/linux/libkrita_bridge.so',
    ];
  }
  if (Platform.isMacOS) {
    return const <String>['libkrita_bridge.dylib'];
  }
  return const <String>[];
}
