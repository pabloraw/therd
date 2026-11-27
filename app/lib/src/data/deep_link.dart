import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Extrae el sessionId de un enlace `therd://session/<id>`. Devuelve null si
/// el esquema o el host son ajenos o si falta el id.
String? parseSessionLink(Uri uri) {
  if (uri.scheme != 'therd' || uri.host != 'session') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 1) return null;
  return segments.first;
}

/// Daemon del enlace (`?pc=<daemonId>`), o null si no lo dice.
String? parseLinkDaemon(Uri uri) {
  final pc = uri.queryParameters['pc'];
  return pc == null || pc.isEmpty ? null : pc;
}

/// `therd://session/<id>`, con `?pc=<daemonId>` si se sabe el ordenador.
Uri sessionLink(String sessionId, {String? daemonId}) => Uri(
  scheme: 'therd',
  host: 'session',
  path: '/$sessionId',
  queryParameters: daemonId == null ? null : {'pc': daemonId},
);

/// Origen de enlaces entrantes (arranque en frío y app ya abierta). Es una
/// interfaz para poder sustituirlo en los tests.
abstract class DeepLinkSource {
  Stream<Uri> get links;
}

/// Implementación real con `app_links`: su stream incluye el enlace inicial.
class AppLinksSource implements DeepLinkSource {
  @override
  Stream<Uri> get links => AppLinks().uriLinkStream;
}

final deepLinkSourceProvider = Provider<DeepLinkSource>(
  (ref) => AppLinksSource(),
);
