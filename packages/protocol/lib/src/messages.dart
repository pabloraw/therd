import 'dart:convert';

import 'enums.dart';
import 'items.dart';
import 'models.dart';

/// Mensaje WebSocket. Cada uno es un objeto JSON con campo "type".
sealed class Message {
  const Message();

  String get type;

  Map<String, dynamic> toJson() => {'type': type, ...bodyJson()};

  Map<String, dynamic> bodyJson();

  String encode() => jsonEncode(toJson());

  /// Decodifica por "type". Tipos desconocidos o cuerpos inválidos dan
  /// [UnknownMessage]; nunca lanza.
  factory Message.fromJson(Map<String, dynamic> j) {
    try {
      return _decode(j) ?? UnknownMessage(rawType: '${j['type']}', raw: j);
    } catch (_) {
      return UnknownMessage(rawType: '${j['type']}', raw: j);
    }
  }
}

/// Decodifica un texto JSON; si no es un objeto JSON válido da [UnknownMessage].
Message decodeMessage(String text) {
  try {
    final v = jsonDecode(text);
    if (v is Map) return Message.fromJson(Map<String, dynamic>.from(v));
    return UnknownMessage(rawType: '', raw: {'value': v});
  } catch (_) {
    return UnknownMessage(rawType: '', raw: {'text': text});
  }
}

/// Mensajes servidor a app.
sealed class ServerMessage extends Message {
  const ServerMessage();
}

/// Mensajes app a servidor.
sealed class ClientMessage extends Message {
  const ClientMessage();
}

// ---------------------------------------------------------------- servidor

/// type "hello": primer mensaje tras autenticar.
final class HelloMessage extends ServerMessage {
  const HelloMessage({
    this.version = protocolVersion,
    this.sessions = const [],
    this.workspaces = const [],
    this.lanHosts = const [],
    this.daemonId,
    this.machine,
  });
  final int version;

  /// Identificador estable del daemon: la app lo usa para saber de qué
  /// ordenador viene un aviso. null en daemons antiguos.
  final String? daemonId;

  /// Nombre del ordenador (hostname), para el nombre por defecto en la app.
  final String? machine;
  final List<SessionInfo> sessions;
  final List<WorkspaceInfo> workspaces;

  /// IPs de la red local donde también escucha el daemon. La app las prueba
  /// antes que la de Tailscale para poder apagarlo en casa.
  final List<String> lanHosts;
  @override
  String get type => 'hello';
  @override
  Map<String, dynamic> bodyJson() => {
    'version': version,
    'sessions': [for (final s in sessions) s.toJson()],
    'workspaces': [for (final w in workspaces) w.toJson()],
    if (lanHosts.isNotEmpty) 'lanHosts': lanHosts,
    if (daemonId != null) 'daemonId': daemonId,
    if (machine != null) 'machine': machine,
  };
}

/// type "sessions": lista completa de sesiones y workspaces (reemplaza a la
/// anterior).
final class SessionsMessage extends ServerMessage {
  const SessionsMessage({this.sessions = const [], this.workspaces = const []});
  final List<SessionInfo> sessions;
  final List<WorkspaceInfo> workspaces;
  @override
  String get type => 'sessions';
  @override
  Map<String, dynamic> bodyJson() => {
    'sessions': [for (final s in sessions) s.toJson()],
    'workspaces': [for (final w in workspaces) w.toJson()],
  };
}

/// type "backlog": items de una sesión en orden de seq ascendente.
/// [cursor] es el seq del item más antiguo devuelto (pasarlo como `before`
/// para paginar hacia atrás); [hasMore] indica si hay items anteriores.
final class BacklogMessage extends ServerMessage {
  const BacklogMessage({
    required this.sessionId,
    this.items = const [],
    this.cursor = 0,
    this.hasMore = false,
    this.pending = const [],
  });
  final String sessionId;
  final List<ChatItem> items;
  final int cursor;
  final bool hasMore;

  /// Pendientes vivos de la sesión (solo en el primer backlog).
  final List<Pending> pending;
  @override
  String get type => 'backlog';
  @override
  Map<String, dynamic> bodyJson() => {
    'sessionId': sessionId,
    'items': [for (final i in items) i.toJson()],
    'cursor': cursor,
    'hasMore': hasMore,
    'pending': [for (final p in pending) p.toJson()],
  };
}

