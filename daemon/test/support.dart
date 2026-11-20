import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:therd_daemon/src/herdr_client.dart';

/// Terminal falso: pantalla modificable y registro de lo que se pulsa.
class FakeTerminal implements TerminalIo {
  FakeTerminal([this.screen = '']);
  String screen;
  final sent = <Object>[];

  @override
  Future<String> readVisible(String pane) async => screen;

  @override
  Future<void> sendKeys(String pane, List<String> keys) async => sent.add(keys);

  @override
  Future<void> sendText(String pane, String text) async => sent.add(text);
}

/// Carpeta temporal bajo /tmp/claude-1000 (los sockets Unix piden rutas cortas).
Directory makeTemp(String prefix) {
  final base = Directory('/tmp/claude-1000/therd-test')
    ..createSync(recursive: true);
  return base.createTempSync(prefix);
}

/// Servidor herdr falso por socket Unix: una petición JSON por línea.
class FakeHerdr {
  FakeHerdr(this.path);

  final String path;
  late ServerSocket _server;
  final List<Map<String, dynamic>> requests = [];
  final List<Socket> _subscribers = [];

  /// Respuestas por método (`result`) o errores `{error: {...}}`.
  final Map<String, Map<String, dynamic> Function(Map<String, dynamic> req)>
  handlers = {};

  Future<void> start() async {
    _server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    _server.listen(_onConn);
  }

  void _onConn(Socket s) {
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final req = Map<String, dynamic>.from(jsonDecode(line) as Map);
          requests.add(req);
          final method = req['method'] as String;
          if (method == 'events.subscribe') {
            _subscribers.add(s);
            s.write(
              '${jsonEncode({
                'id': req['id'],
                'result': {'type': 'subscription_started'},
              })}\n',
            );
            return;
          }
          final h = handlers[method];
          final body = h != null
              ? h(req)
              : {
                  'error': {'code': 'unknown_method', 'message': method},
                };
          s.write('${jsonEncode({'id': req['id'], ...body})}\n');
        }, onError: (_) {});
  }

  /// Emite un evento a los suscriptores.
  void emit(String event, Map<String, dynamic> data) {
    for (final s in _subscribers) {
      s.write('${jsonEncode({'event': event, 'data': data})}\n');
    }
  }

  int get subscriberCount => _subscribers.length;

  /// Corta las conexiones de eventos (simula caída de herdr).
  void dropSubscribers() {
    for (final s in _subscribers) {
      s.destroy();
    }
    _subscribers.clear();
  }

  Future<void> stop() async {
    dropSubscribers();
    await _server.close();
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

Map<String, dynamic> agentJson({
  required String paneId,
  required String sessionId,
  String status = 'idle',
  String cwd = '/tmp/proyecto',
  String title = 'Claude Code',
  String workspace = 'w1',
}) => {
  'agent': 'claude',
  'agent_session': {
    'agent': 'claude',
    'kind': 'id',
    'source': 'herdr:claude',
    'value': sessionId,
  },
  'agent_status': status,
  'pane_id': paneId,
  'workspace_id': workspace,
  'tab_id': '$workspace:t1',
  'cwd': cwd,
  'terminal_title_stripped': title,
};

/// Espera a que [cond] sea cierta (o falla por tiempo).
Future<void> waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
  String what = 'condición',
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('Esperando $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
