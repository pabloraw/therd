import 'package:flutter/foundation.dart';

/// Datos para conectar con el daemon de therd.
class ConnectionConfig {
  const ConnectionConfig({
    required this.host,
    required this.port,
    required this.token,
    this.lanHosts = const [],
  });

  static const defaultPort = 24601;

  /// Dirección principal (la de Tailscale).
  final String host;
  final int port;
  final String token;

  /// IPs de la red local del daemon. Se prueban antes que [host]: en casa
  /// se puede apagar Tailscale y la app sigue entrando.
  final List<String> lanHosts;

  /// Direcciones en el orden en que se prueban: red local primero.
  List<String> get hosts => [...lanHosts.where((h) => h != host), host];

  bool isLan(String h) => h != host && lanHosts.contains(h);

  /// URL del WebSocket. El token va en la query (?token=).
  Uri get webSocketUri => webSocketUriFor(host);

  Uri webSocketUriFor(String h) => Uri(
    scheme: 'ws',
    host: h,
    port: port,
    path: '/',
    queryParameters: {'token': token},
  );

  /// Descripción corta sin el token.
  String get label => '$host:$port';

  String labelFor(String h) => '$h:$port';

  ConnectionConfig withLanHosts(List<String> lan) =>
      ConnectionConfig(host: host, port: port, token: token, lanHosts: lan);

  /// Interpreta `therd://host:puerto?token=...&lan=ip1,ip2`. Devuelve null
  /// si no es válida.
  static ConnectionConfig? tryParse(String raw) {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri == null || uri.scheme != 'therd') return null;
    final host = uri.host;
    final token = uri.queryParameters['token'] ?? '';
    if (host.isEmpty || token.isEmpty) return null;
    final port = uri.hasPort ? uri.port : defaultPort;
    if (port <= 0 || port > 65535) return null;
    final lan = [
      for (final h in (uri.queryParameters['lan'] ?? '').split(','))
        if (h.trim().isNotEmpty) h.trim(),
    ];
    return ConnectionConfig(
      host: host,
      port: port,
      token: token,
      lanHosts: lan,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectionConfig &&
      other.host == host &&
      other.port == port &&
      other.token == token &&
      listEquals(other.lanHosts, lanHosts);

  @override
  int get hashCode => Object.hash(host, port, token, Object.hashAll(lanHosts));
}
