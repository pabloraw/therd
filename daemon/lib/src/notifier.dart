import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:therd_protocol/protocol.dart';

import 'config.dart';
import 'log.dart';
import 'pending.dart';
import 'push_registry.dart';
import 'session_store.dart';

/// Cliente mínimo de ntfy. Nunca lanza: los fallos se avisan una vez en el
/// log y se vuelve a avisar al recuperarse.
class NtfyClient {
  NtfyClient(this.config, {this.timeout = const Duration(seconds: 5)});

  final NtfyConfig config;
  final Duration timeout;
  bool _warned = false;

  Uri get _base => Uri.parse(config.url);

  /// Publica una notificación. Devuelve true si ntfy la aceptó.
  Future<bool> publish({
    required String title,
    required String message,
    String? click,
    int priority = 4,
    List<String> tags = const [],
  }) async {
    final r = await _request('POST', _base, {
      'topic': config.topic,
      'title': title,
      'message': message,
      'click': ?click,
      'tags': tags,
      'priority': priority,
    });
    if (r.ok) {
      if (_warned) Log.info('ntfy: conexión recuperada');
      _warned = false;
      return true;
    }
    if (!_warned) {
      Log.warn('ntfy no disponible: ${r.reason}');
      _warned = true;
    }
    return false;
  }

  /// GET `/v1/health`: null si responde `healthy`, o el motivo del fallo.
  Future<String?> health() async {
    final base = _base.path.replaceAll(RegExp(r'/+$'), '');
    final r = await _request('GET', _base.replace(path: '$base/v1/health'));
    if (!r.ok) return r.reason;
    return RegExp(r'"healthy"\s*:\s*true').hasMatch(r.body)
        ? null
        : 'respuesta inesperada: ${r.body}';
  }

  Future<({bool ok, String reason, String body})> _request(
    String method,
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      if (config.token != null) {
        req.headers.set('Authorization', 'Bearer ${config.token}');
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      return (ok: ok, reason: ok ? '' : 'HTTP ${res.statusCode}', body: text);
    } catch (e) {
      return (ok: false, reason: '$e', body: '');
    } finally {
      client.close(force: true);
    }
  }
}

/// Título de sesión como lo muestra la app: el título, o el nombre de la carpeta.
String notifySessionTitle(SessionInfo? s) {
  if (s == null) return 'Sesión de Claude';
  if (s.title.trim().isNotEmpty) return s.title.trim();
  final parts = s.cwd.split('/').where((e) => e.isNotEmpty);
  return parts.isEmpty ? 'Sesión de Claude' : parts.last;
}

/// `mcp__server__tool` pasa a `server tool`.
String shortToolName(String name) {
  if (!name.startsWith('mcp__')) return name;
  return name.substring(5).split('__').where((e) => e.isNotEmpty).join(' ');
}

String _oneLine(String s, int max) {
  final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= max ? t : '${t.substring(0, max - 1)}…';
}

/// Resumen corto de lo que se pide: comando, ruta, pregunta o plan.
String pendingSummary(Pending p, {int max = 140}) {
  switch (p.kind) {
    case PendingKind.question:
      return p.questions.isEmpty
          ? ''
          : _oneLine(p.questions.first.question, max);
    case PendingKind.plan:
      final first = (p.plan ?? '')
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
      return _oneLine(first.replaceFirst(RegExp(r'^#+\s*'), ''), max);
    case PendingKind.permission:
      for (final k in ['command', 'file_path', 'path', 'url', 'pattern']) {
        final v = p.toolInput[k];
        if (v is String && v.trim().isNotEmpty) return _oneLine(v, max);
      }
      return '';
  }
}

/// Envía avisos a endpoints de UnifiedPush: POST con el JSON de
/// [PushPayload]. ntfy se lo pasa a la app therd, que pinta su notificación.
class PushSender {
  PushSender({this.timeout = const Duration(seconds: 5)});

  final Duration timeout;
  final Set<String> _warned = {};

