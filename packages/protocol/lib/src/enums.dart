/// Versión del protocolo WebSocket. Se incrementa en cambios incompatibles
/// o cuando se añaden mensajes que la otra parte debe conocer.
///
/// 1: primera versión (un daemon que no manda `version` cuenta como 1).
/// 2: `open_session` y avisos de versión.
const int protocolVersion = 2;

/// Versión que se supone a un daemon que no la manda en el hello.
const int legacyProtocolVersion = 1;

/// Estado de una sesión (el mismo vocabulario que herdr).
enum SessionStatus {
  idle,
  working,
  blocked,
  done,
  unknown;

  static SessionStatus parse(Object? v) => SessionStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => SessionStatus.unknown,
  );
}

/// Estado de una tarjeta de herramienta.
enum ToolStatus {
  running,
  ok,
  error;

  static ToolStatus parse(Object? v) => ToolStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => ToolStatus.running,
  );
}

/// Tipo de pendiente que espera respuesta de la app.
enum PendingKind {
  permission,
  question,
  plan;

  static PendingKind parse(Object? v) => PendingKind.values.firstWhere(
    (e) => e.name == v,
    orElse: () => PendingKind.permission,
  );
}

/// Tipo de marcador en el chat.
enum MarkerKind {
  compact,
  turnEnd,
  error,
  other;

  String get wire => switch (this) {
    MarkerKind.compact => 'compact',
    MarkerKind.turnEnd => 'turn_end',
    MarkerKind.error => 'error',
    MarkerKind.other => 'other',
  };

  static MarkerKind parse(Object? v) => MarkerKind.values.firstWhere(
    (e) => e.wire == v,
    orElse: () => MarkerKind.other,
  );
}

/// Cómo terminó un pendiente (campo `resolution` de pending.resolved).
abstract final class Resolution {
  static const allowed = 'allowed';
  static const denied = 'denied';
  static const answered = 'answered';
  static const released = 'released';
  static const timeout = 'timeout';

  /// El hook se desconectó: se contestó en el terminal o Claude canceló.
  static const cancelled = 'cancelled';
}

/// Códigos de error de [ErrorMessage.code].
abstract final class ErrorCode {
  static const unauthorized = 'unauthorized';
  static const badRequest = 'bad_request';
  static const unknownSession = 'unknown_session';
  static const unknownRequest = 'unknown_request';
  static const agentBlocked = 'agent_blocked';
  static const herdrUnavailable = 'herdr_unavailable';
  static const internal = 'internal';
}
