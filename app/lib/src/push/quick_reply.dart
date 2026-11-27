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
  // Primero la red local con poca espera; si no conecta, Tailscale. No se
  // abre una conexión de sondeo aparte: al cerrarse, el daemon soltaría los
  // pendientes por creer que la app se ha ido.
  final hosts = config.hosts;
  for (final h in hosts.take(hosts.length - 1)) {
    try {
      return await _quickReply(
        config,
        h,
        message,
        requestId,
        timeout,
        readyTimeout: WebSocketTherdClient.lanTimeout,
      );
    } on _Unreachable {
      continue;
    }
  }
  try {
    return await _quickReply(config, hosts.last, message, requestId, timeout);
  } on _Unreachable catch (e) {
    return e.reason;
  }
}

/// La dirección no aceptó la conexión; se puede probar otra.
class _Unreachable implements Exception {
  _Unreachable(this.reason);
  final String reason;
}

Future<String?> _quickReply(
  ConnectionConfig config,
  String host,
  ClientMessage message,
  String requestId,
  Duration timeout, {
  Duration? readyTimeout,
}) async {
  WebSocketChannel? ch;
  try {
    ch = WebSocketChannel.connect(config.webSocketUriFor(host));
    try {
      await ch.ready.timeout(readyTimeout ?? timeout);
    } on TimeoutException {
      throw _Unreachable('Sin respuesta de ${config.labelFor(host)}');
    } catch (e) {
      final text = describeError(e, config);
      // Un token rechazado no se arregla con otra dirección.
      if (text.startsWith('Token')) return text;
      throw _Unreachable(text);
    }
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
    return 'Sin respuesta de ${config.labelFor(host)}';
  } on _Unreachable {
    rethrow;
  } catch (e) {
    return describeError(e, config);
  } finally {
    unawaited(ch?.sink.close());
  }
}
