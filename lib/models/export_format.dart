// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// export_format.dart — Export formats supported by Feather-Krita.
//
// Defines the [ExportFormat] enum plus a metadata table for each format
// (file extension, MIME type, whether the format is locked behind the
// freemium "Pro" tier, and a short human-readable description).

import 'dart:io';

/// Supported export formats.
enum ExportFormat {
  /// Portable Network Graphics — lossless raster image with alpha.
  png,

  /// Joint Photographic Experts Group — lossy raster image, no alpha.
  jpeg,

  /// Animated GIF — palette-based animation, 1-bit alpha.
  gif,

  /// H.264 MP4 video — used for animated turntable exports.
  mp4,

  /// Wavefront OBJ — static 3D mesh (vertices, faces, no animation).
  obj,

  /// GL Transmission Format — modern 3D scene format (binary or JSON).
  gltf,

  /// Native Feather-Krita project file (JSON, includes strokes, surfaces,
  /// camera, textures).
  featherProject,
}

/// Static metadata for an [ExportFormat].
class ExportFormatInfo {
  const ExportFormatInfo({
    required this.format,
    required this.label,
    required this.extension,
    required this.mimeType,
    required this.description,
    required this.isProOnly,
    required this.category,
  });

  final ExportFormat format;
  final String label;
  final String extension;
  final String mimeType;
  final String description;
  final bool isProOnly;
  final ExportCategory category;

  /// Returns the suggested file name for [baseName] (without extension).
  String suggestFileName(String baseName) {
    final sanitized = baseName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '$sanitized.$extension';
  }
}

/// Top-level grouping for export formats, used by the UI to organize the
/// export sheet.
enum ExportCategory {
  image,
  animation,
  model,
  project,
}

/// Lookup table for all formats.
const Map<ExportFormat, ExportFormatInfo> kExportFormatInfo = {
  ExportFormat.png: ExportFormatInfo(
    format: ExportFormat.png,
    label: 'PNG Image',
    extension: 'png',
    mimeType: 'image/png',
    description: 'Lossless raster image with full alpha channel. Best for '
        'still artwork and textures.',
    isProOnly: false,
    category: ExportCategory.image,
  ),
  ExportFormat.jpeg: ExportFormatInfo(
    format: ExportFormat.jpeg,
    label: 'JPEG Image',
    extension: 'jpg',
    mimeType: 'image/jpeg',
    description: 'Lossy compressed image, no alpha. Smaller file size than '
        'PNG, suitable for sharing previews.',
    isProOnly: false,
    category: ExportCategory.image,
  ),
  ExportFormat.gif: ExportFormatInfo(
    format: ExportFormat.gif,
    label: 'Animated GIF',
    extension: 'gif',
    mimeType: 'image/gif',
    description: '256-color animated image. Great for short looping '
        'turntable previews.',
    isProOnly: true,
    category: ExportCategory.animation,
  ),
  ExportFormat.mp4: ExportFormatInfo(
    format: ExportFormat.mp4,
    label: 'MP4 Video',
    extension: 'mp4',
    mimeType: 'video/mp4',
    description: 'H.264 video with audio. Used for high-quality animated '
        'turntable or stroke-replay exports.',
    isProOnly: true,
    category: ExportCategory.animation,
  ),
  ExportFormat.obj: ExportFormatInfo(
    format: ExportFormat.obj,
    label: 'OBJ 3D Model',
    extension: 'obj',
    mimeType: 'text/plain',
    description: 'Wavefront OBJ mesh. Compatible with Blender, Maya, '
        'Cinema 4D, and most 3D tools. Static only.',
    isProOnly: false,
    category: ExportCategory.model,
  ),
  ExportFormat.gltf: ExportFormatInfo(
    format: ExportFormat.gltf,
    label: 'glTF 3D Scene',
    extension: 'gltf',
    mimeType: 'model/gltf+json',
    description: 'Modern 3D scene format. Includes strokes as mesh tubes '
        'and supports materials. Embeds textures by default.',
    isProOnly: true,
    category: ExportCategory.model,
  ),
  ExportFormat.featherProject: ExportFormatInfo(
    format: ExportFormat.featherProject,
    label: 'Feather Project',
    extension: 'feather',
    mimeType: 'application/vnd.feather-krita.project+json',
    description: 'Native editable project file. Preserves all strokes, '
        'guide surfaces, textures, and camera state.',
    isProOnly: false,
    category: ExportCategory.project,
  ),
};

/// Returns the [ExportFormatInfo] for [format], falling back to PNG.
ExportFormatInfo exportInfo(ExportFormat format) =>
    kExportFormatInfo[format] ?? kExportFormatInfo[ExportFormat.png]!;

/// Returns true if [format] requires a Pro license.
bool isFormatProOnly(ExportFormat format) => exportInfo(format).isProOnly;

/// Returns all formats available to a user with the given [isPro] flag.
List<ExportFormat> availableFormats({required bool isPro}) {
  return ExportFormat.values
      .where((f) => isPro || !exportInfo(f).isProOnly)
      .toList(growable: false);
}

/// Returns all formats in a given [category].
List<ExportFormat> formatsByCategory(ExportCategory category) {
  return ExportFormat.values
      .where((f) => exportInfo(f).category == category)
      .toList(growable: false);
}

/// Returns the [ExportFormat] whose file extension matches [path], or
/// `null` if no match is found.
ExportFormat? formatFromPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  for (final entry in kExportFormatInfo.entries) {
    if (entry.value.extension == ext) {
      return entry.key;
    }
  }
  return null;
}

/// Returns the default export path for [format] in the given [directory].
String defaultExportPath(String directory, String baseName, ExportFormat format) {
  final info = exportInfo(format);
  final sep = Platform.pathSeparator;
  final cleanDir = directory.endsWith(sep) ? directory : '$directory$sep';
  return '$cleanDir${info.suggestFileName(baseName)}';
}

/// Returns a list of (format, info) pairs sorted by category then label,
/// suitable for displaying in the export sheet.
List<ExportFormatInfo> sortedFormatsForDisplay({required bool isPro}) {
  final list = availableFormats(isPro: isPro)
      .map(exportInfo)
      .toList(growable: false);
  list.sort((a, b) {
    final catCompare = a.category.index.compareTo(b.category.index);
    if (catCompare != 0) return catCompare;
    return a.label.compareTo(b.label);
  });
  return list;
}
