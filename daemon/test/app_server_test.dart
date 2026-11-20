import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/app_server.dart';
import 'package:therd_daemon/src/herdr_client.dart';
import 'package:therd_daemon/src/images.dart';
import 'package:therd_daemon/src/pending.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_daemon/src/uploads.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

const token = 'secreto';

class Conn {
  Conn(this.ws) {
    ws.listen((d) => messages.add(decodeMessage(d as String)));
  }
  final WebSocket ws;
  final List<Message> messages = [];

  void send(ClientMessage m) => ws.add(m.encode());

  Future<T> next<T extends Message>({bool Function(T)? where}) async {
    var i = 0;
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(end)) {
      for (; i < messages.length; i++) {
        final m = messages[i];
        if (m is T && (where == null || where(m))) {
          messages.removeAt(i);
          return m;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException('mensaje $T');
  }
}

void main() {
  late Directory tmp;
  late FakeHerdr fake;
  late SessionStore store;
  late PendingManager pendings;
  late AppServer app;
  late HerdrClient herdr;

  setUp(() async {
    tmp = makeTemp('app');
    fake = FakeHerdr('${tmp.path}/h.sock');
    await fake.start();
    herdr = HerdrClient(fake.path, requestTimeout: const Duration(seconds: 2));
    store = SessionStore();
    pendings = PendingManager(timeout: const Duration(seconds: 30));
    app = AppServer(
      token: token,
      store: store,
      pendings: pendings,
      herdr: herdr,
      port: 0,
      authTimeout: const Duration(milliseconds: 300),
      interruptDelay: const Duration(milliseconds: 10),
      uploads: Uploads('${tmp.path}/therd/uploads'),
      images: ImageStore('${tmp.path}/images'),
    );
    await app.start();
    store.upsertSession(
      's1',
      paneId: 'w1:p1',
      cwd: '/tmp/p',
      herdrTitle: 'Tarea',
      fromHerdr: true,
    );
    for (var i = 1; i <= 5; i++) {
      store.ingest(
        's1',
        AssistantTextItem(
          id: 'i$i',
          sessionId: 's1',
          seq: 0,
          timestamp: DateTime.utc(2026),
          text: 't$i',
        ),
      );
    }
  });

  tearDown(() async {
    await app.stop();
    pendings.dispose();
    await herdr.stop();
    await fake.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<Conn> connect({String query = '?token=$token'}) async =>
      Conn(await WebSocket.connect('ws://127.0.0.1:${app.port}/$query'));

  test('auth por query: primer mensaje es hello con las sesiones', () async {
    final c = await connect();
    final hello = await c.next<HelloMessage>();
    expect(hello.version, protocolVersion);
    expect(hello.version, 2);
    expect(hello.sessions.single.sessionId, 's1');
    expect(hello.sessions.single.title, 'Tarea');
    expect(hello.sessions.single.lastSeq, 5);
    expect(app.clientCount, 1);
  });

  test('auth por primer mensaje', () async {
    final c = await connect(query: '');
    c.send(const AuthMessage(token: token));
    await c.next<HelloMessage>();
  });

  test('token incorrecto: error unauthorized y cierre', () async {
    final c = await connect(query: '?token=mal');
    final e = await c.next<ErrorMessage>();
    expect(e.code, ErrorCode.unauthorized);
    final c2 = await connect(query: '');
    c2.send(const AuthMessage(token: 'mal'));
    expect((await c2.next<ErrorMessage>()).code, ErrorCode.unauthorized);
    expect(app.clientCount, 0);
  });

  test('un mensaje grande sin autenticar cierra con política', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${app.port}/');
    final closed = ws.drain<void>();
    ws.add('x' * (70 << 10));
    await closed.timeout(const Duration(seconds: 5));
    expect(ws.closeCode, WebSocketStatus.policyViolation);
    expect(app.clientCount, 0);
  });

  test(
    'un mensaje por encima del tope autenticado cierra con política',
    () async {
      final small = AppServer(
        token: token,
        store: store,
        pendings: pendings,
        herdr: herdr,
        port: 0,
        maxMessageBytes: 1000,
      );
      await small.start();
      addTearDown(small.stop);
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${small.port}/?token=$token',
      );
      final closed = ws.drain<void>();
      ws.add('x' * 2000);
      await closed.timeout(const Duration(seconds: 5));
      expect(ws.closeCode, WebSocketStatus.policyViolation);
    },
  );

  test('sin auth a tiempo se cierra', () async {
    final c = await connect(query: '');
    expect((await c.next<ErrorMessage>()).code, ErrorCode.unauthorized);
  });

  test(
    'subscribe: backlog paginado, luego item.append y item.update en directo',
    () async {
      final c = await connect();
      await c.next<HelloMessage>();
      c.send(const SubscribeMessage(sessionId: 's1', limit: 2));
      var b = await c.next<BacklogMessage>();
      expect(b.items.map((i) => i.seq), [4, 5]);
      expect(b.cursor, 4);
      expect(b.hasMore, isTrue);
      c.send(SubscribeMessage(sessionId: 's1', before: b.cursor, limit: 2));
      b = await c.next<BacklogMessage>();
      expect(b.items.map((i) => i.seq), [2, 3]);

      store.ingest(
        's1',
        ToolCallItem(
          id: 't1',
          sessionId: 's1',
          seq: 0,
          timestamp: DateTime.utc(2026),
          toolName: 'Bash',
        ),
      );
      final ap = await c.next<ItemAppendMessage>();
      expect(ap.item.seq, 6);
      store.completeTool('s1', 't1', isError: false, result: 'ok');
      final up = await c.next<ItemUpdateMessage>();
      expect((up.item as ToolCallItem).status, ToolStatus.ok);

      c.send(const UnsubscribeMessage(sessionId: 's1'));
      c.send(const PingMessage());
      await c.next<PongMessage>();
      store.ingest(
        's1',
        AssistantTextItem(
          id: 'i9',
          sessionId: 's1',
          seq: 0,
          timestamp: DateTime.utc(2026),
          text: 'z',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.messages.whereType<ItemAppendMessage>(), isEmpty);
    },
  );

  test('sesión eliminada y recreada: la suscripción se descarta', () async {
    final c = await connect();
    await c.next<HelloMessage>();
    c.send(const SubscribeMessage(sessionId: 's1'));
    await c.next<BacklogMessage>();
    store.removeSession('s1');
    store.upsertSession('s1', paneId: 'w1:p1', cwd: '/tmp/p', fromHerdr: true);
    c.send(const PingMessage());
    await c.next<PongMessage>();
    c.messages.clear();
    store.ingest(
      's1',
      AssistantTextItem(
        id: 'n1',
        sessionId: 's1',
        seq: 0,
        timestamp: DateTime.utc(2026),
        text: 'nuevo',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.messages.whereType<ItemAppendMessage>(), isEmpty);
  });

  test('subscribe a sesión desconocida da error', () async {
    final c = await connect();
    await c.next<HelloMessage>();
    c.send(const SubscribeMessage(sessionId: 'nope'));
    expect((await c.next<ErrorMessage>()).code, ErrorCode.unknownSession);
  });

  test('cambios de estado y de sesiones se envían a todos', () async {
    final c = await connect();
    await c.next<HelloMessage>();
    store.setStatus('s1', SessionStatus.working);
    final st = await c.next<StatusMessage>();
    expect(st.status, SessionStatus.working);
    store.upsertSession('s2', cwd: '/tmp/q');
    final ss = await c.next<SessionsMessage>(
      where: (m) => m.sessions.length == 2,
    );
    expect(ss.sessions.map((s) => s.sessionId), containsAll(['s1', 's2']));
  });

  test(
    'prompt: agent.prompt con pane y texto; agent_blocked da error legible',
    () async {
      fake.handlers['agent.prompt'] = (req) => {
        'result': {'type': 'ok'},
      };
      final c = await connect();
      await c.next<HelloMessage>();
      c.send(const PromptMessage(sessionId: 's1', text: 'hola'));
      await waitFor(
        () => fake.requests.any((r) => r['method'] == 'agent.prompt'),
        what: 'prompt',
      );
      expect(fake.requests.last['params'], {'target': 'w1:p1', 'text': 'hola'});

      fake.handlers['agent.prompt'] = (_) => {
        'error': {'code': 'agent_blocked', 'message': 'blocked'},
      };
      c.send(const PromptMessage(sessionId: 's1', text: 'otra'));
      final e = await c.next<ErrorMessage>();
      expect(e.code, ErrorCode.agentBlocked);
      expect(e.message, contains('terminal'));

      c.send(const PromptMessage(sessionId: 'nope', text: 'x'));
      expect((await c.next<ErrorMessage>()).code, ErrorCode.unknownSession);
    },
  );

  test('prompt con imagen: se guarda y su ruta va en el texto', () async {
    fake.handlers['agent.prompt'] = (req) => {
      'result': {'type': 'ok'},
    };
    final c = await connect();
    await c.next<HelloMessage>();
    final png = [0x89, 0x50, 0x4e, 0x47, 1, 2, 3];
    c.send(
      PromptMessage(
        sessionId: 's1',
        text: 'mira esto',
        images: [PromptImage(mime: 'image/png', data: base64.encode(png))],
      ),
    );
    await waitFor(
      () => fake.requests.any((r) => r['method'] == 'agent.prompt'),
      what: 'prompt',
    );
    final text = fake.requests.last['params']['text'] as String;
    final path = text.split('\n').last;
    expect(text, startsWith('mira esto\n\n/'));
    expect(path, endsWith('.png'));
    expect(File(path).readAsBytesSync(), png);
    expect(cleanPromptText(text), 'mira esto');

    c.send(
      const PromptMessage(
        sessionId: 's1',
        text: '',
        images: [PromptImage(mime: 'application/pdf', data: 'AAAA')],
      ),
    );
    final e = await c.next<ErrorMessage>();
    expect(e.code, ErrorCode.badRequest);
    expect(e.message, contains('no admitido'));
  });

  test('GET /images: pide el token y sirve la imagen', () async {
    final id = app.images!.put('image/png', base64.encode([1, 2, 3]))!;
    final http = HttpClient();
    addTearDown(http.close);
    Future<HttpClientResponse> get(String path, {String? bearer}) async {
      final req = await http.get('127.0.0.1', app.port, path);
      if (bearer != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      return req.close();
    }

    final noAuth = await get('/images/$id');
    expect(noAuth.statusCode, HttpStatus.unauthorized);
    await noAuth.drain<void>();

    final full = await get('/images/$id?full=1', bearer: token);
    expect(full.statusCode, HttpStatus.ok);
    expect(full.headers.contentType?.mimeType, 'image/png');
    expect(await full.fold<List<int>>([], (a, b) => a..addAll(b)), [1, 2, 3]);

    final missing = await get('/images/${'0' * 24}.png?token=$token');
    expect(missing.statusCode, HttpStatus.notFound);
    await missing.drain<void>();
  });

  test('herdr caído: error herdr_unavailable', () async {
    await fake.stop();
    final c = await connect();
    await c.next<HelloMessage>();
    c.send(const PromptMessage(sessionId: 's1', text: 'hola'));
    expect((await c.next<ErrorMessage>()).code, ErrorCode.herdrUnavailable);
    fake = FakeHerdr('${tmp.path}/h2.sock');
    await fake.start();
  });

  test('interrupt: send_keys Escape; con pendiente lo libera antes', () async {
    fake.handlers['agent.send_keys'] = (_) => {
      'result': {'type': 'ok'},
    };
    final c = await connect();
    await c.next<HelloMessage>();
    final h = pendings.open(
      Pending(
        requestId: 'r1',
        sessionId: 's1',
        kind: PendingKind.permission,
        toolName: 'Bash',
        createdAt: DateTime.now(),
      ),
    );
    await c.next<PendingMessage>();
    c.send(const InterruptMessage(sessionId: 's1'));
    final res = await h.result;
    expect(res.resolution, Resolution.released);
    await waitFor(
      () => fake.requests.any((r) => r['method'] == 'agent.send_keys'),
      what: 'escape',
    );
    expect(fake.requests.last['params'], {
      'target': 'w1:p1',
      'keys': ['Escape'],
    });
  });

  test('pendientes: pending, respuesta de la app y pending.resolved', () async {
    final c = await connect();
    await c.next<HelloMessage>();
    final h = pendings.open(
      Pending(
        requestId: 'r1',
        sessionId: 's1',
        kind: PendingKind.permission,
        toolName: 'Bash',
        toolInput: const {'command': 'git push'},
        createdAt: DateTime.now(),
      ),
    );
    final p = await c.next<PendingMessage>();
    expect(p.pending.requestId, 'r1');

    // Un suscriptor posterior lo recibe en el backlog.
    c.send(const SubscribeMessage(sessionId: 's1'));
    final b = await c.next<BacklogMessage>();
    expect(b.pending.single.requestId, 'r1');

    c.send(const PermissionMessage(requestId: 'r1', allow: true, always: true));
    final r = await c.next<PendingResolvedMessage>();
    expect(r.requestId, 'r1');
    expect(r.resolution, Resolution.allowed);
    expect((await h.result).body, isNotNull);

    c.send(const PermissionMessage(requestId: 'r1', allow: true));
    expect((await c.next<ErrorMessage>()).code, ErrorCode.unknownRequest);
    c.send(const ReleaseMessage(requestId: 'zz'));
    expect((await c.next<ErrorMessage>()).code, ErrorCode.unknownRequest);
  });

  test('answer a una pregunta', () async {
    final c = await connect();
    await c.next<HelloMessage>();
    final h = pendings.open(
      Pending(
        requestId: 'q1',
        sessionId: 's1',
        kind: PendingKind.question,
        toolName: 'AskUserQuestion',
        toolInput: const {'questions': []},
        createdAt: DateTime.now(),
      ),
    );
    c.send(const AnswerMessage(requestId: 'q1', answers: {'¿A?': 'sí'}));
    final res = await h.result;
    expect(res.resolution, Resolution.answered);
    expect(res.body!['hookSpecificOutput']['updatedInput']['answers'], {
      '¿A?': 'sí',
    });
  });

  test('release desde la app y al desconectarse la última app', () async {
    final c = await connect();
    await c.next<HelloMessage>();
    Pending mk(String id) => Pending(
      requestId: id,
      sessionId: 's1',
      kind: PendingKind.permission,
      toolName: 'Bash',
      createdAt: DateTime.now(),
    );
    final h1 = pendings.open(mk('r1'));
    c.send(const ReleaseMessage(requestId: 'r1'));
    expect((await h1.result).resolution, Resolution.released);

    final h2 = pendings.open(mk('r2'));
    await c.ws.close();
    expect(
      (await h2.result.timeout(const Duration(seconds: 3))).resolution,
      Resolution.released,
    );
    expect(app.clientCount, 0);
  });

  test('mensajes desconocidos o inválidos dan bad_request', () async {
    final c = await connect();
    await c.next<HelloMessage>();
    c.ws.add('{"type":"inventado"}');
    expect((await c.next<ErrorMessage>()).code, ErrorCode.badRequest);
    c.ws.add('no json');
    expect((await c.next<ErrorMessage>()).code, ErrorCode.badRequest);
  });
}
