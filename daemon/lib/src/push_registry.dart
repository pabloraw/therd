import 'dart:convert';
import 'dart:io';

import 'config.dart' show writePrivateFile;
import 'log.dart';

/// Endpoints de UnifiedPush de los móviles emparejados, guardados en
/// `push.json` junto a config.json para que sobrevivan a un reinicio.
class PushRegistry {
  PushRegistry({this.file, this.max = 5}) {
    _load();
  }

  /// null = solo en memoria (tests).
  final String? file;

  /// Tope de endpoints: uno por móvil, con margen para reinstalaciones.
  final int max;

  final List<String> _endpoints = [];

  List<String> get endpoints => List.unmodifiable(_endpoints);

  /// Solo URLs http(s) absolutas; ntfy las da del estilo `http://h:p/upXXX?up=1`.
  static bool isValid(String endpoint) {
    final u = Uri.tryParse(endpoint);
    return u != null &&
        u.hasAuthority &&
        (u.scheme == 'http' || u.scheme == 'https');
  }

  /// Añade [endpoint] (el más reciente al final) y olvida [previous].
  /// False si la URL no vale.
  bool register(String endpoint, {String? previous}) {
    if (!isValid(endpoint)) return false;
    final before = List.of(_endpoints);
    _endpoints.removeWhere((e) => e == endpoint || e == previous);
    _endpoints.add(endpoint);
    while (_endpoints.length > max) {
      _endpoints.removeAt(0);
    }
    if (!_same(before)) {
      Log.info('push: endpoint registrado (${_endpoints.length} en total)');
      _save();
    }
    return true;
  }

  void unregister(String endpoint) {
    if (_endpoints.remove(endpoint)) {
      Log.info('push: endpoint retirado (${_endpoints.length} en total)');
      _save();
    }
  }

  bool _same(List<String> other) =>
      other.length == _endpoints.length &&
      [
        for (var i = 0; i < other.length; i++) other[i] == _endpoints[i],
      ].every((x) => x);

  void _load() {
    final f = file;
    if (f == null) return;
    try {
      final j = jsonDecode(File(f).readAsStringSync());
      final list = j is Map ? j['endpoints'] : null;
      if (list is List) {
        _endpoints.addAll(list.whereType<String>().where(isValid).take(max));
      }
    } on PathNotFoundException {
      // Sin registros todavía.
    } catch (e) {
      Log.warn('push.json ilegible, se ignora: $e');
    }
  }

  void _save() {
    final f = file;
    if (f == null) return;
    try {
      writePrivateFile(
        File(f),
        '${const JsonEncoder.withIndent('  ').convert({'endpoints': _endpoints})}\n',
      );
    } catch (e) {
      Log.warn('No se pudo guardar push.json: $e');
    }
  }
}
