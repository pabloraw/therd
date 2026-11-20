import 'dart:async';
import 'dart:convert';

import 'package:therd_protocol/protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/connection_config.dart';
import '../data/therd_client.dart';

/// Botones de la notificación de un pendiente.
abstract final class QuickAction {
  static const allow = 'allow';
  static const deny = 'deny';

  /// Textos de los botones según el tipo; vacío si no lleva (preguntas).
  static List<(String id, String label)> forKind(PendingKind kind) =>
      switch (kind) {
        PendingKind.permission => const [
          (allow, 'Permitir'),
          (deny, 'Denegar'),
        ],
        PendingKind.plan => const [(allow, 'Aprobar'), (deny, 'Rechazar')],
        PendingKind.question => const [],
      };
}

/// Lo que lleva la notificación para abrir el chat o contestar.
class NotificationPayload {
  const NotificationPayload({required this.sessionId, this.requestId});

  final String sessionId;
  final String? requestId;

  String encode() => jsonEncode({'s': sessionId, 'r': requestId});

  /// Acepta también el formato antiguo (solo el sessionId).
  static NotificationPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is Map && j['s'] is String) {
        return NotificationPayload(
          sessionId: j['s'] as String,
          requestId: j['r'] as String?,
        );
      }
    } catch (_) {
      // texto suelto
    }
    return NotificationPayload(sessionId: raw);
  }
}

/// Mensaje que manda un botón, o null si el id no es de un botón.
PermissionMessage? quickMessage(String? actionId, String requestId) =>
    switch (actionId) {
      QuickAction.allow => PermissionMessage(requestId: requestId, allow: true),
      QuickAction.deny => PermissionMessage(requestId: requestId, allow: false),
      _ => null,
    };

/// Abre una conexión suelta con el daemon, manda [message] y espera a que
/// el pendiente [requestId] se cierre. Devuelve null si fue bien, o el motivo
/// del fallo para enseñarlo.
Future<String?> sendQuickReply(
  ConnectionConfig config,
  ClientMessage message,
  String requestId, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  WebSocketChannel? ch;
  try {
    ch = WebSocketChannel.connect(config.webSocketUri);
    await ch.ready.timeout(timeout);
    final done = Completer<String?>();
    final sub = ch.stream.listen(
      (data) {
        if (data is! String || done.isCompleted) return;
        final m = decodeMessage(data);
        switch (m) {
          case HelloMessage():
            ch!.sink.add(message.encode());
          case PendingResolvedMessage() when m.requestId == requestId:
            done.complete(null);
          case ErrorMessage() when m.code == ErrorCode.unauthorized:
            done.complete('Token rechazado por el daemon');
          case ErrorMessage() when m.requestId == requestId:
            done.complete(
              m.code == ErrorCode.unknownRequest
                  ? 'Ya no estaba pendiente'
                  : m.message,
            );
          default:
            break;
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.complete(describeError(e, config));
      },
      onDone: () {
        if (!done.isCompleted) done.complete('El daemon cerró la conexión');
      },
    );
    try {
      return await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  } on TimeoutException {
    return 'Sin respuesta de ${config.label}';
  } catch (e) {
    return describeError(e, config);
  } finally {
    unawaited(ch?.sink.close());
  }
}
