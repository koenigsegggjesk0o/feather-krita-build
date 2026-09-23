// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// krita_resources.dart — First-run import of the REAL Krita default
// resource library.
//
// The app ships the complete, UNMODIFIED `krita/data` resource tree from
// the real Krita source (v6.0.4) as a single stored-mode ZIP payload
// (`assets/krita-data.zip`, ~80 MB, 727 entries): every default brush
// preset (.kpp), brush tip, preset icon, gradient, pattern, palette,
// workspace, SeExpr script, gamut mask, symbol, color profile, input
// profile, theme and more — byte-identical to what stock Krita installs.
//
// On first run the app extracts that payload 1:1 into the user's
// `feather_resources/` directory — the same first-run import model Krita
// itself uses for its default resource bundles. Nothing is modified:
// file contents and the folder structure are preserved exactly. A
// version marker makes the import idempotent; bumping [importVersion]
// forces a clean re-import on the next launch.
//
// The extraction runs inside a background isolate (the payload is large)
// and streams real progress back to the UI, so the boot screen shows the
// actual import state instead of a fake animation.

import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_dirs.dart';

/// Outcome of one [KritaResources.ensureImported] run.
enum KritaImportStatus {
  /// The payload was extracted during this call.
  imported,

  /// A previous run already imported this payload version.
  alreadyImported,

  /// The payload asset is unavailable (e.g. a stripped build or a test
  /// environment). The editor still works with its bundled presets.
  unavailable,

  /// The extraction started but failed midway. No marker is written, so
  /// the next launch retries the import.
  failed,
}

/// Summary of an import run.
class KritaImportSummary {
  const KritaImportSummary(this.status, this.filesWritten);

  final KritaImportStatus status;
  final int filesWritten;

  bool get ok =>
      status == KritaImportStatus.imported ||
      status == KritaImportStatus.alreadyImported;
}

/// First-run import + lookup of the real Krita default resource library.
class KritaResources {
  /// Asset path of the full krita/data payload (stored-mode ZIP).
  static const String payloadAsset = 'assets/krita-data.zip';

  /// Bump to force a re-extraction of the payload after an app update
  /// that ships a newer resource set.
  static const int importVersion = 1;

  static String _join(String a, String b) {
    final sep = Platform.pathSeparator;
    return a.endsWith(sep) ? '$a$b' : '$a$sep$b';
  }

  /// Root the payload is extracted into (sibling of the legacy
  /// feather_presets folder, both under [appDataRoot]).
  static String rootPath() => _join(appDataRoot().path, 'feather_resources');

  /// The imported `paintoppresets` directory, when present.
  static String? importedPresetsDirPath() {
    final dir = Directory(_join(rootPath(), 'paintoppresets'));
    return dir.existsSync() ? dir.path : null;
  }

  /// Whether the payload for the current [importVersion] is extracted.
  static bool isImported() => _markerFile().existsSync();

  static File _markerFile() =>
      File(_join(rootPath(), '.krita_resources_v$importVersion'));

  /// Extracts the payload on first run. Safe to call on every boot: an
  /// already-imported payload returns immediately.
  ///
  /// [onProgress] receives (filesWritten, totalFiles) while the
  /// background isolate extracts; called on the UI isolate.
  static Future<KritaImportSummary> ensureImported(
      {void Function(int done, int total)? onProgress}) async {
    if (isImported()) {
      return const KritaImportSummary(KritaImportStatus.alreadyImported, 0);
    }
    final root = Directory(rootPath());
    root.createSync(recursive: true);

    // Load the payload asset. In stripped/test builds this throws — the
    // editor falls back to its bundled presets and the next launch of a
    // full build retries the import.
    final ByteData data;
    try {
      data = await rootBundle.load(payloadAsset);
    } catch (_) {
      return const KritaImportSummary(KritaImportStatus.unavailable, 0);
    }

    // Zero-copy hand-off of the payload to the extraction isolate.
    final payload = TransferableTypedData.fromList(
        [data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)]);
    final port = ReceivePort();
    try {
      await Isolate.spawn(
        _extractWorker,
        _WorkerArgs(port.sendPort, payload, root.path),
        errorsAreFatal: true,
      );
    } catch (_) {
      port.close();
      return const KritaImportSummary(KritaImportStatus.failed, 0);
    }

    final completer = Completer<KritaImportSummary>();
    late final StreamSubscription sub;
    sub = port.listen((message) {
      if (message is _Progress) {
        onProgress?.call(message.done, message.total);
        return;
      }
      if (message is _Done) {
        if (message.ok) {
          // Marker LAST: a crash mid-import leaves no marker, so the
          // next launch retries cleanly.
          _markerFile()
              .writeAsStringSync('v$importVersion\n${message.files} files\n');
        }
        completer.complete(KritaImportSummary(
            message.ok ? KritaImportStatus.imported : KritaImportStatus.failed,
            message.files));
        sub.cancel();
        port.close();
      }
    });
    return completer.future;
  }

  // -------------------------------------------------------------------------
  // Extraction isolate.
  // -------------------------------------------------------------------------

  static void _extractWorker(_WorkerArgs args) {
    int written = 0;
    int total = 0;
    try {
      final bytes = args.payload.materialize().asUint8List();
      final archive = ZipDecoder().decodeBytes(bytes);
      total = archive.files.length;
      args.port.send(_Progress(0, total));
      final sep = Platform.pathSeparator;
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final name = file.name;
        // Guard: never extract absolute or traversal paths.
        if (name.startsWith('/') ||
            name.startsWith('\\') ||
            name.split('/').contains('..') ||
            name.split('\\').contains('..')) {
          continue;
        }
        final target =
            File(args.rootPath.endsWith(sep) ? '${args.rootPath}$name' : '${args.rootPath}$sep$name');
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(file.content as List<int>, flush: false);
        written++;
        if (written % 8 == 0) {
          args.port.send(_Progress(written, total));
        }
      }
      args.port.send(_Progress(written, total));
      args.port.send(_Done(true, written));
    } catch (_) {
      args.port.send(_Done(false, written));
    }
  }
}

/// Arguments for the extraction isolate. The payload travels inside a
/// [TransferableTypedData] so the 80 MB ZIP is moved, not copied.
class _WorkerArgs {
  const _WorkerArgs(this.port, this.payload, this.rootPath);

  final SendPort port;
  final TransferableTypedData payload;
  final String rootPath;
}

/// Live progress message from the extraction isolate.
class _Progress {
  const _Progress(this.done, this.total);

  final int done;
  final int total;
}

/// Terminal message from the extraction isolate.
class _Done {
  const _Done(this.ok, this.files);

  final bool ok;
  final int files;
}
