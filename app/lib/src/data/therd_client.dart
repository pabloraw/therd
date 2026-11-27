import 'dart:async';

import 'package:therd_protocol/protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/connection_config.dart';

enum LinkState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  unauthorized,
}

/// Estado del enlace con el daemon.
class LinkStatus {
  const LinkStatus(
    this.state, {
    this.attempt = 0,
    this.error,
    this.lan = false,
  });

  final LinkState state;

  /// Conectado por la red local en vez de por Tailscale.
  final bool lan;

  /// Número de intento de reconexión en curso (0 si no aplica).
  final int attempt;
  final String? error;

  bool get isConnected => state == LinkState.connected;

  /// Texto corto para la interfaz.
  String get label => switch (state) {
    LinkState.connected => lan ? 'Conectado (red local)' : 'Conectado',
    LinkState.connecting => 'Conectando',
    LinkState.reconnecting => 'Reconectando (intento $attempt)',
    LinkState.unauthorized => 'Token rechazado',
    LinkState.disconnected => 'Sin conexión',
  };

  @override
  bool operator ==(Object other) =>
      other is LinkStatus &&
      other.state == state &&
      other.attempt == attempt &&
      other.error == error &&
      other.lan == lan;

  @override
  int get hashCode => Object.hash(state, attempt, error, lan);
}

/// Cliente del protocolo WebSocket del daemon (interfaz para poder falsearlo).
abstract class TherdClient {
  /// Mensajes del servidor ya decodificados.
  Stream<ServerMessage> get messages;

  /// Cambios de estado del enlace.
  Stream<LinkStatus> get link;

  LinkStatus get current;

  /// Conecta (o reconecta con backoff) con [config]. Sustituye a la anterior.
  void connect(ConnectionConfig config);

  /// Cambia la configuración sin cortar la conexión (se usa al reconectar).
  void updateConfig(ConnectionConfig config);

  /// Cierra y deja de reconectar.
  void disconnect();

  void send(ClientMessage message);

  /// Prueba una conexión suelta; null si va bien, o el motivo del fallo.
  Future<String?> probe(ConnectionConfig config);

  void dispose();
}

/// Implementación con web_socket_channel, reconexión con backoff y ping.
class WebSocketTherdClient implements TherdClient {
  static const backoff = [1, 2, 4, 8, 15, 30];
  static const _helloTimeout = Duration(seconds: 10);
  static const _pingEvery = Duration(seconds: 20);
  static const _deadAfter = Duration(seconds: 60);

  /// Lo que se espera a una IP de la red local antes de pasar a la
  /// siguiente: en casa responde al momento; fuera no responde nunca.
  static const lanTimeout = Duration(milliseconds: 2500);

  final _messages = StreamController<ServerMessage>.broadcast();
  final _link = StreamController<LinkStatus>.broadcast();
  LinkStatus _current = const LinkStatus(LinkState.disconnected);

  ConnectionConfig? _config;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  Timer? _helloTimer;
  Timer? _pingTimer;
  DateTime _lastRx = DateTime.now();
  int _attempt = 0;

  /// Dirección de `_config.hosts` que se está probando en esta ronda.
  int _hostIdx = 0;
  int _gen = 0;
  bool _wanted = false;

  @override
  Stream<ServerMessage> get messages => _messages.stream;

  @override
  Stream<LinkStatus> get link => _link.stream;

  @override
  LinkStatus get current => _current;

  void _setStatus(LinkStatus s) {
    if (s == _current) return;
    _current = s;
    if (!_link.isClosed) _link.add(s);
  }

  @override
  void connect(ConnectionConfig config) {
    _config = config;
    _wanted = true;
    _attempt = 0;
    _hostIdx = 0;
    _retryTimer?.cancel();
    _open();
  }

  @override
  void updateConfig(ConnectionConfig config) {
    final host = _hostIdx < (_config?.hosts.length ?? 0)
        ? _config!.hosts[_hostIdx]
        : null;
    _config = config;
    // El índice sigue apuntando a la dirección en uso.
    final i = host == null ? -1 : config.hosts.indexOf(host);
    _hostIdx = i < 0 ? 0 : i;
  }

  bool get _lastHost => _hostIdx >= (_config?.hosts.length ?? 1) - 1;

  @override
  void disconnect() {
    _wanted = false;
    _retryTimer?.cancel();
    _teardown();
    _setStatus(const LinkStatus(LinkState.disconnected));
  }