/// type "item.append": item nuevo.
final class ItemAppendMessage extends ServerMessage {
  const ItemAppendMessage({required this.item});
  final ChatItem item;
  @override
  String get type => 'item.append';
  @override
  Map<String, dynamic> bodyJson() => {'item': item.toJson()};
}

/// type "item.update": item existente (mismo id) con cambios.
final class ItemUpdateMessage extends ServerMessage {
  const ItemUpdateMessage({required this.item});
  final ChatItem item;
  @override
  String get type => 'item.update';
  @override
  Map<String, dynamic> bodyJson() => {'item': item.toJson()};
}

/// type "status": cambio de estado de una sesión.
final class StatusMessage extends ServerMessage {
  const StatusMessage({
    required this.sessionId,
    required this.status,
    this.lastSeq,
  });
  final String sessionId;
  final SessionStatus status;

  /// Último seq de la sesión en ese momento (para marcar «sin leer»).
  final int? lastSeq;
  @override
  String get type => 'status';
  @override
  Map<String, dynamic> bodyJson() => {
    'sessionId': sessionId,
    'status': status.name,
    if (lastSeq != null) 'lastSeq': lastSeq,
  };
}

/// type "seen": la sesión se ha visto hasta [seq] en el PC o en otra app.
final class SeenMessage extends ServerMessage {
  const SeenMessage({required this.sessionId, required this.seq});
  final String sessionId;
  final int seq;
  @override
  String get type => 'seen';
  @override
  Map<String, dynamic> bodyJson() => {'sessionId': sessionId, 'seq': seq};
}

/// type "pending": permiso, pregunta o plan que espera respuesta.
final class PendingMessage extends ServerMessage {
  const PendingMessage({required this.pending});
  final Pending pending;
  @override
  String get type => 'pending';
  @override
  Map<String, dynamic> bodyJson() => {'pending': pending.toJson()};
}

/// type "pending.resolved": [resolution] es un valor de [Resolution].
final class PendingResolvedMessage extends ServerMessage {
  const PendingResolvedMessage({
    required this.requestId,
    required this.sessionId,
    required this.resolution,
  });
  final String requestId;
  final String sessionId;
  final String resolution;
  @override
  String get type => 'pending.resolved';
  @override
  Map<String, dynamic> bodyJson() => {
    'requestId': requestId,
    'sessionId': sessionId,
    'resolution': resolution,
  };
}

/// type "error": [code] es un valor de [ErrorCode]; [message] es legible (español).
final class ErrorMessage extends ServerMessage {
  const ErrorMessage({
    required this.code,
    required this.message,
    this.requestId,
  });
  final String code;
  final String message;

  /// Id de la petición que falló, si aplica (requestId o sessionId según el caso).
  final String? requestId;
  @override
  String get type => 'error';
  @override
  Map<String, dynamic> bodyJson() => {
    'code': code,
    'message': message,
    'requestId': requestId,
  };
}

// --------------------------------------------------------------------- app

/// type "auth": primer mensaje si no se usó ?token= en la URL.
final class AuthMessage extends ClientMessage {
  const AuthMessage({required this.token});
  final String token;
  @override
  String get type => 'auth';
  @override
  Map<String, dynamic> bodyJson() => {'token': token};
}

/// type "subscribe": pide backlog y directo; con [before] pagina hacia atrás
/// (items con seq menor).
final class SubscribeMessage extends ClientMessage {
  const SubscribeMessage({required this.sessionId, this.before, this.limit});
  final String sessionId;
  final int? before;
  final int? limit;
  @override
  String get type => 'subscribe';
  @override
  Map<String, dynamic> bodyJson() => {
    'sessionId': sessionId,
    'before': before,
    'limit': limit,
  };
}

/// type "unsubscribe".
final class UnsubscribeMessage extends ClientMessage {
  const UnsubscribeMessage({required this.sessionId});
  final String sessionId;
  @override
  String get type => 'unsubscribe';
  @override
  Map<String, dynamic> bodyJson() => {'sessionId': sessionId};
}

