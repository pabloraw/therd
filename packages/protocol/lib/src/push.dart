import 'enums.dart';

/// Contenido de un aviso por UnifiedPush (cuerpo JSON del POST al endpoint).
///
/// Va sin cifrar: el endpoint es el servidor ntfy propio, dentro de Tailscale.
/// Cabe de sobra en los 4 KB que admite UnifiedPush.
sealed class PushPayload {
  const PushPayload();

  Map<String, dynamic> toJson();

  /// Daemon que manda el aviso (lo añade el emisor junto al resto del JSON);
  /// null en daemons antiguos.
  static String? daemonIdOf(Map<String, dynamic> j) => j['daemonId'] as String?;

  /// null si no es un aviso de therd.
  static PushPayload? fromJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'pending':
        return PushPending(
          requestId: j['requestId'] as String? ?? '',
          sessionId: j['sessionId'] as String? ?? '',
          kind: PendingKind.parse(j['kind']),
          title: j['title'] as String? ?? '',
          body: j['body'] as String? ?? '',
          canAlways: j['canAlways'] as bool? ?? false,
        );
      case 'resolved':
        return PushResolved(requestId: j['requestId'] as String? ?? '');
      case 'turn_done':
        return PushTurnDone(
          sessionId: j['sessionId'] as String? ?? '',
          title: j['title'] as String? ?? '',
          body: j['body'] as String? ?? '',
        );
      case 'turn_cleared':
        return PushTurnCleared(sessionId: j['sessionId'] as String? ?? '');
    }
    return null;
  }
}

/// Claude espera una respuesta: la app pinta la notificación.
final class PushPending extends PushPayload {
  const PushPending({
    required this.requestId,
    required this.sessionId,
    required this.kind,
    required this.title,
    required this.body,
    this.canAlways = false,
  });

  final String requestId;
  final String sessionId;
  final PendingKind kind;

  /// Ya redactados por el daemon («Permiso: Bash», sesión y resumen).
  final String title;
  final String body;

  /// El permiso trae sugerencias para «Permitir siempre».
  final bool canAlways;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'pending',
    'requestId': requestId,
    'sessionId': sessionId,
    'kind': kind.name,
    'title': title,
    'body': body,
    'canAlways': canAlways,
  };
}

/// El pendiente se cerró (contestado, liberado o cancelado): la app retira
/// la notificación.
final class PushResolved extends PushPayload {
  const PushResolved({required this.requestId});
  final String requestId;

  @override
  Map<String, dynamic> toJson() => {'type': 'resolved', 'requestId': requestId};
}

/// Claude terminó un turno y nadie lo ha visto: la app pinta una notificación
/// sin botones. Hay una sola por sesión; la nueva sustituye a la anterior.
final class PushTurnDone extends PushPayload {
  const PushTurnDone({
    required this.sessionId,
    required this.title,
    required this.body,
  });

  final String sessionId;

  /// Ya redactados por el daemon («Terminado: sesión» y el final del texto).
  final String title;
  final String body;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'turn_done',
    'sessionId': sessionId,
    'title': title,
    'body': body,
  };
}

/// La sesión ya se vio o empezó un turno nuevo: la app retira el aviso de
/// fin de turno de [sessionId].
final class PushTurnCleared extends PushPayload {
  const PushTurnCleared({required this.sessionId});
  final String sessionId;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'turn_cleared',
    'sessionId': sessionId,
  };
}