  void _teardown() {
    _gen++;
    _helloTimer?.cancel();
    _pingTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _open() {
    final config = _config;
    if (config == null || !_wanted) return;
    _teardown();
    final gen = _gen;
    _setStatus(
      _attempt == 0
          ? const LinkStatus(LinkState.connecting)
          : LinkStatus(LinkState.reconnecting, attempt: _attempt),
    );
    final hosts = config.hosts;
    if (_hostIdx >= hosts.length) _hostIdx = 0;
    final host = hosts[_hostIdx];
    final WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(config.webSocketUriFor(host));
    } catch (e) {
      _fail(gen, e);
      return;
    }
    _channel = ch;
    ch.ready.then((_) {}, onError: (Object e) => _fail(gen, e));
    _sub = ch.stream.listen(
      (data) => _onData(gen, data),
      onError: (Object e) => _fail(gen, e),
      onDone: () => _fail(gen, null),
    );
    _helloTimer = Timer(
      _lastHost ? _helloTimeout : lanTimeout,
      () => _fail(gen, 'sin respuesta'),
    );
  }

  void _onData(int gen, Object? data) {
    if (gen != _gen || data is! String) return;
    _lastRx = DateTime.now();
    final msg = decodeMessage(data);
    if (msg is HelloMessage) {
      _helloTimer?.cancel();
      _attempt = 0;
      final c = _config;
      final lan = c != null && !_lastHost && c.isLan(c.hosts[_hostIdx]);
      _setStatus(LinkStatus(LinkState.connected, lan: lan));
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(_pingEvery, (_) => _ping(gen));
    }
    if (msg is ErrorMessage && msg.code == ErrorCode.unauthorized) {
      _wanted = false;
      _teardown();
      _setStatus(LinkStatus(LinkState.unauthorized, error: msg.message));
    }
    if (msg is ServerMessage && !_messages.isClosed) _messages.add(msg);
  }

  void _ping(int gen) {
    if (gen != _gen) return;
    if (DateTime.now().difference(_lastRx) > _deadAfter) {
      _fail(gen, 'sin latidos');
      return;
    }
    send(const PingMessage());
  }

  void _fail(int gen, Object? error) {
    if (gen != _gen || !_wanted) return;
    final text = error == null ? null : describeError(error, _config);
    if (text != null && text.startsWith('Token')) {
      _wanted = false;
      _teardown();
      _setStatus(LinkStatus(LinkState.unauthorized, error: text));
      return;
    }
    _teardown();
    // Quedan direcciones en esta ronda (la red local no respondió o se
    // perdió): se pasa a la siguiente sin esperar.
    if (!_lastHost) {
      _hostIdx++;
      _retryTimer?.cancel();
      _open();
      return;
    }
    _hostIdx = 0;
    _attempt++;
    _setStatus(
      LinkStatus(LinkState.reconnecting, attempt: _attempt, error: text),
    );
    final secs = backoff[(_attempt - 1).clamp(0, backoff.length - 1)];
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: secs), _open);
  }

  @override
  void send(ClientMessage message) {
    if (!_current.isConnected) return;
    try {
      _channel?.sink.add(message.encode());
    } catch (_) {
      // Si falla el envío, el listener detecta el cierre y reconecta.
    }
  }

  @override
  Future<String?> probe(ConnectionConfig config) async {
    final hosts = config.hosts;
    for (final h in hosts.take(hosts.length - 1)) {
      if (await _probeHost(config, h, lanTimeout) == null) return null;
    }
    return _probeHost(config, hosts.last, const Duration(seconds: 6));
  }

  Future<String?> _probeHost(
    ConnectionConfig config,
    String host,
    Duration timeout,
  ) async {
    WebSocketChannel? ch;
    try {
      ch = WebSocketChannel.connect(config.webSocketUriFor(host));
      await ch.ready.timeout(timeout);
      final first = await ch.stream.first.timeout(timeout);
      final msg = first is String ? decodeMessage(first) : null;
      if (msg is HelloMessage) return null;
      if (msg is ErrorMessage) return msg.message;
      return 'Respuesta inesperada del servidor';
    } catch (e) {
      return describeError(e, config);
    } finally {
      ch?.sink.close();
    }
  }

  @override
  void dispose() {
    _wanted = false;
    _retryTimer?.cancel();
    _teardown();
    _messages.close();
    _link.close();
  }
}

/// Traduce un fallo de conexión a un texto legible en español.
String describeError(Object e, ConnectionConfig? c) {
  final s = '$e'.replaceAll(RegExp(r'token=[^&#\s\x27"]+'), 'token=***');
  if (s.contains('401') || s.contains('403')) {
    return 'Token rechazado por el daemon';
  }
  if (e is TimeoutException) {
    return 'Sin respuesta de ${c?.label ?? 'el daemon'}';
  }
  if (s.contains('refused') ||
      s.contains('unreachable') ||
      s.contains('timed out')) {
    return 'No se puede alcanzar ${c?.label ?? 'el daemon'}';
  }
  return 'Fallo de conexión: $s';
}
