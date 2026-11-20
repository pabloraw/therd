import 'dart:typed_data';

import 'package:therd_protocol/protocol.dart';

import '../core/connection_config.dart';
import 'therd_client.dart';

/// Aviso transitorio (error del servidor) para mostrar en un SnackBar.
class Notice {
  const Notice(this.id, this.code, this.message);
  final int id;
  final String code;
  final String message;
}

/// Prompt enviado desde el móvil que aún no ha vuelto del transcript.
class Outgoing {
  const Outgoing({
    required this.id,
    required this.sessionId,
    required this.text,
    required this.afterSeq,
    required this.sentAt,
    this.images = const [],
  });

  /// Ids locales de las imágenes adjuntas (ver `localImages`).
  final List<String> images;

  /// Id local, con el prefijo [kLocalPrefix].
  final String id;
  final String sessionId;
  final String text;

  /// Último seq del chat al enviar: solo un prompt posterior puede ser este.
  final int afterSeq;
  final DateTime sentAt;

  /// Item que se pinta mientras tanto.
  UserPromptItem get item => UserPromptItem(
    id: id,
    sessionId: sessionId,
    seq: afterSeq,
    timestamp: sentAt,
    text: text,
    images: images,
  );
}

/// Imágenes enviadas desde el móvil, por su id local, mientras el prompt no
/// vuelve del transcript con los ids del daemon.
final Map<String, Uint8List> localImages = {};

/// Prefijo de los ids de los prompts provisionales.
const kLocalPrefix = 'local:';

bool isLocalItem(ChatItem i) => i.id.startsWith(kLocalPrefix);

/// Estado del chat de una sesión: items ordenados por seq y paginación.
class ChatState {
  const ChatState({
    this.items = const [],
    this.outgoing = const [],
    this.hasMore = false,
    this.cursor,
    this.loadingOlder = false,
    this.loaded = false,
    this.awaitingInitial = false,
  });

  /// Items en orden de seq ascendente, sin ids repetidos.
  final List<ChatItem> items;

  /// Prompts enviados sin confirmar, del más antiguo al más reciente.
  final List<Outgoing> outgoing;

  /// Lo que se pinta: los items y, al final, los prompts provisionales.
  List<ChatItem> get view =>
      outgoing.isEmpty ? items : [...items, for (final o in outgoing) o.item];

  /// Hay items más antiguos que pedir con subscribe(before: cursor).
  final bool hasMore;

  /// Seq del item más antiguo conocido.
  final int? cursor;

  /// Hay una petición de histórico en curso.
  final bool loadingOlder;

  /// Ya llegó el primer backlog.
  final bool loaded;

  /// Se envió subscribe sin before y aún no llegó el backlog inicial.
  final bool awaitingInitial;

  int get lastSeq => items.isEmpty ? 0 : items.last.seq;

  ChatState copyWith({
    List<ChatItem>? items,
    List<Outgoing>? outgoing,
    bool? hasMore,
    int? cursor,
    bool? loadingOlder,
    bool? loaded,
    bool? awaitingInitial,
  }) => ChatState(
    items: items ?? this.items,
    outgoing: outgoing ?? this.outgoing,
    hasMore: hasMore ?? this.hasMore,
    cursor: cursor ?? this.cursor,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    loaded: loaded ?? this.loaded,
    awaitingInitial: awaitingInitial ?? this.awaitingInitial,
  );
}

/// Estado completo de la app (conexión, sesiones, chats y pendientes).
class AppState {
  const AppState({
    this.configLoaded = false,
    this.config,
    this.link = const LinkStatus(LinkState.disconnected),
    this.sessions = const [],
    this.workspaces = const [],
    this.seen = const {},
    this.chats = const {},
    this.pending = const {},
    this.notice,
    this.hellos = 0,
    this.opening = const {},
  });

  /// Sesiones pedidas desde el móvil que aún no se han abierto, por opId:
  /// null mientras herdr arranca Claude, y luego el pane donde corre.
  final Map<String, String?> opening;