/// Imagen adjunta a un prompt, en base64.
final class PromptImage {
  const PromptImage({required this.mime, required this.data});

  /// `image/png`, `image/jpeg`, `image/webp` o `image/gif`.
  final String mime;

  /// Bytes en base64 (sin prefijo `data:`).
  final String data;

  factory PromptImage.fromJson(Map<String, dynamic> j) =>
      PromptImage(mime: j['mime'] as String, data: j['data'] as String);

  Map<String, dynamic> toJson() => {'mime': mime, 'data': data};
}

/// type "prompt": envía texto a la sesión (agent.prompt). Las imágenes las
/// guarda el daemon en disco y añade sus rutas al texto para que Claude las
/// lea; con imágenes el texto puede ir vacío.
final class PromptMessage extends ClientMessage {
  const PromptMessage({
    required this.sessionId,
    required this.text,
    this.images = const [],
  });
  final String sessionId;
  final String text;
  final List<PromptImage> images;
  @override
  String get type => 'prompt';
  @override
  Map<String, dynamic> bodyJson() => {
    'sessionId': sessionId,
    'text': text,
    if (images.isNotEmpty) 'images': [for (final i in images) i.toJson()],
  };
}

/// type "interrupt": Escape en el pane.
final class InterruptMessage extends ClientMessage {
  const InterruptMessage({required this.sessionId});
  final String sessionId;
  @override
  String get type => 'interrupt';
  @override
  Map<String, dynamic> bodyJson() => {'sessionId': sessionId};
}

/// type "permission": respuesta a un permiso o plan.
final class PermissionMessage extends ClientMessage {
  const PermissionMessage({
    required this.requestId,
    required this.allow,
    this.always = false,
    this.message,
  });
  final String requestId;
  final bool allow;

  /// "Permitir siempre" (usa permission_suggestions).
  final bool always;

  /// Motivo al denegar (feedback para Claude).
  final String? message;
  @override
  String get type => 'permission';
  @override
  Map<String, dynamic> bodyJson() => {
    'requestId': requestId,
    'allow': allow,
    'always': always,
    'message': message,
  };
}

/// type "answer": respuesta a AskUserQuestion, texto de pregunta a respuesta
/// (multiSelect: etiquetas unidas por ", ").
final class AnswerMessage extends ClientMessage {
  const AnswerMessage({required this.requestId, required this.answers});
  final String requestId;
  final Map<String, String> answers;
  @override
  String get type => 'answer';
  @override
  Map<String, dynamic> bodyJson() => {
    'requestId': requestId,
    'answers': answers,
  };
}

/// type "release": "contestar en el PC", el hook vuelve vacío.
final class ReleaseMessage extends ClientMessage {
  const ReleaseMessage({required this.requestId});
  final String requestId;
  @override
  String get type => 'release';
  @override
  Map<String, dynamic> bodyJson() => {'requestId': requestId};
}

/// type "mark_seen": el chat está abierto en el móvil y se ha visto hasta
/// [seq]. El daemon lo apunta y, si herdr la tiene como terminada sin ver,
/// la marca vista también en el PC.
final class MarkSeenMessage extends ClientMessage {
  const MarkSeenMessage({required this.sessionId, required this.seq});
  final String sessionId;
  final int seq;
  @override
  String get type => 'mark_seen';
  @override
  Map<String, dynamic> bodyJson() => {'sessionId': sessionId, 'seq': seq};
}

/// type "ping" (app a servidor, el servidor responde pong).
final class PingMessage extends ClientMessage {
  const PingMessage();
  @override
  String get type => 'ping';
  @override
  Map<String, dynamic> bodyJson() => const {};
}

/// type "push_register": endpoint de UnifiedPush del móvil. El daemon lo
/// guarda y publica ahí los avisos cuando no hay app conectada.
/// [previous] es el endpoint anterior de este móvil, que se olvida.
final class PushRegisterMessage extends ClientMessage {
  const PushRegisterMessage({required this.endpoint, this.previous});
  final String endpoint;
  final String? previous;
  @override
  String get type => 'push_register';
  @override
  Map<String, dynamic> bodyJson() => {
    'endpoint': endpoint,
    'previous': previous,
  };
}

