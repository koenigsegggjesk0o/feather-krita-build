// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// guide_surface_parity.dart — Loop-58 guide-surface parity check for the
// open/save dialogs.
//
// A .feather document stores only the guide surface's display NAME; on
// load, FeatherProjectDocument.applyTo rebuilds the surface through
// GuideSurface.forType. Three things can make the restored surface differ
// from what the document's author saw, and none of them were visible in
// the UI before this module:
//
//   1. The stored name is not a known spelling. The tolerant parser
//      (guideSurfaceTypeFromName) silently falls back to Sphere — the
//      document opens with a DIFFERENT surface than it names.
//   2. The stored name maps through an alias or a case variant ("torus",
//      "custom_curve", "SPHERE"). The restored TYPE is right, but the
//      label differs from what was saved.
//   3. The key is absent entirely (hand-trimmed or legacy file). The
//      tolerant parse defaults to Sphere.
//
// [checkGuideSurfaceParity] classifies a stored name into the four
// levels above; [scanGuideSurfaceParity] reads a project file and runs
// the check on its guideSurface field. Both are pure and synchronous so
// the dialogs can render the verdict in the same frame and widget tests
// can assert exact output with no async plumbing.

import 'dart:convert';
import 'dart:io';

import 'package:feather_krita/engine/guide_surface.dart';

/// Upper bound for the file scan. Project documents are stroke JSON
/// (no bitmaps), so real files land far below this; the cap only keeps
/// a pathological file from freezing the dialog on the UI thread.
const int kMaxParityScanBytes = 8 * 1024 * 1024;

/// How faithfully a document's stored guide-surface name survives the
/// load roundtrip.
enum GuideSurfaceParityLevel {
  /// The stored name is the canonical display name of its type —
  /// exactly what this app's writer emits. The same type comes back.
  exact,

  /// The stored name resolves through an alias or case variant ("torus",
  /// "custom_curve", "SPHERE"). The restored type is correct but the
  /// label differs from the stored spelling.
  aliased,

  /// The stored name is not a known spelling; the tolerant parser
  /// silently falls back to Sphere. The restored surface is a DIFFERENT
  /// type than the name suggests.
  fallback,

  /// The document carries no guideSurface field; the tolerant parse
  /// defaults to Sphere.
  missing,
}

/// The parity verdict for one document's guideSurface field.
class GuideSurfaceParityReport {
  const GuideSurfaceParityReport({
    required this.level,
    required this.storedName,
    required this.resolvedType,
  });

  final GuideSurfaceParityLevel level;

  /// The raw stored name, or null when the field was absent.
  final String? storedName;

  /// The surface type the restore path will actually build.
  final GuideSurfaceType resolvedType;

  /// True only when the roundtrip is exactly what the writer emitted.
  bool get isLossless => level == GuideSurfaceParityLevel.exact;

  /// Display name of the type the restore path will build.
  String get surfaceLabel => guideSurfaceTypeName(resolvedType);

  /// One-line human-readable verdict (test-locked; the dialogs render
  /// this verbatim).
  String get detail {
    switch (level) {
      case GuideSurfaceParityLevel.exact:
        return '$surfaceLabel — opens exactly as saved';
      case GuideSurfaceParityLevel.aliased:
        return '"$storedName" opens as $surfaceLabel';
      case GuideSurfaceParityLevel.fallback:
        return '"$storedName" is not a known surface — opens as Sphere';
      case GuideSurfaceParityLevel.missing:
        return 'No guide surface stored — opens as Sphere';
    }
  }
}

/// Classifies [storedName] the way the load path will treat it.
///
/// The contract mirrors FeatherProjectDocument.parse + applyTo exactly:
/// a null name and an unknown name both end up as a default Sphere, a
/// known alias keeps its type, and only the canonical display spelling
/// counts as exact.
GuideSurfaceParityReport checkGuideSurfaceParity(String? storedName) {
  final type = guideSurfaceTypeFromNameStrict(storedName);
  if (type == null) {
    return GuideSurfaceParityReport(
      level: storedName == null
          ? GuideSurfaceParityLevel.missing
          : GuideSurfaceParityLevel.fallback,
      storedName: storedName,
      resolvedType: GuideSurfaceType.sphere,
    );
  }
  final canonical = guideSurfaceTypeName(type);
  final exact = storedName!.trim() == canonical;
  return GuideSurfaceParityReport(
    level: exact
        ? GuideSurfaceParityLevel.exact
        : GuideSurfaceParityLevel.aliased,
    storedName: storedName,
    resolvedType: type,
  );
}

/// Reads the project document at [path] and checks its guideSurface
/// field. Returns null when the file is missing, unreadable, oversized,
/// or not a JSON object — the dialog hides the parity row then, because
/// the load itself will surface the real error.
GuideSurfaceParityReport? scanGuideSurfaceParity(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    if (f.lengthSync() > kMaxParityScanBytes) return null;
    final dynamic decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map<String, dynamic>) return null;
    final raw = decoded['guideSurface'];
    return checkGuideSurfaceParity(raw is String ? raw : null);
  } catch (_) {
    return null;
  }
}
