import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hook_event.dart';
import 'log.dart';
import 'pending.dart';

/// Lógica que el HookServer delega: espejo de eventos y retención de hooks.
abstract class HookHandler {
  /// ¿Hay alguna app conectada? Sin ninguna, los hooks bloqueantes devuelven
  /// 204 al instante y el diálogo sale en el terminal.
  bool get hasClients;

  /// Evento de solo espejo (ya se respondió 204).
  void onEvent(HookEvent e);

  /// Crea el pendiente de un evento retenible. Null = no retener (204).
  Future<PendingHandle?> hold(HookEvent e);
}

/// Comparación en tiempo constante.
bool tokenEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Servidor HTTP de hooks de Claude Code: `POST /hook` en loopback.
class HookServer {
  HookServer({
    required this.token,
    required this.handler,
    this.host = '127.0.0.1',
    this.port = 24600,
  });

  final String token;
  final HookHandler handler;
  final String host;
  int port;

  HttpServer? _server;

  Future<void> start() async {
    final s = await HttpServer.bind(host, port);
    _server = s;
    port = s.port;
    s.listen(
      (req) => _handle(req).catchError((Object e, StackTrace st) {
        Log.error('hook', e, st);
      }),
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _reply(HttpRequest req, int code, [String? text]) async {
    req.response.statusCode = code;
    if (text != null) req.response.write(text);
    await req.response.close();
  }

  static bool _hostIsLoopback(String? host) {
    if (host == null) return false;
    var name = host.trim().toLowerCase();
    if (name.startsWith('[')) {
      final end = name.indexOf(']');
      if (end < 0) return false;
      name = name.substring(1, end);
    } else {
      final colon = name.indexOf(':');
      if (colon >= 0) name = name.substring(0, colon);
    }
    return name == '127.0.0.1' || name == 'localhost' || name == '::1';
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path != '/hook') return _reply(req, 404);
    if (req.method != 'POST') return _reply(req, 405);
    // Claude Code manda los hooks desde su proceso: sin Origin ni Sec-Fetch-*.
    // Un navegador los pone siempre en un POST cross-origin (también con
    // fetch no-cors), así que su presencia delata a una página web.
    final h = req.headers;
    if (h.value('origin') != null ||
        h.value('sec-fetch-site') != null ||
        h.value('sec-fetch-mode') != null) {
      return _reply(req, 403, 'forbidden');
    }
    // Contra DNS rebinding: el Host debe ser un loopback literal.
    if (!_hostIsLoopback(h.value('host'))) return _reply(req, 403, 'forbidden');
    // Solo escuchamos en 127.0.0.1: un hook sin token (Claude lanzado sin
    // THERD_TOKEN en su entorno manda «Bearer » vacío) se acepta, porque si
    // no therd quedaría ciego en esas sesiones. Un token presente y distinto
    // sí se rechaza.
    final auth = (req.headers.value('authorization') ?? '').trim();
    final given = auth.startsWith('Bearer') ? auth.substring(6).trim() : auth;
    if (given.isNotEmpty && !tokenEquals(given, token)) {
      return _reply(req, 401, 'unauthorized');
    }

    Map<String, dynamic> json;
    try {
      final body = await utf8.decoder
          .bind(req)
          .join()
          .timeout(const Duration(seconds: 5));
      final v = jsonDecode(body);
      if (v is! Map) throw const FormatException('no es un objeto');
      json = Map<String, dynamic>.from(v);
    } catch (_) {
      return _reply(req, 400, 'bad request');
    }
    final event = HookEvent.fromJson(
      json,
      paneId: req.headers.value('x-herdr-pane'),
    );

    if (event.name == 'Notification' ||
        event.toolName == 'ExitPlanMode' ||
        event.toolName == 'AskUserQuestion') {
      Log.info(
        'hook ${event.name} ${event.toolName ?? event.raw['notification_type'] ?? ''}',
      );
    }
    if (event.isHoldable) {
      final who =
          '${event.name} ${event.toolName ?? ''} '
          '(${event.sessionId.length > 8 ? event.sessionId.substring(0, 8) : event.sessionId})';
      if (handler.hasClients) {
        Log.info('retengo $who');
        return _hold(req, event);
      }
      Log.info('no retengo $who: no hay app conectada');
    } else if (event.name == 'PermissionRequest') {
      Log.info('PermissionRequest ${event.toolName ?? ''} no retenible');
    }
    await _reply(req, 204);
    try {
      handler.onEvent(event);
    } catch (e, st) {
      Log.error('hook ${event.name}', e, st);
    }
  }

  /// Retiene la conexión: se detecta si el hook cuelga (Claude canceló o se
  /// contestó en el terminal) y se responde cuando hay decisión.
  Future<void> _hold(HttpRequest req, HookEvent event) async {
    final socket = await req.response.detachSocket(writeHeaders: false);
    var gone = false;
    PendingHandle? handle;
    void onGone() {
      gone = true;
      handle?.cancel();
    }

    socket.listen(
      (_) {},
      onDone: onGone,
      onError: (_) => onGone(),
      cancelOnError: true,
    );

    Future<void> write(int code, [Map<String, dynamic>? body]) async {
      if (gone) return;
      try {
        if (body == null) {
          socket.write(
            'HTTP/1.1 $code No Content\r\nConnection: close\r\n\r\n',
          );
        } else {
          final bytes = utf8.encode(jsonEncode(body));
          socket.write(
            'HTTP/1.1 $code OK\r\nContent-Type: application/json\r\n'
            'Content-Length: ${bytes.length}\r\nConnection: close\r\n\r\n',
          );
          socket.add(bytes);
        }
        await socket.flush();
      } catch (_) {
        // el cliente ya no está
      } finally {
        socket.destroy();
      }
    }

    try {
      handle = await handler.hold(event);
    } catch (e, st) {
      Log.error('hold ${event.name}', e, st);
    }
    if (handle == null) return write(204);
    if (gone) {
      handle.cancel();
      return;
    }
    final result = await handle.result;
    await write(result.body == null ? 204 : 200, result.body);
  }
}
