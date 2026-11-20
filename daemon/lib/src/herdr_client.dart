import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:therd_protocol/protocol.dart';

import 'log.dart';
import 'seen_sync.dart';

/// Error devuelto por herdr (o fallo de conexión con código `unavailable`).
class HerdrException implements Exception {
  HerdrException(this.code, this.message);
  final String code;
  final String message;

  bool get isBlocked => code.contains('blocked');
  bool get isUnavailable => code == 'unavailable';

  @override
  String toString() => 'HerdrException($code): $message';
}

/// Agente tal como lo lista `agent.list`.
class HerdrAgent {
  const HerdrAgent({
    required this.paneId,
    required this.workspaceId,
    required this.agent,
    required this.status,
    this.sessionId,
    this.cwd,
    this.foregroundCwd,
    this.title,
    this.tabId,
    this.focused = false,
  });

  factory HerdrAgent.fromJson(Map<String, dynamic> j) => HerdrAgent(
    tabId: j['tab_id'] as String?,
    paneId: j['pane_id'] as String? ?? '',
    workspaceId: j['workspace_id'] as String? ?? '',
    agent: j['agent'] as String?,
    status: SessionStatus.parse(j['agent_status']),
    sessionId: asMap(j['agent_session'])['value'] as String?,
    cwd: j['cwd'] as String?,
    foregroundCwd: j['foreground_cwd'] as String?,
    title: (j['terminal_title_stripped'] ?? j['title']) as String?,
    focused: j['focused'] == true,
  );

  final String paneId;
  final String workspaceId;
  final String? agent;
  final SessionStatus status;
  final String? sessionId;
  final String? cwd;
  final String? foregroundCwd;
  final String? title;
  final String? tabId;

  /// Es el pane que se ve ahora en el PC.
  final bool focused;

  bool get isClaude => agent == 'claude' && (sessionId ?? '').isNotEmpty;
}

/// Evento del stream de herdr. `event` es p. ej. `pane.agent_status_changed`;
/// `connected` es sintético y se emite al (re)establecer la suscripción.
class HerdrEvent {
  const HerdrEvent(this.event, this.data);
  final String event;
  final Map<String, dynamic> data;

  String? get paneId => data['pane_id'] as String?;
  SessionStatus? get status => data.containsKey('agent_status')
      ? SessionStatus.parse(data['agent_status'])
      : null;
}

/// Acceso al terminal de una sesión para contestar diálogos de Claude Code.
abstract interface class TerminalIo {
  Future<String> readVisible(String pane);
  Future<void> sendKeys(String pane, List<String> keys);
  Future<void> sendText(String pane, String text);
}

/// Cliente JSON-RPC de herdr por socket Unix (una petición por línea).
class HerdrClient implements TerminalIo, FocusIo {
  HerdrClient(
    this.socketPath, {
    this.requestTimeout = const Duration(seconds: 5),
    this.maxBackoff = const Duration(seconds: 30),
  });

  final String socketPath;
  final Duration requestTimeout;
  final Duration maxBackoff;

  int _nextId = 0;