/// type "push_unregister": el móvil ya no recibe en [endpoint].
final class PushUnregisterMessage extends ClientMessage {
  const PushUnregisterMessage({required this.endpoint});
  final String endpoint;
  @override
  String get type => 'push_unregister';
  @override
  Map<String, dynamic> bodyJson() => {'endpoint': endpoint};
}

/// type "open_session": abre una sesión de Claude en el workspace
/// [workspaceId] de herdr, en una tab nueva. Con [branch] crea antes un
/// worktree de ese repo (desde [base], o la rama actual si es null) y la abre
/// ahí. [prompt], si viene, se envía en cuanto Claude está listo. [opId] lo
/// elige la app y vuelve en [SessionOpenedMessage] o en el `requestId` del
/// error.
final class OpenSessionMessage extends ClientMessage {
  const OpenSessionMessage({
    required this.opId,
    required this.workspaceId,
    this.branch,
    this.base,
    this.prompt,
  });
  final String opId;
  final String workspaceId;
  final String? branch;
  final String? base;
  final String? prompt;
  @override
  String get type => 'open_session';
  @override
  Map<String, dynamic> bodyJson() => {
    'opId': opId,
    'workspaceId': workspaceId,
    'branch': branch,
    'base': base,
    'prompt': prompt,
  };
}

/// type "close_session": cierra el pane de la sesión (y Claude con él).
final class CloseSessionMessage extends ClientMessage {
  const CloseSessionMessage({required this.sessionId});
  final String sessionId;
  @override
  String get type => 'close_session';
  @override
  Map<String, dynamic> bodyJson() => {'sessionId': sessionId};
}

/// type "remove_worktree": quita el worktree del workspace [workspaceId]
/// (cierra su workspace y borra el checkout). Nunca fuerza: si hay cambios
/// sin commitear, herdr lo rechaza y llega un error.
final class RemoveWorktreeMessage extends ClientMessage {
  const RemoveWorktreeMessage({required this.workspaceId});
  final String workspaceId;
  @override
  String get type => 'remove_worktree';
  @override
  Map<String, dynamic> bodyJson() => {'workspaceId': workspaceId};
}

/// type "session_opened": Claude ya corre en [paneId]; su sesión aparecerá en
/// la lista con ese pane.
final class SessionOpenedMessage extends ServerMessage {
  const SessionOpenedMessage({
    required this.opId,
    required this.paneId,
    required this.workspaceId,
  });
  final String opId;
  final String paneId;
  final String workspaceId;
  @override
  String get type => 'session_opened';
  @override
  Map<String, dynamic> bodyJson() => {
    'opId': opId,
    'paneId': paneId,
    'workspaceId': workspaceId,
  };
}

/// type "pong" (respuesta del servidor a ping).
final class PongMessage extends ServerMessage {
  const PongMessage();
  @override
  String get type => 'pong';
  @override
  Map<String, dynamic> bodyJson() => const {};
}

/// Mensaje de tipo desconocido (versión más nueva del otro extremo).
final class UnknownMessage extends Message {
  const UnknownMessage({required this.rawType, required this.raw});
  final String rawType;
  final Map<String, dynamic> raw;
  @override
  String get type => rawType;
  @override
  Map<String, dynamic> toJson() => raw;
  @override
  Map<String, dynamic> bodyJson() => const {};
}

// --------------------------------------------------------------- decodificar

List<ChatItem> _items(Object? v) => asList(v, ChatItem.fromJson);
Map<String, String> _strMap(Object? v) => v is Map
    ? {for (final e in v.entries) '${e.key}': '${e.value}'}
    : <String, String>{};