  /// Cuántos `hello` se han recibido: permite saber si la lista de sesiones
  /// ya es fresca tras una reconexión.
  final int hellos;

  final bool configLoaded;
  final ConnectionConfig? config;
  final LinkStatus link;
  final List<SessionInfo> sessions;
  final List<WorkspaceInfo> workspaces;

  /// Último seq visto en el móvil por sesión (para «sin leer»).
  final Map<String, int> seen;

  /// Terminó algo que aún no se ha mirado ni en el móvil ni en el PC.
  bool isUnread(SessionInfo s) {
    final mine = seen[s.sessionId] ?? s.lastSeq;
    return s.lastSeq > (mine > s.seenSeq ? mine : s.seenSeq);
  }

  final Map<String, ChatState> chats;

  /// Pendientes vivos por sessionId, del más antiguo al más reciente.
  final Map<String, List<Pending>> pending;
  final Notice? notice;

  SessionInfo? session(String id) {
    for (final s in sessions) {
      if (s.sessionId == id) return s;
    }
    return null;
  }

  ChatState chat(String id) => chats[id] ?? const ChatState();

  List<Pending> pendingOf(String id) => pending[id] ?? const [];

  AppState copyWith({
    bool? configLoaded,
    ConnectionConfig? config,
    bool clearConfig = false,
    LinkStatus? link,
    List<SessionInfo>? sessions,
    List<WorkspaceInfo>? workspaces,
    Map<String, int>? seen,
    Map<String, ChatState>? chats,
    Map<String, List<Pending>>? pending,
    Notice? notice,
    int? hellos,
    Map<String, String?>? opening,
  }) => AppState(
    opening: opening ?? this.opening,
    configLoaded: configLoaded ?? this.configLoaded,
    config: clearConfig ? null : (config ?? this.config),
    link: link ?? this.link,
    sessions: sessions ?? this.sessions,
    workspaces: workspaces ?? this.workspaces,
    seen: seen ?? this.seen,
    chats: chats ?? this.chats,
    pending: pending ?? this.pending,
    notice: notice ?? this.notice,
    hellos: hellos ?? this.hellos,
  );
}

/// Mezcla [incoming] en [existing] por id (el nuevo sustituye al viejo) y
/// ordena por seq.
List<ChatItem> mergeItems(
  List<ChatItem> existing,
  Iterable<ChatItem> incoming,
) {
  final byId = <String, ChatItem>{for (final i in existing) i.id: i};
  for (final i in incoming) {
    byId[i.id] = i;
  }
  final list = byId.values.toList()
    ..sort((a, b) {
      final c = a.seq.compareTo(b.seq);
      return c != 0 ? c : a.timestamp.compareTo(b.timestamp);
    });
  return list;
}

