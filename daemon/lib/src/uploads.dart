import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:therd_protocol/protocol.dart';

/// Imágenes que llegan desde la app. Se guardan en disco y el prompt lleva
/// sus rutas, que Claude Code lee con Read.
class Uploads {
  Uploads(
    this.dir, {
    this.maxBytes = 15 << 20,
    this.keep = const Duration(days: 7),
  });

  final String dir;

  /// Tamaño máximo de cada imagen ya decodificada.
  final int maxBytes;

  /// Las más viejas se borran al arrancar.
  final Duration keep;

  /// Imágenes máximas por mensaje (la app adjunta hasta 4).
  static const maxImages = 4;

  /// Nombre de los archivos que genera [save]: `AAAAMMDD-HHMMSS-<8 hex>.<ext>`.
  static final _nameRe = RegExp(
    r'^\d{8}-\d{6}-[0-9a-f]{8}\.(?:png|jpg|webp|gif)$',
  );

  static const _ext = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/webp': 'webp',
    'image/gif': 'gif',
  };

  final _rnd = Random();

  /// Guarda las imágenes y devuelve sus rutas absolutas. Lanza
  /// [UploadException] si alguna no vale; en ese caso no deja nada escrito.
  Future<List<String>> save(List<PromptImage> images) async {
    if (images.length > maxImages) {
      throw const UploadException(
        'Demasiadas imágenes (máximo $maxImages por mensaje).',
      );
    }
    final decoded = <(String, List<int>)>[];
    for (final img in images) {
      final ext = _ext[img.mime];
      if (ext == null) {
        throw UploadException('Formato de imagen no admitido (${img.mime}).');
      }
      // Antes de decodificar: base64 ocupa 4/3 del original (más relleno).
      if (img.data.length > maxBytes * 4 ~/ 3 + 8) {
        throw UploadException(
          'La imagen pesa demasiado (máximo ${maxBytes >> 20} MB).',
        );
      }
      final List<int> bytes;
      try {
        bytes = base64.decode(img.data);
      } on FormatException {
        throw const UploadException('La imagen llegó dañada.');
      }
      if (bytes.isEmpty) throw const UploadException('La imagen está vacía.');
      if (bytes.length > maxBytes) {
        throw UploadException(
          'La imagen pesa demasiado (máximo ${maxBytes >> 20} MB).',
        );
      }
      decoded.add((ext, bytes));
    }
    await Directory(dir).create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp('[-:]'), '')
        .replaceFirst('T', '-');
    final out = <String>[];
    for (final (ext, bytes) in decoded) {
      final id = _rnd.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
      final path = p.join(dir, '$stamp-$id.$ext');
      await File(path).writeAsBytes(bytes, flush: true);
      out.add(path);
    }
    return out;
  }

  /// Borra las imágenes de más de [keep]. Los fallos se ignoran.
  Future<void> prune({DateTime? now}) async {
    final d = Directory(dir);
    if (!await d.exists()) return;
    final limit = (now ?? DateTime.now()).subtract(keep);
    await for (final f in d.list()) {
      if (f is! File || !_nameRe.hasMatch(p.basename(f.path))) continue;
      try {
        if ((await f.stat()).modified.isBefore(limit)) await f.delete();
      } on FileSystemException {
        // Otro proceso la borró o no hay permiso: da igual.
      }
    }
  }
}

class UploadException implements Exception {
  const UploadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Texto del prompt con las rutas de las imágenes, una por línea al final.
/// Claude Code reconoce cada ruta y la adjunta como imagen (`[Image #N]`).
String promptWithImages(String text, List<String> paths) {
  final t = text.trim();
  if (paths.isEmpty) return t;
  final list = paths.join('\n');
  return t.isEmpty ? list : '$t\n\n$list';
}

final _uploadPathRe = RegExp(
  r'/\S*/therd/uploads/[\w.-]+\.(?:png|jpg|webp|gif)',
);
final _uploadHeaderRe = RegExp(r'^(?:Imagen adjunta|Imágenes adjuntas):$');
final _imageMarkRe = RegExp(r'\[Image #\d+\]');

/// Texto de un prompt tal como se pinta: sin las marcas `[Image #N]` de
/// Claude Code ni las rutas de imágenes subidas desde la app (la imagen va
/// aparte, en `images`). Quita también la cabecera de las primeras versiones.
String cleanPromptText(String text) {
  var t = text.replaceAll(_imageMarkRe, '');
  if (!_uploadPathRe.hasMatch(t) && !t.contains(':')) return t.trim();
  final lines = [
    for (final l in t.split('\n'))
      if (!_uploadHeaderRe.hasMatch(l.trim())) l.replaceAll(_uploadPathRe, ''),
  ];
  t = lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}