  /// Devuelve true si el servidor aceptó el aviso. Nunca lanza.
  Future<bool> send(String endpoint, PushPayload payload) async {
    final client = HttpClient()..connectionTimeout = timeout;
    String reason;
    try {
      final req = await client.postUrl(Uri.parse(endpoint)).timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(payload.toJson())));
      final res = await req.close().timeout(timeout);
      await res.drain<void>().timeout(timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (_warned.remove(endpoint)) Log.info('push: endpoint recuperado');
        return true;
      }
      reason = 'HTTP ${res.statusCode}';
    } catch (e) {
      reason = '$e';
    } finally {
      client.close(force: true);
    }
    if (_warned.add(endpoint)) Log.warn('push: no se pudo avisar: $reason');
    return false;
  }
}

/// Avisa cuando se abre un pendiente y no hay ninguna app conectada: por
/// UnifiedPush si algún móvil registró su endpoint y, si no, por el topic de
/// ntfy. Con UnifiedPush avisa también al cerrarse, para retirar la
/// notificación.
class PendingNotifier {
  PendingNotifier({
    required Stream<PendingEvent> events,
    required this.client,
    required this.hasClients,
    required this.sessionInfo,
    this.push,
    PushSender? sender,
  }) : sender = sender ?? PushSender() {
    _sub = events.listen(_onEvent);
  }

  /// null = topic de ntfy desactivado.
  final NtfyClient? client;
  final bool Function() hasClients;
  final SessionInfo? Function(String sessionId) sessionInfo;

  /// Endpoints de UnifiedPush (null = sin UnifiedPush).
  final PushRegistry? push;
  final PushSender sender;
  late final StreamSubscription<PendingEvent> _sub;
  final Set<String> _sent = {};

  /// Pendientes avisados por UnifiedPush, para retirar su notificación.
  final Set<String> _pushed = {};

  /// Publicaciones en curso (los tests esperan a que terminen).
  final List<Future<void>> inFlight = [];

  void _onEvent(PendingEvent e) {
    switch (e) {
      case PendingOpened():
        _onOpened(e.pending);
      case PendingClosed():
        // Al pasar al terminal se reabre con el mismo requestId: la
        // notificación sigue valiendo.
        if (e.toTerminal || !_pushed.remove(e.pending.requestId)) return;
        _toEndpoints(PushResolved(requestId: e.pending.requestId));
    }
  }

  void _onOpened(Pending p) {
    final endpoints = push?.endpoints ?? const [];
    final c = client;
    if (endpoints.isEmpty && c == null) return;
    if (hasClients() || !_sent.add(p.requestId)) return;
    if (_sent.length > 500) _sent.remove(_sent.first);
    final session = _oneLine(notifySessionTitle(sessionInfo(p.sessionId)), 60);
    final summary = pendingSummary(p, max: 139 - session.length);
    final title = switch (p.kind) {
      PendingKind.permission => 'Permiso: ${shortToolName(p.toolName)}',
      PendingKind.question => 'Pregunta',
      PendingKind.plan => 'Plan para revisar',
    };
    final body = summary.isEmpty ? session : '$session\n$summary';
    if (endpoints.isNotEmpty) {
      _pushed.add(p.requestId);
      if (_pushed.length > 500) _pushed.remove(_pushed.first);
      _toEndpoints(
        PushPending(
          requestId: p.requestId,
          sessionId: p.sessionId,
          kind: p.kind,
          title: title,
          body: body,
          canAlways: p.suggestions.isNotEmpty,
        ),
      );
      return;
    }
    final f = c!.publish(
      title: title,
      message: body,
      click: 'therd://session/${p.sessionId}',
      tags: const ['hourglass_flowing_sand'],
    );
    inFlight.add(f.then((_) {}));
  }

  void _toEndpoints(PushPayload payload) {
    for (final ep in push?.endpoints ?? const <String>[]) {
      inFlight.add(sender.send(ep, payload).then((_) {}));
    }
  }

  Future<void> dispose() => _sub.cancel();
}

/// Avisa del fin de turno de una sesión que nadie ha visto, ni en el PC ni en
/// el móvil. Mismo transporte que [PendingNotifier]: UnifiedPush si hay
/// endpoints y, si no, el topic de ntfy (sin retirada).
///
/// Tras el fin de turno (herdr pasa a `done` o llega el hook `Stop`) espera
/// [settle] por si aún llega el final del transcript o alguien la ve. Se
/// retira sola al verse o al empezar un turno nuevo.
class TurnNotifier {
  TurnNotifier({
    required this.store,
    required this.pendings,
    required this.client,
    required this.hasClients,
    this.push,
    PushSender? sender,
    this.settle = const Duration(seconds: 5),
  }) : sender = sender ?? PushSender();

