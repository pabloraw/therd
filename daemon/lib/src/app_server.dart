import 'dart:async';
import 'dart:io';

import 'package:therd_protocol/protocol.dart';

import 'herdr_client.dart';
import 'images.dart';
import 'hook_server.dart';
import 'log.dart';
import 'pending.dart';
import 'push_registry.dart';
import 'seen_sync.dart';
import 'session_store.dart';
import 'uploads.dart';

class _Client {
  _Client(this.ws);
  final WebSocket ws;
  bool authed = false;
  final Set<String> subs = {};
  Timer? authTimer;
}

/// WebSocket para las apps: autenticado por token, protocolo de therd_protocol.
class AppServer {
  AppServer({
    required this.token,
    required this.store,
    required this.pendings,
    required this.herdr,
    this.host = '127.0.0.1',
    this.port = 24601,
    this.authTimeout = const Duration(seconds: 10),
    this.interruptDelay = const Duration(milliseconds: 300),
    this.push,
    this.seen,
    this.uploads,
    this.images,
    this.maxPreAuthBytes = 64 << 10,
    this.maxMessageBytes = defaultMaxMessageBytes,
  });

  /// 4 imágenes de 15 MB en base64 (4/3) más margen para el JSON.
  static const defaultMaxMessageBytes = 4 * (15 << 20) * 4 ~/ 3 + (1 << 20);

  /// Tope por mensaje mientras el cliente no se ha autenticado.
  final int maxPreAuthBytes;

  /// Tope por mensaje de un cliente autenticado.
  final int maxMessageBytes;

  /// Imágenes de los transcripts, servidas en `GET /images/<id>`.
  final ImageStore? images;

  /// Dónde se guardan las imágenes de los prompts; null = no se aceptan.
  final Uploads? uploads;

  /// Lleva lo leído en las apps al PC; null = solo se apunta en el store.
  final SeenSync? seen;

  /// Endpoints de UnifiedPush; null = el daemon no acepta registros.
  final PushRegistry? push;

  final String token;
  final SessionStore store;
  final PendingManager pendings;
  final HerdrClient herdr;
  final String host;
  int port;
  final Duration authTimeout;
  final Duration interruptDelay;

  HttpServer? _server;
  final Set<_Client> _clients = {};
  final List<StreamSubscription<Object?>> _subs = [];

  /// Apps conectadas y autenticadas.
  int get clientCount => _clients.where((c) => c.authed).length;