  Future<Socket> _connect() => Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  ).timeout(requestTimeout);

  /// Llama a un método y devuelve `result`. Lanza [HerdrException].
  /// [timeout] sustituye a [requestTimeout] para métodos lentos.
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
    Duration? timeout,
  ]) async {
    final id = 'therd:${++_nextId}';
    Socket socket;
    try {
      socket = await _connect();
    } catch (e) {
      throw HerdrException('unavailable', 'No se pudo abrir $socketPath: $e');
    }
    try {
      socket.write(
        '${jsonEncode({'id': id, 'method': method, 'params': params})}\n',
      );
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout ?? requestTimeout);
      final resp = asMap(jsonDecode(line));
      if (resp['error'] is Map) {
        final e = asMap(resp['error']);
        throw HerdrException(
          e['code'] as String? ?? 'error',
          e['message'] as String? ?? 'error desconocido',
        );
      }
      return asMap(resp['result']);
    } on HerdrException {
      rethrow;
    } on StateError {
      throw HerdrException('unavailable', 'herdr cerró la conexión');
    } on TimeoutException {
      throw HerdrException('unavailable', 'herdr no respondió a tiempo');
    } on SocketException catch (e) {
      throw HerdrException('unavailable', '$e');
    } finally {
      socket.destroy();
    }
  }

  Future<List<HerdrAgent>> agentList() async {
    final r = await call('agent.list');
    final list = r['agents'];
    return [
      if (list is List)
        for (final a in list)
          if (a is Map) HerdrAgent.fromJson(Map<String, dynamic>.from(a)),
    ];
  }

  /// `tab.list` en crudo (tab_id, label y number de cada tab).
  Future<List<Map<String, dynamic>>> tabList() async {
    final r = await call('tab.list');
    final list = r['tabs'];
    return [
      if (list is List)
        for (final t in list)
          if (t is Map) Map<String, dynamic>.from(t),
    ];
  }

  /// `workspace.list` en crudo (label, number y worktree de cada workspace).
  Future<List<Map<String, dynamic>>> workspaceList() async {
    final r = await call('workspace.list');
    final list = r['workspaces'];
    return [
      if (list is List)
        for (final w in list)
          if (w is Map) Map<String, dynamic>.from(w),
    ];
  }

  /// Escribe y envía un prompt. Lanza [HerdrException] (`agent_blocked`...).
  Future<void> prompt(String target, String text) async {
    await call('agent.prompt', {'target': target, 'text': text});
  }

  @override
  Future<void> sendKeys(String target, List<String> keys) async {
    await call('agent.send_keys', {'target': target, 'keys': keys});
  }

  /// Texto literal al pane, sin Enter (sirve aunque el agente esté bloqueado
  /// en un diálogo, a diferencia de [prompt]).
  @override
  Future<void> sendText(String pane, String text) async {
    await call('pane.send_text', {'pane_id': pane, 'text': text});
  }

  /// Lo que se ve ahora mismo en el pane, sin códigos ANSI.
  @override
  Future<String> readVisible(String pane) async {
    final r = await call('pane.read', {'pane_id': pane, 'source': 'visible'});
    // herdr devuelve `{type: pane_read, read: {text: ...}}`.
    return asMap(r['read'])['text'] as String? ?? r['text'] as String? ?? '';
  }

  @override
  Future<String?> currentPane() async {
    final r = await call('pane.current');
    return asMap(r['pane'])['pane_id'] as String?;
  }

  /// Enfoca el pane en el PC; herdr lo da por visto.
  @override
  Future<void> focusPane(String paneId) async {
    await call('pane.focus', {'pane_id': paneId});
  }

  // ------------------------------------------------- abrir y cerrar

  /// Tiempo máximo para que Claude arranque y quede listo.
  static const agentStartTimeout = Duration(seconds: 60);

  /// Tab nueva (sin enfocar) en [workspaceId]; devuelve su pane raíz.
  Future<String> tabCreate(String workspaceId) async {
    final r = await call('tab.create', {
      'workspace_id': workspaceId,
      'focus': false,
    });
    return _rootPane(r, 'tab.create');
  }

  /// Worktree nuevo del repo de [workspaceId] en la rama [branch] (creada
  /// desde [base]), abierto como workspace propio. Devuelve su workspace y
  /// su pane raíz.
  Future<({String workspaceId, String paneId})> worktreeCreate(
    String workspaceId, {
    required String branch,
    String? base,
  }) async {
    final r = await call('worktree.create', {
      'workspace_id': workspaceId,
      'branch': branch,
      'base': ?base,
      'focus': false,
    }, const Duration(seconds: 60));
    final ws = asMap(r['workspace'])['workspace_id'] as String?;
    if (ws == null) {
      throw HerdrException('bad_response', 'worktree.create sin workspace');
    }
    return (workspaceId: ws, paneId: _rootPane(r, 'worktree.create'));
  }

  String _rootPane(Map<String, dynamic> r, String method) {
    final pane = asMap(r['root_pane'])['pane_id'] as String?;
    if (pane == null) throw HerdrException('bad_response', '$method sin pane');
    return pane;
  }

  /// Arranca Claude en [paneId] (que debe estar en el prompt de la shell) y
  /// espera a que esté listo para recibir texto.
  Future<void> startClaude(String paneId) async {
    await call('agent.start', {
      'name': 'claude',
      'kind': 'claude',
      'pane_id': paneId,
      'timeout_ms': agentStartTimeout.inMilliseconds,
    }, agentStartTimeout + const Duration(seconds: 5));
  }

  /// Cierra el pane (y lo que corre en él).
  Future<void> paneClose(String paneId) async {
    await call('pane.close', {'pane_id': paneId});
  }

  /// Quita el worktree de [workspaceId] sin forzar: git se niega si hay
  /// cambios sin commitear.
  Future<void> worktreeRemove(String workspaceId) async {
    await call('worktree.remove', {
      'workspace_id': workspaceId,
      'force': false,
    }, const Duration(seconds: 30));
  }

  // ------------------------------------------------------------ eventos

  final StreamController<HerdrEvent> _events = StreamController.broadcast();
  Stream<HerdrEvent> get events => _events.stream;

  bool _running = false;
  bool _forceReconnect = false;
  Socket? _eventSocket;
  bool _eventsUp = false;

  /// ¿Está viva la suscripción de eventos?
  bool get eventsConnected => _eventsUp;

  /// Arranca el bucle de suscripción con reconexión y backoff. [panes]
  /// devuelve los panes a vigilar en cada (re)conexión.
  void startEvents(Future<List<String>> Function() panes) {
    if (_running) return;
    _running = true;
    unawaited(_loop(panes));
  }

  /// Fuerza una reconexión inmediata (p. ej. cambió el conjunto de panes).
  void resubscribe() {
    _forceReconnect = true;
    _eventSocket?.destroy();
  }

  Future<void> stop() async {
    _running = false;
    _eventSocket?.destroy();
  }

  Future<void> _loop(Future<List<String>> Function() panes) async {
    var delay = const Duration(seconds: 1);
    var loggedDown = false;
    while (_running) {
      try {
        List<String> ids;
        try {
          ids = await panes();
        } catch (_) {
          ids = const [];
        }
        final socket = await _connect();
        _eventSocket = socket;
        _forceReconnect = false;
        final subs = [
          {'type': 'pane.created'},
          {'type': 'pane.closed'},
          {'type': 'pane.focused'},
          for (final id in ids)
            {'type': 'pane.agent_status_changed', 'pane_id': id},
        ];
        socket.write(
          '${jsonEncode({
            'id': 'therd:sub',
            'method': 'events.subscribe',
            'params': {'subscriptions': subs},
          })}\n',
        );
        var acked = false;
        await for (final line
            in socket
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          Map<String, dynamic> m;
          try {
            m = asMap(jsonDecode(line));
          } catch (_) {
            continue;
          }
          if (m['error'] is Map) {
            throw HerdrException(
              asMap(m['error'])['code'] as String? ?? 'error',
              asMap(m['error'])['message'] as String? ?? '',
            );
          }
          if (!acked && m.containsKey('result')) {
            acked = true;
            _eventsUp = true;
            delay = const Duration(seconds: 1);
            if (loggedDown) Log.info('herdr: eventos reconectados');
            loggedDown = false;
            _events.add(const HerdrEvent('connected', {}));
            continue;
          }
          final ev = m['event'];
          if (ev is String) {
            _events.add(HerdrEvent(ev, asMap(m['data'])));
          }
        }
      } catch (e) {
        if (!loggedDown) {
          Log.warn('herdr: eventos no disponibles ($e), reintentando');
          loggedDown = true;
        }
      }
      _eventsUp = false;
      if (!_running) break;
      if (_forceReconnect) continue;
      await Future<void>.delayed(delay);
      delay = delay * 2 > maxBackoff ? maxBackoff : delay * 2;
    }
  }
}
