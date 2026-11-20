import 'dart:async';
import 'dart:math';

import 'package:therd_protocol/protocol.dart';

/// Resultado de un pendiente: cómo terminó y qué responder al hook.
/// `body` null significa 204 vacío (el diálogo sale en el terminal).
class PendingResult {
  const PendingResult(this.resolution, [this.body]);
  final String resolution;
  final Map<String, dynamic>? body;
}

/// Evento del gestor de pendientes.
sealed class PendingEvent {
  const PendingEvent();
}

class PendingOpened extends PendingEvent {
  const PendingOpened(this.pending);
  final Pending pending;
}

class PendingClosed extends PendingEvent {
  const PendingClosed(
    this.pending,
    this.resolution, {
    this.answers,
    this.toTerminal = false,
  });
  final Pending pending;
  final String resolution;
  final Map<String, String>? answers;

  /// El hook vuelve vacío sin que nadie lo decidiera (se fue la última app o
  /// expiró la espera), así que el diálogo sale ahora en el terminal.
  final bool toTerminal;
}

/// Asa para el HookServer: esperar el resultado o cancelar si el hook se cae.
class PendingHandle {
  PendingHandle(this.requestId, this.result, this._cancel);
  final String requestId;
  final Future<PendingResult> result;
  final void Function() _cancel;

  /// El hook HTTP se desconectó: se resuelve como cancelado.
  void cancel() => _cancel();
}

class _Entry {
  _Entry(this.pending, this.completer, this.timer, {this.onTerminal = false});
  final Pending pending;
  final Completer<PendingResult> completer;
  final Timer timer;

  /// Respaldado por un diálogo del terminal: no depende de que haya apps.
  final bool onTerminal;
}

String newRequestId() {
  final r = Random.secure();
  return [
    for (var i = 0; i < 8; i++)
      r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Cuerpo de respuesta del hook PermissionRequest.
Map<String, dynamic> permissionBody(
  Pending p, {
  required bool allow,
  bool always = false,
  String? message,
}) {
  final decision = <String, dynamic>{'behavior': allow ? 'allow' : 'deny'};
  // Claude Code exige updatedInput en ExitPlanMode; el input original es equivalente.
  if (allow) decision['updatedInput'] = p.toolInput;
  if (allow && always && p.suggestions.isNotEmpty) {
    decision['updatedPermissions'] = p.suggestions;
  }
  if (!allow && message != null && message.isNotEmpty) {
    decision['message'] = message;
  }
  return {
    'hookSpecificOutput': {
      'hookEventName': 'PermissionRequest',
      'decision': decision,
    },
  };
}

/// Cuerpo de respuesta del hook PreToolUse de AskUserQuestion.
Map<String, dynamic> questionBody(Pending p, Map<String, String> answers) => {
  'hookSpecificOutput': {
    'hookEventName': 'PreToolUse',
    'permissionDecision': 'allow',
    'updatedInput': {...p.toolInput, 'answers': answers},
  },
};

/// Retiene hooks bloqueantes hasta que la app responde, se libera o expira.
class PendingManager {
  PendingManager({required this.timeout});

  /// Tiempo máximo de espera antes de devolver 204 (ajustable en caliente).
  Duration timeout;

  final Map<String, _Entry> _entries = {};
  final StreamController<PendingEvent> _events = StreamController.broadcast(
    sync: true,
  );

  Stream<PendingEvent> get events => _events.stream;

  List<Pending> forSession(String sessionId) => [
    for (final e in _entries.values)
      if (e.pending.sessionId == sessionId) e.pending,
  ];

  Pending? byId(String requestId) => _entries[requestId]?.pending;

  int get count => _entries.length;

  /// Abre un pendiente y devuelve su asa. [expireAfter] sustituye al
  /// [timeout] general (los diálogos del terminal no expiran igual).
  /// [onTerminal]: el diálogo ya está en el terminal y [releaseAll] no lo
  /// toca.
  PendingHandle open(
    Pending pending, {
    Duration? expireAfter,
    bool onTerminal = false,
  }) {
    final c = Completer<PendingResult>();
    final id = pending.requestId;
    final timer = Timer(
      expireAfter ?? timeout,
      () => _finish(id, PendingResult(Resolution.timeout), toTerminal: true),
    );
    _entries[id] = _Entry(pending, c, timer, onTerminal: onTerminal);
    _events.add(PendingOpened(pending));
    return PendingHandle(
      id,
      c.future,
      () => _finish(id, PendingResult(Resolution.cancelled)),
    );
  }

  void _finish(
    String id,
    PendingResult r, {
    Map<String, String>? answers,
    bool toTerminal = false,
  }) {
    final e = _entries.remove(id);
    if (e == null) return;
    e.timer.cancel();
    if (!e.completer.isCompleted) e.completer.complete(r);
    _events.add(
      PendingClosed(
        e.pending,
        r.resolution,
        answers: answers,
        toTerminal: toTerminal,
      ),
    );
  }

  /// Respuesta de la app a un permiso o plan. False si ya no existe.
  bool respondPermission(
    String requestId, {
    required bool allow,
    bool always = false,
    String? message,
  }) {
    final e = _entries[requestId];
    if (e == null || e.pending.kind == PendingKind.question) return false;
    _finish(
      requestId,
      PendingResult(
        allow ? Resolution.allowed : Resolution.denied,
        permissionBody(
          e.pending,
          allow: allow,
          always: always,
          message: message,
        ),
      ),
    );
    return true;
  }

  /// Respuesta de la app a una pregunta.
  bool respondAnswer(String requestId, Map<String, String> answers) {
    final e = _entries[requestId];
    if (e == null || e.pending.kind != PendingKind.question) return false;
    _finish(
      requestId,
      PendingResult(Resolution.answered, questionBody(e.pending, answers)),
      answers: answers,
    );
    return true;
  }

  /// "Contestar en el PC": el hook vuelve vacío.
  bool release(String requestId) {
    if (!_entries.containsKey(requestId)) return false;
    _finish(requestId, PendingResult(Resolution.released));
    return true;
  }

  /// Resuelve como cancelados los pendientes de una sesión (se contestaron
  /// en el terminal o la sesión avanzó).
  void cancelSession(String sessionId) {
    for (final e in _entries.values.toList()) {
      if (e.pending.sessionId == sessionId) {
        _finish(e.pending.requestId, PendingResult(Resolution.cancelled));
      }
    }
  }

  /// Libera todos los pendientes porque se desconectó la última app: los
  /// hooks vuelven vacíos y los diálogos salen en el terminal. Los que ya
  /// están en el terminal siguen abiertos (y avisados).
  void releaseAll() {
    for (final e in _entries.values.toList()) {
      if (e.onTerminal) continue;
      _finish(
        e.pending.requestId,
        PendingResult(Resolution.released),
        toTerminal: true,
      );
    }
  }

  void dispose() {
    for (final e in _entries.values) {
      e.timer.cancel();
    }
    _entries.clear();
    _events.close();
  }
}
