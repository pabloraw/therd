import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:therd_protocol/protocol.dart';

import '../core/computer.dart';
import '../core/connection_config.dart';
import '../core/settings_store.dart';
import 'app_state.dart';
import 'therd_client.dart';

/// Se sobrescriben en main() y en los tests.
final clientProvider = Provider<TherdClient>(
  (ref) => throw UnimplementedError('clientProvider sin sobrescribir'),
);
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw UnimplementedError('settingsStoreProvider sin sobrescribir'),
);

final therdProvider = NotifierProvider<TherdController, AppState>(
  TherdController.new,
);

/// Une el cliente WebSocket con el estado: reenvía suscripciones al
/// reconectar y expone las acciones de la UI.
class TherdController extends Notifier<AppState> {
  late final TherdClient _client;
  late final SettingsStore _store;
  final _subscribed = <String>{};
  bool _paused = false;

  @override
  AppState build() {
    _client = ref.read(clientProvider);
    _store = ref.read(settingsStoreProvider);
    final subs = [
      _client.messages.listen(_onMessage),
      _client.link.listen(_onLink),
    ];
    ref.onDispose(() {
      for (final s in subs) {
        s.cancel();
      }
      for (final t in _openTimers.values) {
        t.cancel();
      }
    });
    Future.microtask(_bootstrap);
    return AppState(link: _client.current);
  }

  Future<void> _bootstrap() async {
    final computers = await _store.loadComputers();
    final seen = await _store.loadSeen();
    state = state.copyWith(
      configLoaded: true,
      computers: computers,
      seen: seen,
    );
    final config = state.config;
    if (config != null && !_paused) _client.connect(config);
  }

  /// Las sesiones con el chat abierto se dan por leídas; lo visto se guarda
  /// en el teléfono cuando cambia y se avisa al daemon, que lo lleva al PC.
  void _markSeen() {
    var seen = state.seen;
    for (final id in _subscribed) {
      final s = state.session(id);
      if (s == null) continue;
      if (s.lastSeq > (seen[id] ?? -1)) {
        seen = {...seen, id: s.lastSeq};
      }
      if (state.link.isConnected &&
          !_paused &&
          s.lastSeq > s.seenSeq &&
          s.lastSeq > (_sentSeen[id] ?? 0)) {
        _sentSeen[id] = s.lastSeq;
        _client.send(MarkSeenMessage(sessionId: id, seq: s.lastSeq));
      }
    }
    if (!identical(seen, state.seen)) state = state.copyWith(seen: seen);
    if (!identical(state.seen, _savedSeen)) {
      _savedSeen = state.seen;
      unawaited(_store.saveSeen(state.seen));
    }
  }

  Map<String, int>? _savedSeen;

  /// Último `mark_seen` enviado por sesión en esta conexión.
  final Map<String, int> _sentSeen = {};

  /// Endpoint de UnifiedPush de este móvil y el anterior por olvidar.
  String? _pushEndpoint;
  String? _pushPrevious;

  /// El daemon lo guarda; se repite en cada conexión por si se reinició o
  /// cambió de máquina.
  void registerPush(String endpoint, {String? previous}) {
    _pushEndpoint = endpoint;
    _pushPrevious = previous ?? _pushPrevious;
    if (state.link.isConnected) _sendPush();
  }

  void unregisterPush(String endpoint) {
    if (_pushEndpoint == endpoint) _pushEndpoint = null;
    if (state.link.isConnected) {
      _client.send(PushUnregisterMessage(endpoint: endpoint));
    }
  }

  void _sendPush() {
    final e = _pushEndpoint;
    if (e == null) return;
    _client.send(PushRegisterMessage(endpoint: e, previous: _pushPrevious));
    _pushPrevious = null;
  }

  void _onMessage(ServerMessage m) {
    // Conexión nueva (quizá a un daemon reiniciado): se vuelve a avisar.
    if (m is HelloMessage) _sentSeen.clear();
    state = reduce(state, m);
    if (m is HelloMessage) {
      _sendPush();
      _learnFromHello(m);
    }
    _markSeen();
    if (m is SessionsMessage && state.link.isConnected) {
      // Sesión suscrita que reapareció tras desaparecer: se pide de nuevo.
      for (final id in _subscribed.toList()) {
        if (state.session(id) != null && !state.chats.containsKey(id)) {
          _resubscribe(id);
        }
      }
    }
  }

  /// Lo que el daemon cuenta de sí en el hello se guarda en su ordenador:
  /// las IPs de la red local (para probarlas primero la próxima vez y poder
  /// apagar Tailscale en casa), su id (para reconocer sus avisos) y su
  /// hostname (nombre por defecto). Un daemon antiguo no manda nada de esto;
  /// entonces se deja lo que había.
  void _learnFromHello(HelloMessage m) {
    final pc = state.computer;
    if (pc == null) return;
    var next = pc;
    if (m.lanHosts.isNotEmpty && !listEquals(pc.config.lanHosts, m.lanHosts)) {
      next = next.copyWith(config: pc.config.withLanHosts(m.lanHosts));
    }
    if (m.daemonId != null && m.daemonId != pc.daemonId) {
      next = next.copyWith(daemonId: m.daemonId);
    }
    if (m.machine != null && m.machine != pc.machine) {
      next = next.copyWith(machine: m.machine);
    }
    if (next == pc) return;
    if (next.config != pc.config) _client.updateConfig(next.config);
    _replace(next);
    unawaited(_persist());
  }

