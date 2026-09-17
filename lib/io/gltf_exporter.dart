// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// gltf_exporter.dart — Minimal glTF 2.0 (.gltf) exporter for guide surfaces.
//
// Produces a self-contained single-file glTF: all buffer data (positions,
// normals, UVs, triangle indices) is embedded as a base64 data URI, so the
// exported model opens directly in Blender / three.js viewers / Windows
// 3D Viewer without sidecar .bin files.
//
// Only a single static mesh with one primitive is emitted — the same mesh
// the OBJ exporter writes, in the surface's local (already world) space.

import 'dart:convert';
import 'dart:typed_data';

import 'package:feather_krita/engine/guide_surface.dart';

/// Builds a self-contained glTF 2.0 JSON document for [mesh].
///
/// The buffer layout is:
///   view 0 — positions   (VEC3 float32, accessor 0)
///   view 1 — normals     (VEC3 float32, accessor 1)
///   view 2 — texcoords   (VEC2 float32, accessor 2)
///   view 3 — indices     (SCALAR uint32,  accessor 3)
/// Each view is padded to 4-byte alignment as required by the spec.
String buildGltf(SurfaceMesh mesh, {String name = 'FeatherSurface'}) {
  final positions = Float32List(mesh.positions.length * 3);
  var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  var maxX = double.negativeInfinity,
      maxY = double.negativeInfinity,
      maxZ = double.negativeInfinity;
  for (var i = 0; i < mesh.positions.length; i++) {
    final p = mesh.positions[i];
    positions[i * 3] = p.x;
    positions[i * 3 + 1] = p.y;
    positions[i * 3 + 2] = p.z;
    if (p.x < minX) minX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.z < minZ) minZ = p.z;
    if (p.x > maxX) maxX = p.x;
    if (p.y > maxY) maxY = p.y;
    if (p.z > maxZ) maxZ = p.z;
  }

  final normals = Float32List(mesh.normals.length * 3);
  for (var i = 0; i < mesh.normals.length; i++) {
    final n = mesh.normals[i];
    normals[i * 3] = n.x;
    normals[i * 3 + 1] = n.y;
    normals[i * 3 + 2] = n.z;
  }

  final uvs = Float32List(mesh.uvs.length * 2);
  for (var i = 0; i < mesh.uvs.length; i++) {
    uvs[i * 2] = mesh.uvs[i].x;
    uvs[i * 2 + 1] = mesh.uvs[i].y;
  }

  final indexCount = mesh.indices.length;
  final indices = Uint32List(indexCount);
  for (var i = 0; i < indexCount; i++) {
    indices[i] = mesh.indices[i];
  }

  // Assemble the binary buffer with 4-byte alignment between views.
  final chunks = <Uint8List>[
    positions.buffer.asUint8List(),
    normals.buffer.asUint8List(),
    uvs.buffer.asUint8List(),
    indices.buffer.asUint8List(),
  ];
  final views = <Map<String, dynamic>>[];
  final payload = BytesBuilder();
  var offset = 0;
  for (final chunk in chunks) {
    final aligned = (offset + 3) & ~3;
    while (offset < aligned) {
      payload.addByte(0);
      offset++;
    }
    payload.add(chunk);
    views.add({
      'buffer': 0,
      'byteOffset': aligned,
      'byteLength': chunk.length,
    });
    offset += chunk.length;
  }
  final totalLength = (offset + 3) & ~3;
  while (offset < totalLength) {
    payload.addByte(0);
    offset++;
  }
  final base64 = base64Encode(payload.toBytes());

  final gltf = <String, dynamic>{
    'asset': {
      'version': '2.0',
      'generator': 'Feather-Krita glTF exporter',
    },
    'scene': 0,
    'scenes': [
      {'nodes': [0]},
    ],
    'nodes': [
      {'name': name, 'mesh': 0},
    ],
    'meshes': [
      {
        'name': name,
        'primitives': [
          {
            'attributes': {
              'POSITION': 0,
              'NORMAL': 1,
              'TEXCOORD_0': 2,
            },
            'indices': 3,
            'mode': 4, // TRIANGLES
          },
        ],
      },
    ],
    'buffers': [
      {
        'byteLength': totalLength,
        'uri': 'data:application/octet-stream;base64,$base64',
      },
    ],
    'bufferViews': views,
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126, // FLOAT
        'count': mesh.positions.length,
        'type': 'VEC3',
        'min': [minX, minY, minZ],
        'max': [maxX, maxY, maxZ],
      },
      {
        'bufferView': 1,
        'componentType': 5126,
        'count': mesh.normals.length,
        'type': 'VEC3',
      },
      {
        'bufferView': 2,
        'componentType': 5126,
        'count': mesh.uvs.length,
        'type': 'VEC2',
      },
      {
        'bufferView': 3,
        'componentType': 5125, // UNSIGNED_INT
        'count': indexCount,
        'type': 'SCALAR',
      },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(gltf);
}