Message? _decode(Map<String, dynamic> j) {
  switch (j['type']) {
    case 'hello':
      return HelloMessage(
        version: (j['version'] as num?)?.toInt() ?? legacyProtocolVersion,
        sessions: asList(j['sessions'], SessionInfo.fromJson),
        workspaces: asList(j['workspaces'], WorkspaceInfo.fromJson),
        lanHosts: [
          if (j['lanHosts'] case final List<dynamic> l)
            for (final h in l)
              if (h is String && h.isNotEmpty) h,
        ],
        daemonId: j['daemonId'] as String?,
        machine: j['machine'] as String?,
      );
    case 'sessions':
      return SessionsMessage(
        sessions: asList(j['sessions'], SessionInfo.fromJson),
        workspaces: asList(j['workspaces'], WorkspaceInfo.fromJson),
      );
    case 'backlog':
      return BacklogMessage(
        sessionId: j['sessionId'] as String,
        items: _items(j['items']),
        cursor: (j['cursor'] as num?)?.toInt() ?? 0,
        hasMore: j['hasMore'] as bool? ?? false,
        pending: asList(j['pending'], Pending.fromJson),
      );
    case 'item.append':
      return ItemAppendMessage(item: ChatItem.fromJson(asMap(j['item'])));
    case 'item.update':
      return ItemUpdateMessage(item: ChatItem.fromJson(asMap(j['item'])));
    case 'status':
      return StatusMessage(
        sessionId: j['sessionId'] as String,
        status: SessionStatus.parse(j['status']),
        lastSeq: (j['lastSeq'] as num?)?.toInt(),
      );
    case 'seen':
      return SeenMessage(
        sessionId: j['sessionId'] as String,
        seq: (j['seq'] as num).toInt(),
      );
    case 'mark_seen':
      return MarkSeenMessage(
        sessionId: j['sessionId'] as String,
        seq: (j['seq'] as num).toInt(),
      );
    case 'pending':
      return PendingMessage(pending: Pending.fromJson(asMap(j['pending'])));
    case 'pending.resolved':
      return PendingResolvedMessage(
        requestId: j['requestId'] as String,
        sessionId: j['sessionId'] as String? ?? '',
        resolution: j['resolution'] as String? ?? Resolution.cancelled,
      );
    case 'error':
      return ErrorMessage(
        code: j['code'] as String? ?? ErrorCode.internal,
        message: j['message'] as String? ?? '',
        requestId: j['requestId'] as String?,
      );
    case 'pong':
      return const PongMessage();
    case 'auth':
      return AuthMessage(token: j['token'] as String);
    case 'subscribe':
      return SubscribeMessage(
        sessionId: j['sessionId'] as String,
        before: (j['before'] as num?)?.toInt(),
        limit: (j['limit'] as num?)?.toInt(),
      );
    case 'unsubscribe':
      return UnsubscribeMessage(sessionId: j['sessionId'] as String);
    case 'prompt':
      return PromptMessage(
        sessionId: j['sessionId'] as String,
        text: j['text'] as String,
        images: [
          for (final i in (j['images'] as List? ?? const []))
            PromptImage.fromJson((i as Map).cast<String, dynamic>()),
        ],
      );
    case 'interrupt':
      return InterruptMessage(sessionId: j['sessionId'] as String);
    case 'permission':
      return PermissionMessage(
        requestId: j['requestId'] as String,
        allow: j['allow'] as bool,
        always: j['always'] as bool? ?? false,
        message: j['message'] as String?,
      );
    case 'answer':
      return AnswerMessage(
        requestId: j['requestId'] as String,
        answers: _strMap(j['answers']),
      );
    case 'release':
      return ReleaseMessage(requestId: j['requestId'] as String);
    case 'ping':
      return const PingMessage();
    case 'push_register':
      return PushRegisterMessage(
        endpoint: j['endpoint'] as String,
        previous: j['previous'] as String?,
      );
    case 'push_unregister':
      return PushUnregisterMessage(endpoint: j['endpoint'] as String);
    case 'open_session':
      return OpenSessionMessage(
        opId: j['opId'] as String,
        workspaceId: j['workspaceId'] as String,
        branch: j['branch'] as String?,
        base: j['base'] as String?,
        prompt: j['prompt'] as String?,
      );
    case 'close_session':
      return CloseSessionMessage(sessionId: j['sessionId'] as String);
    case 'remove_worktree':
      return RemoveWorktreeMessage(workspaceId: j['workspaceId'] as String);
    case 'session_opened':
      return SessionOpenedMessage(
        opId: j['opId'] as String,
        paneId: j['paneId'] as String,
        workspaceId: j['workspaceId'] as String? ?? '',
      );
  }
  return null;
}
