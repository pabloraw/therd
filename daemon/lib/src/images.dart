import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Imágenes vistas en los transcripts (adjuntos del usuario, capturas y Read
/// de imágenes). Se guardan en disco por su hash y la app las pide por HTTP;
/// así los items solo llevan el id.
class ImageStore {
  ImageStore(
    this.dir, {
    this.keep = const Duration(days: 30),
    this.thumbSide = 1024,
    this.thumbQuality = 75,
  });

  final String dir;

  /// Lado largo y calidad JPEG de lo que se pinta en el chat.
  final int thumbSide;
  final int thumbQuality;

  /// Miniaturas en curso, para no calcular dos veces la misma.
  final Map<String, Future<File?>> _thumbs = {};

  /// Originales que ya son ligeros: se sirven tal cual sin volver a mirarlos.
  final Set<String> _light = {};

  /// Al arrancar se borran las que llevan más tiempo sin tocarse. Si vuelven
  /// a hacer falta, releer el transcript las escribe de nuevo.
  final Duration keep;

  static const _ext = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/webp': 'webp',
    'image/gif': 'gif',
  };
  static const _mime = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };
  static final _idRe = RegExp(r'^[0-9a-f]{24}\.(png|jpg|webp|gif)$');

  /// Lo que genera este almacén: originales, miniaturas y temporales. Prune
  /// no toca nada más por si la carpeta se comparte con archivos ajenos.
  static final _ownedRe = RegExp(
    r'^[0-9a-f]{24}\.(png|jpg|webp|gif|t\d+\.jpeg)(\.tmp)?$',
  );

  bool _dirReady = false;

  /// Id de un bloque `image` del transcript (`source` en base64), guardándola
  /// si aún no está. null si el bloque no es una imagen válida.
  String? putBlock(Object? block) {
    if (block is! Map || block['type'] != 'image') return null;
    final src = block['source'];
    if (src is! Map || src['type'] != 'base64') return null;
    final mime = src['media_type'];
    final data = src['data'];
    if (mime is! String || data is! String || data.isEmpty) return null;
    return put(mime, data);
  }

  /// Guarda una imagen en base64 y devuelve su id (`<hash>.<ext>`).
  String? put(String mime, String data) {
    final ext = _ext[mime];
    if (ext == null) return null;
    final hash = sha1.convert(utf8.encode(data)).toString().substring(0, 24);
    final id = '$hash.$ext';
    final f = File(p.join(dir, id));
    try {
      if (f.existsSync()) return id;
      if (!_dirReady) {
        Directory(dir).createSync(recursive: true);
        _dirReady = true;
      }
      final tmp = File('${f.path}.tmp');
      tmp.writeAsBytesSync(base64.decode(data), flush: true);
      tmp.renameSync(f.path);
      return id;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Archivo de [id], o null si el id no es válido o no existe.
  File? file(String id) {
    if (!_idRe.hasMatch(id)) return null;
    final f = File(p.join(dir, id));
    return f.existsSync() ? f : null;
  }

  static String mimeOf(String id) => _mime[id.split('.').last]!;

  /// Versión ligera de [id] para el chat: JPEG de [thumbSide] px como mucho,
  /// guardada junto al original. Si el original ya es ligero, el original.
  Future<File?> thumb(String id) {
    final orig = file(id);
    if (orig == null) return Future.value();
    final out = File(p.join(dir, '${id.split('.').first}.t$thumbSide.jpeg'));
    if (_light.contains(id)) return Future.value(orig);
    if (out.existsSync()) return Future.value(out);
    // El callback no devuelve nada: si devolviera el future quitado del mapa,
    // whenComplete se esperaría a sí mismo.
    return _thumbs[id] ??= _makeThumb(orig, out).whenComplete(() {
      _thumbs.remove(id);
    });
  }

  Future<File?> _makeThumb(File orig, File out) async {
    final side = thumbSide;
    final quality = thumbQuality;
    final src = orig.path;
    final dst = out.path;
    // Decodificar y comprimir es pesado: fuera del isolate principal.
    // La tarea va como objeto con solo cadenas y enteros: un closure de este
    // método arrastraría el store entero y no se puede enviar.
    final usedOriginal = await Isolate.run(
      _ThumbJob(src, dst, side, quality).call,
    ).catchError((Object _) => true);
    if (usedOriginal) _light.add(p.basename(orig.path));
    return usedOriginal ? orig : out;
  }

  Future<void> prune({DateTime? now}) async {
    final d = Directory(dir);
    if (!await d.exists()) return;
    final limit = (now ?? DateTime.now()).subtract(keep);
    await for (final f in d.list()) {
      if (f is! File || !_ownedRe.hasMatch(p.basename(f.path))) continue;
      try {
        if ((await f.stat()).modified.isBefore(limit)) await f.delete();
      } on FileSystemException {
        // Da igual.
      }
    }
  }
}

/// Escribe la miniatura de [src] en [dst]; true si conviene servir el
/// original (ya es ligero o no se pudo decodificar).
class _ThumbJob {
  const _ThumbJob(this.src, this.dst, this.side, this.quality);
  final String src;
  final String dst;
  final int side;
  final int quality;

  bool call() => _thumbJob(src, dst, side, quality);
}

bool _thumbJob(String src, String dst, int side, int quality) {
  final bytes = File(src).readAsBytesSync();
  final im = img.decodeImage(bytes);
  if (im == null) return true;
  final small = im.width <= side && im.height <= side;
  if (small && bytes.length <= 300 * 1024) return true;
  final resized = small
      ? im
      : img.copyResize(
          im,
          width: im.width >= im.height ? side : null,
          height: im.width >= im.height ? null : side,
          interpolation: img.Interpolation.average,
        );
  final jpg = img.encodeJpg(resized, quality: quality);
  if (jpg.length >= bytes.length) return true;
  final tmp = File('$dst.tmp')..writeAsBytesSync(jpg, flush: true);
  tmp.renameSync(dst);
  return false;
}
