import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/hook_router.dart';
import 'package:therd_daemon/src/hook_server.dart';
import 'package:therd_daemon/src/pending.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_daemon/src/transcript_tailer.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

const token = 'tok-test';

void main() {
  late SessionStore store;
  late PendingManager pendings;
  late TranscriptHub hub;
  late HookRouter router;
  late HookServer server;
  late HttpClient client;
  var clients = 1;
  late List<PendingEvent> pendingEvents;
  late Directory tmp;

  setUp(() async {
    clients = 1;
    tmp = makeTemp('hook');
    store = SessionStore();
    pendings = PendingManager(timeout: const Duration(seconds: 5));
    hub = TranscriptHub(store);
    router = HookRouter(
      store: store,
      hub: hub,
      pendings: pendings,
      projectsDir: tmp.path,
      plansDir: '${tmp.path}/plans',
      hasClients: () => clients > 0,
    );
    server = HookServer(token: token, handler: router, port: 0);
    await server.start();
    pendingEvents = [];
    pendings.events.listen(pendingEvents.add);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await hub.stop();
    router.dispose();
    pendings.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> post(
    Map<String, dynamic> body, {
    String auth = 'Bearer $token',
    String? pane = 'w1:p1',
  }) async {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}/hook'),
    );
    req.headers.set('Authorization', auth);
    if (pane != null) req.headers.set('X-Herdr-Pane', pane);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    return req.close();
  }

  Future<String> bodyOf(HttpClientResponse r) => utf8.decoder.bind(r).join();

  Map<String, dynamic> permissionEvent({
    String tool = 'Bash',
    Map<String, dynamic>? input,
    List<dynamic>? suggestions,
  }) => {
    'hook_event_name': 'PermissionRequest',
    'session_id': 's1',
    'cwd': '/tmp/proyecto',
    'tool_name': tool,
    'tool_input': input ?? {'command': 'git push'},
    'permission_suggestions': ?suggestions,
  };

  Future<String> waitPending() async {
    await waitFor(() => pendings.count > 0, what: 'pendiente');
    return pendings.forSession('s1').single.requestId;
  }

  group('origen y host', () {
    Future<int> rawPost(Map<String, String> headers) async {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/hook'),
      );
      headers.forEach(req.headers.set);
      req.write('{"hook_event_name":"Stop","session_id":"s1"}');
      return (await req.close()).statusCode;
    }

    test('rechaza peticiones de navegador (Origin, Sec-Fetch-*)', () async {
      expect(await rawPost({'Origin': 'https://evil.example'}), 403);
      expect(await rawPost({'Sec-Fetch-Site': 'cross-site'}), 403);
      expect(await rawPost({'Sec-Fetch-Mode': 'no-cors'}), 403);
    });

    test('rechaza un Host que no es loopback (DNS rebinding)', () async {
      expect(await rawPost({'Host': 'evil.example:${server.port}'}), 403);
      expect(await rawPost({'Host': '127.0.0.1.evil.example'}), 403);
    });

    test('acepta loopback sin Content-Type', () async {
      expect(await rawPost({}), isNot(403));
      expect(await rawPost({'Host': 'localhost:${server.port}'}), isNot(403));
      expect(await rawPost({'Host': '[::1]:${server.port}'}), isNot(403));
      expect(await rawPost({'Host': '127.0.0.1'}), isNot(403));
    });
  });

  group('sin retención', () {
    test(
      'rechaza token erróneo, otro método o ruta; acepta sin token',
      () async {
        expect((await post({'a': 1}, auth: 'Bearer malo')).statusCode, 401);
        // Claude sin THERD_TOKEN: cabecera vacía o «Bearer » a secas.
        expect((await post({'a': 1}, auth: '')).statusCode, isNot(401));
        expect((await post({'a': 1}, auth: 'Bearer ')).statusCode, isNot(401));
        final get = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/hook'),
        )).close();
        expect(get.statusCode, 405);
        final other = await (await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/otra'),
        )).close();
        expect(other.statusCode, 404);
      },
    );

    test('JSON inválido da 400', () async {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/hook'),
      );
      req.headers.set('Authorization', 'Bearer $token');
      req.write('{roto');
      expect((await req.close()).statusCode, 400);
    });

    test('el informe de un subagente no se pinta como prompt', () async {
      final r = await post({
        'hook_event_name': 'UserPromptSubmit',
        'session_id': 's1',
        'cwd': '/tmp/proyecto',
        'prompt':
            '<agent-message from="ac8c3d4cf58201751">\n'
            '[Subagent hand-back] The text below is the final report…\n'
            '</agent-message>',
      });
      expect(r.statusCode, 204);
      await waitFor(
        () => store.info('s1')?.status == SessionStatus.working,
        what: 'estado',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(store.itemsOf('s1'), isEmpty);
    });

    test('eventos de espejo: 204 inmediato y crean sesión e items', () async {
      var r = await post({
        'hook_event_name': 'UserPromptSubmit',
        'session_id': 's1',
        'cwd': '/tmp/proyecto',
        'prompt': 'haz algo',
      });
      expect(r.statusCode, 204);
      await waitFor(() => store.itemsOf('s1').isNotEmpty, what: 'prompt');
      expect(store.info('s1')!.paneId, 'w1:p1');
      expect(store.info('s1')!.status, SessionStatus.working);
      expect((store.itemsOf('s1').single as UserPromptItem).text, 'haz algo');

      r = await post({
        'hook_event_name': 'PreToolUse',
        'session_id': 's1',
        'tool_name': 'Bash',
        'tool_input': {'command': 'ls'},
        'tool_use_id': 'tu1',
      });
      expect(r.statusCode, 204);
      await waitFor(() => store.itemById('s1', 'tu1') != null, what: 'tarjeta');
      expect(
        (store.itemById('s1', 'tu1') as ToolCallItem).status,
        ToolStatus.running,
      );

      r = await post({
        'hook_event_name': 'PostToolUse',
        'session_id': 's1',
        'tool_use_id': 'tu1',
        'tool_response': {'stdout': 'a.txt'},
        'duration_ms': 42,
      });
      expect(r.statusCode, 204);
      await waitFor(
        () =>
            (store.itemById('s1', 'tu1') as ToolCallItem).status ==
            ToolStatus.ok,
        what: 'cierre',
      );
      final t = store.itemById('s1', 'tu1') as ToolCallItem;
      expect(t.result, 'a.txt');
      expect(t.durationMs, 42);

      r = await post({'hook_event_name': 'Stop', 'session_id': 's1'});
      expect(r.statusCode, 204);
      await waitFor(
        () => store.info('s1')!.status == SessionStatus.idle,
        what: 'idle',
      );

      r = await post({'hook_event_name': 'SessionEnd', 'session_id': 's1'});
      expect(r.statusCode, 204);
      await waitFor(() => !store.has('s1'), what: 'baja');
    });

    test(
      'PermissionRequest sin ninguna app conectada: 204 al instante, sin retener',
      () async {
        clients = 0;
        final r = await post(permissionEvent());
        expect(r.statusCode, 204);
        expect(pendings.count, 0);
        // AskUserQuestion igual
        final q = await post({
          'hook_event_name': 'PreToolUse',
          'session_id': 's1',
          'tool_name': 'AskUserQuestion',
          'tool_input': {'questions': []},
        });
        expect(q.statusCode, 204);
        expect(pendings.count, 0);
      },
    );

    test(
      'PermissionRequest de AskUserQuestion no se retiene (lo hace PreToolUse)',
      () async {
        final r = await post(
          permissionEvent(tool: 'AskUserQuestion', input: {'questions': []}),
        );
        expect(r.statusCode, 204);
        expect(pendings.count, 0);
      },
    );
  });

  group('retención con app conectada', () {
    test('permitir: formato exacto de la decisión', () async {
      final f = post(permissionEvent());
      final id = await waitPending();
      expect(pendings.respondPermission(id, allow: true), isTrue);
      final r = await f;
      expect(r.statusCode, 200);
      expect(jsonDecode(await bodyOf(r)), {
        'hookSpecificOutput': {
          'hookEventName': 'PermissionRequest',
          'decision': {
            'behavior': 'allow',
            'updatedInput': {'command': 'git push'},
          },
        },
      });
      expect(
        pendingEvents.whereType<PendingClosed>().single.resolution,
        Resolution.allowed,
      );
      // El item del chat existe y quedó resuelto.
      final item = store.itemsOf('s1').whereType<PermissionItem>().single;
      expect(item.resolution, Resolution.allowed);
      expect(item.toolName, 'Bash');
    });

    test(
      'permitir siempre usa updatedPermissions de permission_suggestions',
      () async {
        final sug = [
          {
            'type': 'addRules',
            'rules': [
              {'toolName': 'Bash', 'ruleContent': 'git push:*'},
            ],
            'behavior': 'allow',
            'destination': 'localSettings',
          },
        ];
        final f = post(permissionEvent(suggestions: sug));
        final id = await waitPending();
        pendings.respondPermission(id, allow: true, always: true);
        final body = jsonDecode(await bodyOf(await f)) as Map;
        expect(body['hookSpecificOutput']['decision'], {
          'behavior': 'allow',
          'updatedInput': {'command': 'git push'},
          'updatedPermissions': sug,
        });
      },
    );

    test('denegar con mensaje', () async {
      final f = post(permissionEvent());
      final id = await waitPending();
      pendings.respondPermission(id, allow: false, message: 'No hagas push');
      final r = await f;
      expect(jsonDecode(await bodyOf(r)), {
        'hookSpecificOutput': {
          'hookEventName': 'PermissionRequest',
          'decision': {'behavior': 'deny', 'message': 'No hagas push'},
        },
      });
      expect(
        pendingEvents.whereType<PendingClosed>().single.resolution,
        Resolution.denied,
      );
    });

    test('ExitPlanMode es un plan; rechazar lleva el feedback', () async {
      final f = post(
        permissionEvent(tool: 'ExitPlanMode', input: {'plan': '# Plan\n1. A'}),
      );
      final id = await waitPending();
      final p = pendings.byId(id)!;
      expect(p.kind, PendingKind.plan);
      expect(p.plan, '# Plan\n1. A');
      expect(store.itemsOf('s1').whereType<PlanItem>().single.requestId, id);
      pendings.respondPermission(id, allow: false, message: 'Cambia el paso 1');
      final body = jsonDecode(await bodyOf(await f)) as Map;
      expect(body['hookSpecificOutput']['decision'], {
        'behavior': 'deny',
        'message': 'Cambia el paso 1',
      });
      expect(
        (store.itemsOf('s1').whereType<PlanItem>().single).resolution,
        Resolution.denied,
      );
    });

    test('ExitPlanMode sin plan lo lee del archivo de plan escrito', () async {
      final plans = Directory('${tmp.path}/plans')..createSync();
      final file = File('${plans.path}/plan-x.md')
        ..writeAsStringSync('# Plan del archivo\n1. B');
      await post({
        'hook_event_name': 'PreToolUse',
        'session_id': 's1',
        'tool_name': 'Write',
        'tool_input': {'file_path': file.path, 'content': '...'},
        'tool_use_id': 'tw1',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final f = post(permissionEvent(tool: 'ExitPlanMode', input: {}));
      final id = await waitPending();
      expect(pendings.byId(id)!.plan, '# Plan del archivo\n1. B');
      expect(
        store.itemsOf('s1').whereType<PlanItem>().single.plan,
        '# Plan del archivo\n1. B',
      );
      pendings.respondPermission(id, allow: true);
      await f;
    });

    test('aprobar ExitPlanMode devuelve updatedInput con el plan', () async {
      final f = post(
        permissionEvent(tool: 'ExitPlanMode', input: {'plan': '# Plan\n1. A'}),
      );
      final id = await waitPending();
      pendings.respondPermission(id, allow: true);
      final body = jsonDecode(await bodyOf(await f)) as Map;
      expect(body['hookSpecificOutput']['decision'], {
        'behavior': 'allow',
        'updatedInput': {'plan': '# Plan\n1. A'},
      });
    });

    test(
      'AskUserQuestion: PreToolUse devuelve updatedInput con answers',
      () async {
        final questions = [
          {
            'question': '¿Qué framework?',
            'header': 'Framework',
            'options': [
              {'label': 'React', 'description': 'UI'},
              {'label': 'Vue', 'description': 'UI'},
            ],
            'multiSelect': false,
          },
        ];
        final f = post({
          'hook_event_name': 'PreToolUse',
          'session_id': 's1',
          'tool_name': 'AskUserQuestion',
          'tool_input': {'questions': questions},
          'tool_use_id': 'tq1',
        });
        final id = await waitPending();
        final p = pendings.byId(id)!;
        expect(p.kind, PendingKind.question);
        expect(p.questions.single.options.map((o) => o.label), [
          'React',
          'Vue',
        ]);
        // La respuesta de permiso no vale para una pregunta.
        expect(pendings.respondPermission(id, allow: true), isFalse);
        expect(
          pendings.respondAnswer(id, {'¿Qué framework?': 'React'}),
          isTrue,
        );
        final body = jsonDecode(await bodyOf(await f)) as Map;
        expect(body, {
          'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'allow',
            'updatedInput': {
              'questions': questions,
              'answers': {'¿Qué framework?': 'React'},
            },
          },
        });
        final item = store.itemById('s1', 'tq1') as QuestionItem;
        expect(item.resolution, Resolution.answered);
        expect(item.answers, {'¿Qué framework?': 'React'});
      },
    );

    test('timeout: 204 vacío y resolución timeout', () async {
      pendings.timeout = const Duration(milliseconds: 150);
      final r = await post(permissionEvent());
      expect(r.statusCode, 204);
      expect(await bodyOf(r), isEmpty);
      expect(
        pendingEvents.whereType<PendingClosed>().single.resolution,
        Resolution.timeout,
      );
      expect(pendings.count, 0);
    });

    test('release: 204 vacío y resolución released', () async {
      final f = post(permissionEvent());
      final id = await waitPending();
      expect(pendings.release(id), isTrue);
      final r = await f;
      expect(r.statusCode, 204);
      expect(
        pendingEvents.whereType<PendingClosed>().single.resolution,
        Resolution.released,
      );
      expect(pendings.release(id), isFalse); // ya no existe
    });

    test('desconexión del hook: se resuelve como cancelado', () async {
      final sock = await Socket.connect('127.0.0.1', server.port);
      final body = jsonEncode(permissionEvent());
      sock.write(
        'POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer $token\r\n'
        'Content-Type: application/json\r\nContent-Length: ${utf8.encode(body).length}\r\n\r\n$body',
      );
      await sock.flush();
      await waitPending();
      sock.destroy();
      await waitFor(() => pendings.count == 0, what: 'cancelación');
      final closed = pendingEvents.whereType<PendingClosed>().single;
      expect(closed.resolution, Resolution.cancelled);
      expect(
        store.itemsOf('s1').whereType<PermissionItem>().single.resolution,
        Resolution.cancelled,
      );
    });

    test(
      'un Stop o un prompt nuevo cancelan los pendientes de la sesión',
      () async {
        final f = post(permissionEvent());
        await waitPending();
        await post({
          'hook_event_name': 'UserPromptSubmit',
          'session_id': 's1',
          'prompt': 'x',
        });
        final r = await f;
        expect(r.statusCode, 204);
        expect(
          pendingEvents.whereType<PendingClosed>().single.resolution,
          Resolution.cancelled,
        );
      },
    );

    test('estado blocked mientras hay pendiente y vuelve a working', () async {
      final f = post(permissionEvent());
      final id = await waitPending();
      expect(store.info('s1')!.status, SessionStatus.blocked);
      pendings.respondPermission(id, allow: true);
      await f;
      expect(store.info('s1')!.status, SessionStatus.working);
    });
  });
}