  void _replace(Computer pc) {
    final c = state.computers;
    state = state.copyWith(
      computers: SavedComputers([
        for (final x in c.list) x.id == pc.id ? pc : x,
      ], c.activeId),
    );
  }

  Future<void> _persist() => _store.saveComputers(state.computers);

  void _onLink(LinkStatus status) {
    final wasConnected = state.link.isConnected;
    state = state.copyWith(link: status);
    if (status.isConnected && !wasConnected) {
      // Tras (re)conectar se vuelve a pedir el backlog de cada sesión abierta.
      for (final id in _subscribed) {
        _resubscribe(id);
      }
    }
  }

  void _resubscribe(String id) {
    final chat = state.chat(id);
    state = state.copyWith(
      chats: {
        ...state.chats,
        id: chat.copyWith(loadingOlder: false, awaitingInitial: true),
      },
    );
    _client.send(SubscribeMessage(sessionId: id));
  }

  // ------------------------------------------------------------ conexión

  /// Añade un ordenador y pasa a él. Si ya había uno con el mismo host y
  /// puerto, se actualiza ese en vez de duplicarlo.
  Future<void> addComputer(ConnectionConfig config, {String? name}) async {
    for (final pc in state.computers.list) {
      if (pc.config.host == config.host && pc.config.port == config.port) {
        return updateComputer(pc.id, config, name: name);
      }
    }
    final pc = Computer(
      id: Computer.newId(),
      config: config,
      name: _blankToNull(name),
    );
    final c = state.computers;
    state = state.copyWith(
      computers: SavedComputers([...c.list, pc], c.activeId),
    );
    await switchTo(pc.id);
  }

  /// Cambia la conexión y el nombre de un ordenador y pasa a él.
  Future<void> updateComputer(
    String id,
    ConnectionConfig config, {
    String? name,
  }) async {
    final pc = state.computers.byId(id);
    if (pc == null) return;
    final n = _blankToNull(name);
    final next = pc.copyWith(config: config, name: n, clearName: n == null);
    _replace(next);
    if (state.computers.activeId == id && pc.config == config) {
      await _persist();
      return;
    }
    // Conexión distinta: se empieza de cero aunque sea el activo.
    await switchTo(id, force: true);
  }

  /// Pasa a otro ordenador: cierra la conexión, olvida sus sesiones y
  /// conecta con el nuevo.
  Future<void> switchTo(String id, {bool force = false}) async {
    final pc = state.computers.byId(id);
    if (pc == null) return;
    if (!force && state.computers.activeId == id) return;
    _client.disconnect();
    _resetSession();
    state = AppState(
      configLoaded: true,
      computers: SavedComputers(state.computers.list, id),
      seen: state.seen,
      hellos: state.hellos,
    );
    await _persist();
    if (!_paused) _client.connect(pc.config);
  }

  /// Olvida un ordenador. Si era el activo, se pasa al siguiente que quede.
  Future<void> removeComputer(String id) async {
    final c = state.computers;
    if (c.byId(id) == null) return;
    final wasActive = c.activeId == id;
    // Que su daemon deje de mandar avisos a este móvil.
    final e = _pushEndpoint;
    if (wasActive && e != null && state.link.isConnected) {
      _client.send(PushUnregisterMessage(endpoint: e));
    }
    final rest = [
      for (final x in c.list)
        if (x.id != id) x,
    ];
    if (!wasActive) {
      state = state.copyWith(computers: SavedComputers(rest, c.activeId));
      await _persist();
      return;
    }
    _client.disconnect();
    _resetSession();
    final next = rest.firstOrNull;
    state = AppState(
      configLoaded: true,
      computers: SavedComputers(rest, next?.id),
      seen: state.seen,
      hellos: state.hellos,
    );
    await _persist();
    if (next != null && !_paused) _client.connect(next.config);
  }

  /// Olvida el ordenador en uso.
  Future<void> forget() async {
    final id = state.computers.activeId;
    if (id != null) await removeComputer(id);
  }

  void _resetSession() {
    _subscribed.clear();
    _sentSeen.clear();
    for (final t in _openTimers.values) {
      t.cancel();
    }
    _openTimers.clear();
  }

  /// La app pasa a segundo plano: se cierra el socket.
  void pause() {
    _paused = true;
    _client.disconnect();
  }

  /// La app vuelve a primer plano: se reconecta si hay configuración.
  void resume() {
    if (!_paused) return;
    _paused = false;
    final c = state.config;
    if (c != null) _client.connect(c);
  }

