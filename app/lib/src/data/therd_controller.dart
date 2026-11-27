import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:therd_protocol/protocol.dart';

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
    final config = await _store.load();
    final seen = await _store.loadSeen();
    state = state.copyWith(configLoaded: true, config: config, seen: seen);
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
      _learnLan(m.lanHosts);
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

  /// El daemon dice en qué IPs de la red local escucha: se guardan para
  /// probarlas primero la próxima vez (y poder apagar Tailscale en casa).
  /// Un daemon antiguo no manda ninguna; entonces se dejan las que había.
  void _learnLan(List<String> lan) {
    final c = state.config;
    if (c == null || lan.isEmpty || listEquals(c.lanHosts, lan)) return;
    final next = c.withLanHosts(lan);
    state = state.copyWith(config: next);
    _client.updateConfig(next);
    unawaited(_store.save(next));
  }

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

  Future<void> saveConfig(ConnectionConfig config) async {
    await _store.save(config);
    state = state.copyWith(config: config);
    _paused = false;
    _client.connect(config);
  }

  Future<void> forget() async {
    await _store.clear();
    _client.disconnect();
    _subscribed.clear();
    state = const AppState(configLoaded: true);
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
