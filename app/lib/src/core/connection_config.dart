/// Datos para conectar con el daemon de therd.
class ConnectionConfig {
  const ConnectionConfig({
    required this.host,
    required this.port,
    required this.token,
  });

  static const defaultPort = 24601;

  final String host;
  final int port;
  final String token;

  /// URL del WebSocket. El token va en la query (?token=).
  Uri get webSocketUri => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: '/',
    queryParameters: {'token': token},
  );

  /// Descripción corta sin el token.
  String get label => '$host:$port';

  /// Interpreta `therd://host:puerto?token=...`. Devuelve null si no es válida.
  static ConnectionConfig? tryParse(String raw) {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri == null || uri.scheme != 'therd') return null;
    final host = uri.host;
    final token = uri.queryParameters['token'] ?? '';
    if (host.isEmpty || token.isEmpty) return null;
    final port = uri.hasPort ? uri.port : defaultPort;
    if (port <= 0 || port > 65535) return null;
    return ConnectionConfig(host: host, port: port, token: token);
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectionConfig &&
      other.host == host &&
      other.port == port &&
      other.token == token;

  @override
  int get hashCode => Object.hash(host, port, token);
}
