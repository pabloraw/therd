import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/cli.dart';
import 'package:therd_daemon/src/config.dart';
import 'package:therd_daemon/src/log.dart';
import 'package:therd_daemon/src/notifier.dart';
import 'package:therd_daemon/src/pending.dart';
import 'package:therd_daemon/src/push_registry.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

/// ntfy falso: guarda los POST JSON y responde a /v1/health.
class FakeNtfy {
  late HttpServer server;
  final posts = <Map<String, dynamic>>[];
  final auth = <String?>[];
  int status = 200;

  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      if (req.method == 'GET' && req.uri.path == '/v1/health') {
        req.response.write('{"healthy":true}');
      } else if (req.method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        posts.add(Map<String, dynamic>.from(jsonDecode(body) as Map));
        auth.add(req.headers.value('authorization'));
        req.response.statusCode = status;
      }
      await req.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

Pending pend(
  String id, {
  PendingKind kind = PendingKind.permission,
  String tool = 'Bash',
  Map<String, dynamic> input = const {'command': 'rm -rf build'},
}) => Pending(
  requestId: id,
  sessionId: 's1',
  kind: kind,
  toolName: tool,
  toolInput: input,
  createdAt: DateTime.now(),
);

void main() {
  group('UnifiedPush', pushTests);
  late FakeNtfy ntfy;
  late PendingManager pm;
  var clients = 0;
  final warnings = <String>[];

  PendingNotifier make({NtfyConfig? cfg, String? url}) => PendingNotifier(
    events: pm.events,
    client: cfg == null && url == null
        ? null
        : NtfyClient(
            cfg ?? NtfyConfig(url: url!, topic: 'therd'),
            timeout: const Duration(seconds: 2),
          ),
    hasClients: () => clients > 0,
    sessionInfo: (id) => const SessionInfo(
      sessionId: 's1',
      cwd: '/home/u/proyecto',
      title: 'Arreglar login',
    ),
  );

  setUp(() async {
    ntfy = FakeNtfy();
    await ntfy.start();
    pm = PendingManager(timeout: const Duration(minutes: 1));
    clients = 0;
    warnings.clear();
    Log.sink = warnings.add;
  });

  tearDown(() async {
    pm.dispose();
    await ntfy.stop();
  });

  test('config ntfy: round-trip y ausente', () {
    final c = TherdConfig.fromJson({
      'token': 'x',
      'ntfy': {'url': 'http://h:1/', 'topic': 't', 'token': 'tk'},
    });
    expect(c.ntfy!.url, 'http://h:1');
    final back = TherdConfig.fromJson(c.toJson());
    expect(back.ntfy!.topic, 't');
    expect(back.ntfy!.token, 'tk');
    final none = TherdConfig.fromJson({'token': 'x'});
    expect(none.ntfy, isNull);
    expect(none.toJson().containsKey('ntfy'), isFalse);
  });

  test('publica sin clientes con título, mensaje, click y prioridad', () async {
    final n = make(url: ntfy.url);
    pm.open(pend('r1'));
    await Future.wait(n.inFlight);
    expect(ntfy.posts, hasLength(1));
    final m = ntfy.posts.single;
    expect(m['topic'], 'therd');
    expect(m['title'], 'Permiso: Bash');
    expect(m['message'], 'Arreglar login\nrm -rf build');
    expect(m['click'], 'therd://session/s1');
    expect(m['priority'], 4);
    expect(m['tags'], isNotEmpty);
  });

  test('preguntas, planes y herramientas MCP', () async {
    final n = make(url: ntfy.url);
    pm.open(
      Pending(
        requestId: 'q',
        sessionId: 's1',
        kind: PendingKind.question,
        questions: const [QuestionSpec(question: '¿Qué base de datos?')],
        createdAt: DateTime.now(),
      ),
    );
    pm.open(
      Pending(
        requestId: 'p',
        sessionId: 's1',
        kind: PendingKind.plan,
        plan: '\n# Migrar a Postgres\n- paso',
        createdAt: DateTime.now(),
      ),
    );
    pm.open(pend('m', tool: 'mcp__github__create_issue', input: const {}));
    await Future.wait(n.inFlight);
    final titles = ntfy.posts.map((m) => m['title']).toSet();
    expect(titles, {
      'Pregunta',
      'Plan para revisar',
      'Permiso: github create_issue',
    });
    final plan = ntfy.posts.firstWhere(
      (m) => m['title'] == 'Plan para revisar',
    );
    expect(plan['message'], 'Arreglar login\nMigrar a Postgres');
  });

  test('trunca el resumen', () async {
    final n = make(url: ntfy.url);
    pm.open(pend('r1', input: {'command': 'x' * 500}));
    await Future.wait(n.inFlight);
    expect(
      (ntfy.posts.single['message'] as String).length,
      lessThanOrEqualTo(140),
    );
  });

  test('no publica con clientes conectados', () async {
    clients = 1;
    final n = make(url: ntfy.url);
    pm.open(pend('r1'));
    await Future.wait(n.inFlight);
    expect(ntfy.posts, isEmpty);
  });

  test('una sola vez por requestId', () async {
    final n = make(url: ntfy.url);
    pm.open(pend('r1'));
    pm.open(pend('r1'));
    await Future.wait(n.inFlight);
    expect(ntfy.posts, hasLength(1));
  });

  test('sin config no hace nada', () async {
    final n = make();
    pm.open(pend('r1'));
    await Future.wait(n.inFlight);
    expect(ntfy.posts, isEmpty);
  });

  test('envía el token como Bearer', () async {
    final n = make(
      cfg: NtfyConfig(url: ntfy.url, topic: 'therd', token: 'tk_abc'),
    );
    pm.open(pend('r1'));
    await Future.wait(n.inFlight);
    expect(ntfy.auth.single, 'Bearer tk_abc');
  });

  test('fallo de red no lanza y avisa una sola vez', () async {
    final dead = await HttpServer.bind('127.0.0.1', 0);
    final url = 'http://127.0.0.1:${dead.port}';
    await dead.close(force: true);
    final n = make(url: url);
    pm.open(pend('r1'));
    pm.open(pend('r2'));
    await Future.wait(n.inFlight);
    expect(warnings.where((w) => w.contains('ntfy')), hasLength(1));
  });

  test('error HTTP del servidor tampoco lanza', () async {
    ntfy.status = 500;
    final n = make(url: ntfy.url);
    pm.open(pend('r1'));
    await Future.wait(n.inFlight);
    expect(warnings.single, contains('HTTP 500'));
  });

  test('health y notify-test', () async {
    expect(
      await NtfyClient(NtfyConfig(url: ntfy.url, topic: 't')).health(),
      isNull,
    );
    final tmp = makeTemp('ntfy');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final cfg = TherdConfig(
      token: 'x',
      ntfy: NtfyConfig(url: ntfy.url, topic: 'therd'),
    );
    cfg.save(TherdPaths(home: tmp.path, configDir: '${tmp.path}/cfg'));
    final out = StringBuffer();
    final code = await runCli([
      'notify-test',
      '--home',
      tmp.path,
      '--config-dir',
      '${tmp.path}/cfg',
    ], out: out);
    expect(code, 0);
    expect(out.toString(), contains('enviada'));
    expect(ntfy.posts.single['title'], 'Prueba de therd');
  });
}

void pushTests() {
  late FakeNtfy ntfy;
  late PendingManager pm;
  var clients = 0;

  setUp(() async {
    ntfy = FakeNtfy();
    await ntfy.start();
    pm = PendingManager(timeout: const Duration(minutes: 1));
    clients = 0;
    Log.sink = (_) {};
  });

  tearDown(() async {
    pm.dispose();
    await ntfy.stop();
  });

  PendingNotifier make(PushRegistry reg, {String? topicUrl}) => PendingNotifier(
    events: pm.events,
    client: topicUrl == null
        ? null
        : NtfyClient(NtfyConfig(url: topicUrl, topic: 'therd')),
    hasClients: () => clients > 0,
    sessionInfo: (_) =>
        const SessionInfo(sessionId: 's1', title: 'Arreglar login'),
    push: reg,
  );

  test('registro: valida, deduplica, olvida el anterior y persiste', () {
    final dir = Directory.systemTemp.createTempSync('therd-push');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = '${dir.path}/push.json';
    final reg = PushRegistry(file: file, max: 2);
    expect(reg.register('no es url'), isFalse);
    expect(reg.register('ftp://h/x'), isFalse);
    expect(reg.register('http://h/up1?up=1'), isTrue);
    expect(reg.register('http://h/up1?up=1'), isTrue);
    expect(reg.register('http://h/up2', previous: 'http://h/up1?up=1'), isTrue);
    expect(reg.endpoints, ['http://h/up2']);
    reg.register('http://h/up3');
    reg.register('http://h/up4');
    expect(reg.endpoints, ['http://h/up3', 'http://h/up4']);
    expect(PushRegistry(file: file).endpoints, [
      'http://h/up3',
      'http://h/up4',
    ]);
    reg.unregister('http://h/up3');
    expect(PushRegistry(file: file).endpoints, ['http://h/up4']);
  });

  test('con endpoint avisa por UnifiedPush y no por el topic', () async {
    final reg = PushRegistry()..register('${ntfy.url}/upABC?up=1');
    final n = make(reg, topicUrl: ntfy.url);
    pm.open(
      Pending(
        requestId: 'r1',
        sessionId: 's1',
        kind: PendingKind.permission,
        toolName: 'Bash',
        toolInput: const {'command': 'ls'},
        suggestions: const [
          {'type': 'addRules'},
        ],
        createdAt: DateTime.now(),
      ),
    );
    await Future.wait(n.inFlight);
    expect(ntfy.posts, hasLength(1));
    final p = PushPayload.fromJson(ntfy.posts.single) as PushPending;
    expect(p.requestId, 'r1');
    expect(p.sessionId, 's1');
    expect(p.title, 'Permiso: Bash');
    expect(p.body, 'Arreglar login\nls');
    expect(p.canAlways, isTrue);
  });

  test(
    'al cerrarse retira la notificación, salvo si pasa al terminal',
    () async {
      final reg = PushRegistry()..register('${ntfy.url}/upABC?up=1');
      final n = make(reg);
      pm.open(pend('r1'));
      pm.releaseAll(); // se fue la app: pasa al terminal, sigue avisado
      await Future.wait(n.inFlight);
      expect(ntfy.posts, hasLength(1));
      pm.open(pend('r1'));
      pm.release('r1');
      await Future.wait(n.inFlight);
      expect(ntfy.posts, hasLength(2));
      expect(PushPayload.fromJson(ntfy.posts.last), isA<PushResolved>());
    },
  );

  test('sin aviso previo no manda retirada', () async {
    final reg = PushRegistry()..register('${ntfy.url}/upABC?up=1');
    clients = 1;
    final n = make(reg);
    pm.open(pend('r1'));
    pm.release('r1');
    await Future.wait(n.inFlight);
    expect(ntfy.posts, isEmpty);
  });
}