  final SessionStore store;
  final PendingManager pendings;

  /// null = topic de ntfy desactivado.
  final NtfyClient? client;
  final bool Function() hasClients;
  final PushRegistry? push;
  final PushSender sender;
  final Duration settle;

  final Map<String, Timer> _timers = {};

  /// Último seq avisado por sesión: no se repite y marca hasta dónde debe
  /// llegar lo visto para retirar el aviso.
  final Map<String, int> _sentSeq = {};

  /// Sesiones con un aviso vivo por UnifiedPush.
  final Set<String> _pushed = {};
  StreamSubscription<StoreEvent>? _sub;

  /// Publicaciones en curso (los tests esperan a que terminen).
  final List<Future<void>> inFlight = [];

  void start() => _sub = store.events.listen(_onStore);

  Future<void> dispose() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    await _sub?.cancel();
  }

  /// Fin de turno de [sessionId]. Varias señales del mismo turno (herdr y el
  /// hook) cuentan una sola vez.
  void onTurnEnd(String sessionId) {
    if (_timers.containsKey(sessionId)) return;
    if (pendings.forSession(sessionId).isNotEmpty) return;
    late final Timer t;
    t = Timer(settle, () {
      _timers.remove(sessionId);
      _fire(sessionId);
    });
    _timers[sessionId] = t;
  }

  void _onStore(StoreEvent e) {
    switch (e) {
      case StatusChanged(:final sessionId, :final status):
        // Turno nuevo: lo pendiente de avisar deja de valer.
        if (status == SessionStatus.working) _cancel(sessionId);
      case SeenChanged(:final sessionId, :final seq):
        final sent = _sentSeq[sessionId];
        if (sent != null && seq >= sent) _clear(sessionId);
      case SessionRemoved(:final sessionId):
        _cancel(sessionId);
        _sentSeq.remove(sessionId);
        _pushed.remove(sessionId);
      default:
    }
  }

  void _cancel(String sessionId) {
    _timers.remove(sessionId)?.cancel();
    _clear(sessionId);
  }

  void _clear(String sessionId) {
    if (!_pushed.remove(sessionId)) return;
    _toEndpoints(PushTurnCleared(sessionId: sessionId));
  }

  void _fire(String sessionId) {
    final info = store.info(sessionId);
    if (info == null || hasClients()) return;
    if (info.status == SessionStatus.working) return;
    if (info.seenSeq >= info.lastSeq) return;
    if (_sentSeq[sessionId] == info.lastSeq) return;
    if (pendings.forSession(sessionId).isNotEmpty) return;
    final endpoints = push?.endpoints ?? const <String>[];
    final c = client;
    if (endpoints.isEmpty && c == null) return;
    _sentSeq[sessionId] = info.lastSeq;

    final session = _oneLine(notifySessionTitle(info), 60);
    final title = 'Terminado: $session';
    final text = _lastAssistantText(sessionId);
    final body = text.isEmpty ? 'Claude ha terminado' : _oneLine(text, 140);
    if (endpoints.isNotEmpty) {
      _pushed.add(sessionId);
      _toEndpoints(
        PushTurnDone(sessionId: sessionId, title: title, body: body),
      );
      return;
    }
    inFlight.add(
      c!
          .publish(
            title: title,
            message: body,
            click: 'therd://session/$sessionId',
            priority: 3,
            tags: const ['white_check_mark'],
          )
          .then((_) {}),
    );
  }

  String _lastAssistantText(String sessionId) {
    final items = store.itemsOf(sessionId);
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is AssistantTextItem && it.text.trim().isNotEmpty) return it.text;
    }
    return '';
  }

  void _toEndpoints(PushPayload payload) {
    for (final ep in push?.endpoints ?? const <String>[]) {
      inFlight.add(sender.send(ep, payload).then((_) {}));
    }
  }
}