  Future<String?> probe(ConnectionConfig config) => _client.probe(config);

  // ------------------------------------------------------------- sesiones

  void openSession(String id) {
    _subscribed.add(id);
    _markSeen();
    final chat = state.chat(id);
    state = state.copyWith(
      chats: {
        ...state.chats,
        id: chat.copyWith(loadingOlder: false, awaitingInitial: true),
      },
    );
    if (state.link.isConnected) _client.send(SubscribeMessage(sessionId: id));
  }

  void closeSession(String id) {
    _markSeen();
    if (_subscribed.remove(id) && state.link.isConnected) {
      _client.send(UnsubscribeMessage(sessionId: id));
    }
  }

  /// Pide la página de histórico anterior al item más antiguo cargado.
  void loadOlder(String id) {
    final chat = state.chat(id);
    final cursor = chat.cursor;
    if (!chat.hasMore ||
        chat.loadingOlder ||
        chat.awaitingInitial ||
        cursor == null) {
      return;
    }
    if (!state.link.isConnected) return;
    state = state.copyWith(
      chats: {...state.chats, id: chat.copyWith(loadingOlder: true)},
    );
    _client.send(SubscribeMessage(sessionId: id, before: cursor));
  }

  // -------------------------------------------------------------- acciones

  int _localSeq = 0;

  /// Envía el prompt y lo pinta ya como provisional hasta que vuelva del
  /// transcript.
  void sendPrompt(
    String id,
    String text, {
    List<PromptImage> images = const [],
  }) {
    final chat = state.chat(id);
    // Las imágenes se pintan desde aquí hasta que vuelvan con id del daemon.
    final localIds = <String>[];
    for (final img in images) {
      final key = '${kLocalPrefix}img:${++_localSeq}';
      localImages[key] = base64.decode(img.data);
      localIds.add(key);
    }
    final o = Outgoing(
      id: '$kLocalPrefix${++_localSeq}',
      sessionId: id,
      text: text.trim(),
      images: localIds,
      // Con el chat aún sin cargar, el seq de la sesión evita casar el
      // provisional con un prompt viejo del backlog.
      afterSeq: math.max(chat.lastSeq, state.session(id)?.lastSeq ?? 0),
      sentAt: DateTime.now(),
    );
    state = state.copyWith(
      chats: {
        ...state.chats,
        id: chat.copyWith(outgoing: [...chat.outgoing, o]),
      },
    );
    _client.send(PromptMessage(sessionId: id, text: text, images: images));
  }

  void interrupt(String id) => _client.send(InterruptMessage(sessionId: id));

  void respondPermission(
    String requestId, {
    required bool allow,
    bool always = false,
    String? message,
  }) => _client.send(
    PermissionMessage(
      requestId: requestId,
      allow: allow,
      always: always,
      message: (message == null || message.trim().isEmpty)
          ? null
          : message.trim(),
    ),
  );

  void answer(String requestId, Map<String, String> answers) =>
      _client.send(AnswerMessage(requestId: requestId, answers: answers));

  void release(String requestId) =>
      _client.send(ReleaseMessage(requestId: requestId));

  // ------------------------------------------------- abrir y cerrar

  int _opSeq = 0;

  /// Pide abrir Claude en [workspaceId] (o en un worktree nuevo si hay
  /// [branch]). Devuelve el opId, que queda en `state.opening` hasta que la
  /// sesión aparece ([finishOpening]), falla o pasa un rato sin noticias.
  String requestSession(
    String workspaceId, {
    String? branch,
    String? base,
    String? prompt,
  }) {
    final opId = 'op:${DateTime.now().microsecondsSinceEpoch}:${++_opSeq}';
    state = state.copyWith(opening: {...state.opening, opId: null});
    _client.send(
      OpenSessionMessage(
        opId: opId,
        workspaceId: workspaceId,
        branch: _blankToNull(branch),
        base: _blankToNull(base),
        prompt: _blankToNull(prompt),
      ),
    );
    // Arrancar Claude puede tardar (worktree, hooks); más allá se olvida.
    _openTimers[opId] = Timer(openingTimeout, () => finishOpening(opId));
    return opId;
  }

  /// Lo que se espera a que una sesión pedida aparezca en la lista.
  static const openingTimeout = Duration(seconds: 90);

  final Map<String, Timer> _openTimers = {};

  void finishOpening(String opId) {
    _openTimers.remove(opId)?.cancel();
    if (!state.opening.containsKey(opId)) return;
    state = state.copyWith(opening: {...state.opening}..remove(opId));
  }

  void closeRemoteSession(String sessionId) =>
      _client.send(CloseSessionMessage(sessionId: sessionId));

  void removeWorktree(String workspaceId) =>
      _client.send(RemoveWorktreeMessage(workspaceId: workspaceId));
}

String? _blankToNull(String? s) {
  final t = s?.trim() ?? '';
  return t.isEmpty ? null : t;
}