  Future<void> start() async {
    final s = await HttpServer.bind(host, port);
    _server = s;
    port = s.port;
    s.listen(_onRequest);
    _subs.add(store.events.listen(_onStoreEvent));
    _subs.add(pendings.events.listen(_onPendingEvent));
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final c in _clients.toList()) {
      c.authTimer?.cancel();
      await c.ws.close(WebSocketStatus.goingAway, 'servidor detenido');
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  // ---------------------------------------------------------- conexiones

  /// `GET /images/<id>`: miniatura para el chat, o el original con `?full=1`.
  /// Autenticado con el mismo token que el WebSocket.
  Future<void> _serveImage(HttpRequest req) async {
    final res = req.response;
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final given = auth != null && auth.startsWith('Bearer ')
        ? auth.substring(7)
        : req.uri.queryParameters['token'];
    if (given == null || !tokenEquals(given, token)) {
      res.statusCode = HttpStatus.unauthorized;
      return res.close();
    }
    final store = images;
    final id = req.uri.pathSegments.length == 2 ? req.uri.pathSegments[1] : '';
    final File? f;
    if (store == null) {
      f = null;
    } else if (req.uri.queryParameters['full'] == '1') {
      f = store.file(id);
    } else {
      f = await store.thumb(id);
    }
    if (f == null) {
      res.statusCode = HttpStatus.notFound;
      return res.close();
    }
    final mime = f.path.endsWith('.jpeg')
        ? 'image/jpeg'
        : ImageStore.mimeOf(id);
    res.headers
      ..contentType = ContentType.parse(mime)
      ..set(
        HttpHeaders.cacheControlHeader,
        'private, max-age=31536000, immutable',
      );
    try {
      await res.addStream(f.openRead());
    } on FileSystemException {
      // Borrada entre medias: la conexión se corta.
    }
    await res.close();
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (req.method == 'GET' && req.uri.path.startsWith('/images/')) {
      return _serveImage(req);
    }
    if (!WebSocketTransformer.isUpgradeRequest(req) ||
        (req.uri.path != '/' && req.uri.path != '/ws')) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (_) {
      return;
    }
    ws.pingInterval = const Duration(seconds: 20);
    final c = _Client(ws);
    _clients.add(c);

    ws.listen(
      (data) {
        if (data is! String) {
          _error(c, ErrorCode.badRequest, 'Solo se admiten mensajes de texto.');
          return;
        }
        if (data.length > (c.authed ? maxMessageBytes : maxPreAuthBytes)) {
          Log.info('mensaje de app demasiado grande (${data.length} B)');
          c.ws.close(
            WebSocketStatus.policyViolation,
            'mensaje demasiado grande',
          );
          return;
        }
        try {
          _onMessage(c, decodeMessage(data));
        } catch (e, st) {
          Log.error('app', e, st);
          _error(c, ErrorCode.internal, 'Error interno del servidor.');
        }
      },
      onDone: () => _onClosed(c),
      onError: (_) => _onClosed(c),
      cancelOnError: true,
    );

    final qt = req.uri.queryParameters['token'];
    if (qt != null) {
      if (tokenEquals(qt, token)) {
        _authenticate(c);
      } else {
        _reject(c);
      }
    } else {
      c.authTimer = Timer(authTimeout, () => _reject(c));
    }
  }

  void _reject(_Client c) {
    _error(c, ErrorCode.unauthorized, 'Token no válido.');
    c.ws.close(WebSocketStatus.policyViolation, 'unauthorized');
  }

  void _authenticate(_Client c) {
    c.authTimer?.cancel();
    c.authed = true;
    _send(
      c,
      HelloMessage(
        version: protocolVersion,
        sessions: store.sessions,
        workspaces: store.workspaces,
      ),
    );
  }

  void _onClosed(_Client c) {
    c.authTimer?.cancel();
    final wasAuthed = c.authed;
    _clients.remove(c);
    if (wasAuthed && clientCount == 0) {
      // Sin apps, los hooks retenidos vuelven vacíos y el terminal pregunta.
      pendings.releaseAll();
    }
  }

  void _send(_Client c, ServerMessage m) {
    try {
      c.ws.add(m.encode());
    } catch (_) {
      // conexión caída; _onClosed limpia
    }
  }

  void _error(_Client c, String code, String message, {String? requestId}) =>
      _send(
        c,
        ErrorMessage(code: code, message: message, requestId: requestId),
      );

  void _broadcast(ServerMessage m) {
    for (final c in _clients.where((c) => c.authed)) {
      _send(c, m);
    }
  }

  // ------------------------------------------------------------ mensajes

  void _onMessage(_Client c, Message m) {
    if (!c.authed) {
      if (m is AuthMessage && tokenEquals(m.token, token)) {
        _authenticate(c);
      } else {
        _reject(c);
      }
      return;
    }
    switch (m) {
      case AuthMessage():
        break; // ya autenticado
      case SubscribeMessage():
        _subscribe(c, m);
      case UnsubscribeMessage():
        c.subs.remove(m.sessionId);
      case PromptMessage():
        unawaited(_prompt(c, m));
      case InterruptMessage():
        unawaited(_interrupt(c, m));
      case PermissionMessage():
        final ok = pendings.respondPermission(
          m.requestId,
          allow: m.allow,
          always: m.always,
          message: m.message,
        );
        if (!ok) _unknownRequest(c, m.requestId);
      case AnswerMessage():
        if (!pendings.respondAnswer(m.requestId, m.answers)) {
          _unknownRequest(c, m.requestId);
        }
      case ReleaseMessage():
        if (!pendings.release(m.requestId)) _unknownRequest(c, m.requestId);
      case PingMessage():
        _send(c, const PongMessage());
      case PushRegisterMessage():
        final reg = push;
        if (reg != null && !reg.register(m.endpoint, previous: m.previous)) {
          _error(c, ErrorCode.badRequest, 'Endpoint de avisos no válido.');
        }
      case PushUnregisterMessage():
        push?.unregister(m.endpoint);
      case MarkSeenMessage():
        final sync = seen;
        if (sync != null) {
          sync.fromApp(m.sessionId, m.seq);
        } else {
          store.markSeen(m.sessionId, m.seq);
        }
      case ServerMessage():
        _error(c, ErrorCode.badRequest, 'Mensaje no válido para un cliente.');
      case UnknownMessage():
        _error(c, ErrorCode.badRequest, 'Mensaje desconocido: "${m.rawType}".');
    }
  }

  void _unknownRequest(_Client c, String requestId) => _error(
    c,
    ErrorCode.unknownRequest,
    'Esa petición ya no está pendiente (se contestó, expiró o se canceló).',
    requestId: requestId,
  );

  void _subscribe(_Client c, SubscribeMessage m) {
    if (!store.has(m.sessionId)) {
      _error(c, ErrorCode.unknownSession, 'La sesión ya no existe.');
      return;
    }
    c.subs.add(m.sessionId);
    final page = store.backlog(
      m.sessionId,
      before: m.before,
      limit: m.limit ?? 100,
    );
    _send(
      c,
      BacklogMessage(
        sessionId: m.sessionId,
        items: page.items,
        cursor: page.cursor,
        hasMore: page.hasMore,
        pending: m.before == null ? pendings.forSession(m.sessionId) : const [],
      ),
    );
  }

  Future<void> _prompt(_Client c, PromptMessage m) async {
    final info = store.info(m.sessionId);
    if (info == null) {
      return _error(c, ErrorCode.unknownSession, 'La sesión ya no existe.');
    }
    if (m.text.trim().isEmpty && m.images.isEmpty) {
      return _error(c, ErrorCode.badRequest, 'El mensaje está vacío.');
    }
    final pane = info.paneId;
    if (pane == null) {
      return _error(
        c,
        ErrorCode.badRequest,
        'Esta sesión no corre en herdr, no se le puede escribir desde la app.',
      );
    }
    var text = m.text;
    if (m.images.isNotEmpty) {
      final up = uploads;
      if (up == null) {
        return _error(
          c,
          ErrorCode.badRequest,
          'Este daemon no acepta imágenes.',
        );
      }
      try {
        text = promptWithImages(text, await up.save(m.images));
      } on UploadException catch (e) {
        return _error(c, ErrorCode.badRequest, e.message);
      } on FileSystemException catch (e) {
        Log.error('no se pudo guardar una imagen', e);
        return _error(
          c,
          ErrorCode.internal,
          'No se pudo guardar la imagen en el PC.',
        );
      }
    }
    try {
      await herdr.prompt(pane, text);
    } on HerdrException catch (e) {
      _herdrError(c, e);
    }
  }

  Future<void> _interrupt(_Client c, InterruptMessage m) async {
    final info = store.info(m.sessionId);
    if (info == null) {
      return _error(c, ErrorCode.unknownSession, 'La sesión ya no existe.');
    }
    final pane = info.paneId;
    if (pane == null) {
      return _error(
        c,
        ErrorCode.badRequest,
        'Esta sesión no corre en herdr, no se puede interrumpir desde la app.',
      );
    }
    // Un pendiente retenido se libera antes: el diálogo del terminal sale y
    // Escape lo descarta junto con el turno.
    final open = pendings.forSession(m.sessionId);
    for (final p in open) {
      pendings.release(p.requestId);
    }
    if (open.isNotEmpty) await Future<void>.delayed(interruptDelay);
    try {
      await herdr.sendKeys(pane, ['Escape']);
    } on HerdrException catch (e) {
      _herdrError(c, e);
    }
  }

  void _herdrError(_Client c, HerdrException e) {
    if (e.isBlocked) {
      _error(
        c,
        ErrorCode.agentBlocked,
        'Claude espera una respuesta en el terminal. Contéstala antes de enviar un mensaje.',
      );
    } else if (e.isUnavailable) {
      _error(
        c,
        ErrorCode.herdrUnavailable,
        'No se puede hablar con herdr. Comprueba que esté en marcha.',
      );
    } else {
      _error(
        c,
        ErrorCode.internal,
        'herdr respondió con un error: ${e.message}',
      );
    }
  }

  // ------------------------------------------------------------- eventos

  void _onStoreEvent(StoreEvent e) {
    switch (e) {
      case SessionsChanged():
        _broadcast(
          SessionsMessage(
            sessions: store.sessions,
            workspaces: store.workspaces,
          ),
        );
      case SessionRemoved():
        // La app deberá volver a suscribirse si la sesión reaparece.
        for (final c in _clients) {
          c.subs.remove(e.sessionId);
        }
      case StatusChanged():
        _broadcast(
          StatusMessage(
            sessionId: e.sessionId,
            status: e.status,
            lastSeq: store.info(e.sessionId)?.lastSeq,
          ),
        );
      case SeenChanged():
        _broadcast(SeenMessage(sessionId: e.sessionId, seq: e.seq));
      case ItemAppended():
        for (final c in _clients) {
          if (c.authed && c.subs.contains(e.item.sessionId)) {
            _send(c, ItemAppendMessage(item: e.item));
          }
        }
      case ItemUpdated():
        for (final c in _clients) {
          if (c.authed && c.subs.contains(e.item.sessionId)) {
            _send(c, ItemUpdateMessage(item: e.item));
          }
        }
    }
  }

  void _onPendingEvent(PendingEvent e) {
    switch (e) {
      case PendingOpened():
        _broadcast(PendingMessage(pending: e.pending));
      case PendingClosed():
        _broadcast(
          PendingResolvedMessage(
            requestId: e.pending.requestId,
            sessionId: e.pending.sessionId,
            resolution: e.resolution,
          ),
        );
    }
  }
}