String _norm(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Quita de [out] los prompts provisionales que ya han vuelto en [incoming].
///
/// Cada prompt del transcript posterior al envío confirma el provisional con
/// el mismo texto; si ninguno coincide (Claude Code lo reescribió), el más
/// antiguo, que es el que antes llega.
List<Outgoing> confirmOutgoing(
  List<Outgoing> out,
  Iterable<ChatItem> incoming,
) {
  if (out.isEmpty) return out;
  var left = out;
  for (final i in incoming) {
    if (i is! UserPromptItem || left.isEmpty) continue;
    final candidates = [
      for (final o in left)
        if (o.afterSeq < i.seq) o,
    ];
    if (candidates.isEmpty) continue;
    final text = _norm(i.text);
    final hit = candidates.firstWhere(
      (o) => _norm(o.text) == text,
      orElse: () => candidates.first,
    );
    left = [
      for (final o in left)
        if (o.id != hit.id) o,
    ];
  }
  return left;
}

/// Errores con los que el daemon rechaza un prompt.
const _promptErrors = {
  ErrorCode.unknownSession,
  ErrorCode.badRequest,
  ErrorCode.agentBlocked,
  ErrorCode.herdrUnavailable,
};

/// Un error justo después de enviar es el rechazo de ese prompt: se quita el
/// provisional más reciente (el aviso ya explica qué pasó).
Map<String, ChatState>? _dropRejected(AppState s, String code, DateTime now) {
  if (!_promptErrors.contains(code)) return null;
  Outgoing? newest;
  for (final c in s.chats.values) {
    for (final o in c.outgoing) {
      if (newest == null || o.sentAt.isAfter(newest.sentAt)) newest = o;
    }
  }
  if (newest == null || now.difference(newest.sentAt).inSeconds > 15) {
    return null;
  }
  final sid = newest.sessionId;
  final chat = s.chat(sid);
  return {
    ...s.chats,
    sid: chat.copyWith(
      outgoing: [
        for (final o in chat.outgoing)
          if (o.id != newest.id) o,
      ],
    ),
  };
}

/// Añade o sustituye (por requestId) un pendiente, ordenado por creación.
List<Pending> upsertPending(List<Pending> list, Pending p) {
  final out = [
    for (final x in list)
      if (x.requestId != p.requestId) x,
    p,
  ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return out;
}

/// Ajusta lo leído a las sesiones vivas: una sesión nueva para el móvil cuenta
/// como leída (no se pinta todo de azul la primera vez) y, si el daemon se
/// reinició y su seq bajó, lo visto baja con él. Las sesiones muertas se
/// olvidan.
Map<String, int> baselineSeen(Map<String, int> seen, List<SessionInfo> list) {
  final out = <String, int>{};
  for (final x in list) {
    final v = seen[x.sessionId];
    out[x.sessionId] = v == null || v > x.lastSeq ? x.lastSeq : v;
  }
  return out;
}

/// Aplica un mensaje del servidor al estado. Función pura salvo por [now],
/// que solo se usa para casar un error con el prompt recién enviado.
AppState reduce(AppState s, ServerMessage m, {DateTime? now}) {
  switch (m) {
    case HelloMessage():
      // Los pendientes vivos vuelven con el backlog inicial de cada
      // suscripción; los guardados pueden haber sido liberados sin aviso.
      return s.copyWith(
        sessions: m.sessions,
        workspaces: m.workspaces,
        seen: baselineSeen(s.seen, m.sessions),
        pending: const {},
        hellos: s.hellos + 1,
        // Una apertura en vuelo perdió su respuesta con la conexión.
        opening: const {},
      );
    case SessionsMessage():
      // Una sesión suscrita que desaparece pierde su chat y sus pendientes;
      // al reaparecer el controlador vuelve a suscribirse.
      final alive = {for (final x in m.sessions) x.sessionId};
      return s.copyWith(
        sessions: m.sessions,
        workspaces: m.workspaces,
        seen: baselineSeen(s.seen, m.sessions),
        chats: {
          for (final e in s.chats.entries)
            if (alive.contains(e.key)) e.key: e.value,
        },
        pending: {
          for (final e in s.pending.entries)
            if (alive.contains(e.key)) e.key: e.value,
        },
      );
    case StatusMessage():
      return s.copyWith(
        sessions: [
          for (final x in s.sessions)
            x.sessionId == m.sessionId
                ? x.copyWith(
                    status: m.status,
                    lastSeq: m.lastSeq != null && m.lastSeq! > x.lastSeq
                        ? m.lastSeq
                        : null,
                  )
                : x,
        ],
      );
    case SeenMessage():
      return s.copyWith(
        sessions: [
          for (final x in s.sessions)
            x.sessionId == m.sessionId && m.seq > x.seenSeq
                ? x.copyWith(seenSeq: m.seq)
                : x,
        ],
      );
    case BacklogMessage():
      return _reduceBacklog(s, m);
    case ItemAppendMessage():
      return _reduceItem(s, m.item);
    case ItemUpdateMessage():
      return _reduceItem(s, m.item);
    case PendingMessage():
      final p = m.pending;
      return s.copyWith(
        pending: {
          ...s.pending,
          p.sessionId: upsertPending(s.pendingOf(p.sessionId), p),
        },
      );
    case PendingResolvedMessage():
      final next = <String, List<Pending>>{};
      s.pending.forEach((sid, list) {
        final kept = [
          for (final p in list)
            if (p.requestId != m.requestId) p,
        ];
        if (kept.isNotEmpty) next[sid] = kept;
      });
      return s.copyWith(pending: next);
    case SessionOpenedMessage():
      if (!s.opening.containsKey(m.opId)) return s;
      return s.copyWith(opening: {...s.opening, m.opId: m.paneId});
    case ErrorMessage() when s.opening.containsKey(m.requestId):
      return s.copyWith(
        opening: {...s.opening}..remove(m.requestId),
        notice: Notice((s.notice?.id ?? 0) + 1, m.code, m.message),
      );
    case ErrorMessage():
      // unknown_session no trae backlog ni sessionId: se liberan las esperas.
      final released = m.code == ErrorCode.unknownSession
          ? {
              for (final e in s.chats.entries)
                e.key: e.value.copyWith(
                  loadingOlder: false,
                  awaitingInitial: false,
                ),
            }
          : null;
      final withReleased = released == null ? s : s.copyWith(chats: released);
      final rejected = _dropRejected(
        withReleased,
        m.code,
        now ?? DateTime.now(),
      );
      return s.copyWith(
        chats: rejected ?? released,
        notice: Notice((s.notice?.id ?? 0) + 1, m.code, m.message),
      );
    case PongMessage():
      return s;
  }
}

AppState _reduceItem(AppState s, ChatItem item) {
  final sid = item.sessionId;
  // Sesión sin suscripción: no hay backlog sobre el que mezclar.
  final chat = s.chats[sid];
  var next = s;
  if (chat != null) {
    next = next.copyWith(
      chats: {
        ...s.chats,
        sid: chat.copyWith(
          items: mergeItems(chat.items, [item]),
          outgoing: confirmOutgoing(chat.outgoing, [item]),
        ),
      },
    );
  }
  return next.copyWith(
    sessions: [
      for (final x in next.sessions)
        x.sessionId == sid && item.seq > x.lastSeq
            ? x.copyWith(lastSeq: item.seq)
            : x,
    ],
  );
}

AppState _reduceBacklog(AppState s, BacklogMessage m) {
  final old = s.chats[m.sessionId] ?? const ChatState();
  final ChatState chat;
  if (old.loadingOlder) {
    // Página de histórico pedida con before.
    chat = old.copyWith(
      items: mergeItems(old.items, m.items),
      cursor: m.items.isEmpty ? old.cursor : m.cursor,
      hasMore: m.hasMore,
      loadingOlder: false,
      loaded: true,
    );
    return s.copyWith(chats: {...s.chats, m.sessionId: chat});
  } else {
    final hadItems = old.items.isNotEmpty;
    final gap = hadItems && m.items.isNotEmpty && m.cursor > old.lastSeq + 1;
    final daemonReset =
        hadItems && m.items.isNotEmpty && m.items.last.seq < old.lastSeq;
    if (!hadItems || gap || daemonReset) {
      chat = ChatState(
        items: mergeItems(const [], m.items),
        // Con los seq del daemon reiniciado ya no se puede casar nada.
        outgoing: daemonReset
            ? const []
            : confirmOutgoing(old.outgoing, m.items),
        hasMore: m.hasMore,
        cursor: m.items.isEmpty ? null : m.cursor,
        loaded: true,
      );
    } else {
      // Reconexión sin hueco: se conserva el histórico ya cargado.
      final oldest = old.items.first.seq;
      final extendsBack = m.items.isNotEmpty && m.cursor <= oldest;
      chat = old.copyWith(
        items: mergeItems(old.items, m.items),
        outgoing: confirmOutgoing(old.outgoing, m.items),
        cursor: extendsBack ? m.cursor : old.cursor,
        hasMore: extendsBack ? m.hasMore : old.hasMore,
        loaded: true,
        awaitingInitial: false,
      );
    }
    // Solo el backlog inicial trae los pendientes vivos.
    return s.copyWith(
      chats: {...s.chats, m.sessionId: chat},
      pending: {...s.pending, m.sessionId: m.pending}
        ..removeWhere((_, v) => v.isEmpty),
    );
  }
}
