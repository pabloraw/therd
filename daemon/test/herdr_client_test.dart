import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/herdr_client.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

void main() {
  late Directory tmp;
  late FakeHerdr fake;
  late HerdrClient client;

  setUp(() async {
    tmp = makeTemp('herdr');
    fake = FakeHerdr('${tmp.path}/h.sock');
    await fake.start();
    client = HerdrClient(
      fake.path,
      requestTimeout: const Duration(seconds: 2),
      maxBackoff: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    await client.stop();
    await fake.stop();
    tmp.deleteSync(recursive: true);
  });

  test('agent.list: mapea pane, sesión, estado y título', () async {
    fake.handlers['agent.list'] = (_) => {
      'result': {
        'type': 'agent_list',
        'agents': [
          agentJson(
            paneId: 'w1:p1',
            sessionId: 'sess-a',
            status: 'working',
            title: 'Mi tarea',
          ),
          {
            'agent': 'codex',
            'pane_id': 'w1:p2',
            'workspace_id': 'w1',
            'agent_status': 'idle',
          },
          {
            'agent': 'claude',
            'pane_id': 'w1:p3',
            'workspace_id': 'w1',
            'agent_status': 'idle',
          },
        ],
      },
    };
    final agents = await client.agentList();
    expect(agents, hasLength(3));
    final a = agents.first;
    expect(a.isClaude, isTrue);
    expect(a.sessionId, 'sess-a');
    expect(a.paneId, 'w1:p1');
    expect(a.workspaceId, 'w1');
    expect(a.status, SessionStatus.working);
    expect(a.title, 'Mi tarea');
    expect(
      agents.where((x) => x.isClaude),
      hasLength(1),
    ); // sin sesión o no claude: fuera
    expect(fake.requests.single['method'], 'agent.list');
  });

  test('pane.read: el texto viene dentro de `read`', () async {
    fake.handlers['pane.read'] = (_) => {
      'result': {
        'type': 'pane_read',
        'read': {'pane_id': 'w1:p1', 'text': 'pantalla'},
      },
    };
    expect(await client.readVisible('w1:p1'), 'pantalla');
    expect(fake.requests.single['params'], {
      'pane_id': 'w1:p1',
      'source': 'visible',
    });
  });

  test('agent.prompt y agent.send_keys con los params del esquema', () async {
    fake.handlers['agent.prompt'] = (_) => {
      'result': {'type': 'ok'},
    };
    fake.handlers['agent.send_keys'] = (_) => {
      'result': {'type': 'ok'},
    };
    await client.prompt('w1:p1', 'hola\nmundo');
    await client.sendKeys('w1:p1', ['Escape']);
    expect(fake.requests[0]['params'], {
      'target': 'w1:p1',
      'text': 'hola\nmundo',
    });
    expect(fake.requests[1]['method'], 'agent.send_keys');
    expect(fake.requests[1]['params'], {
      'target': 'w1:p1',
      'keys': ['Escape'],
    });
  });

  test('agent_blocked llega como HerdrException.isBlocked', () async {
    fake.handlers['agent.prompt'] = (_) => {
      'error': {'code': 'agent_blocked', 'message': 'agent is blocked'},
    };
    await expectLater(
      client.prompt('w1:p1', 'x'),
      throwsA(
        isA<HerdrException>().having((e) => e.isBlocked, 'isBlocked', isTrue),
      ),
    );
  });

  test('socket inexistente: unavailable', () async {
    final c = HerdrClient('${tmp.path}/no.sock');
    await expectLater(
      c.agentList(),
      throwsA(
        isA<HerdrException>().having(
          (e) => e.isUnavailable,
          'unavailable',
          isTrue,
        ),
      ),
    );
  });

  test(
    'eventos: suscribe con los panes, emite estado y se reconecta',
    () async {
      final events = <HerdrEvent>[];
      client.events.listen(events.add);
      var panes = ['w1:p1'];
      client.startEvents(() async => panes);

      await waitFor(() => fake.subscriberCount == 1, what: 'suscripción');
      final sub = fake.requests.firstWhere(
        (r) => r['method'] == 'events.subscribe',
      );
      expect(sub['params']['subscriptions'], [
        {'type': 'pane.created'},
        {'type': 'pane.closed'},
        {'type': 'pane.focused'},
        {'type': 'pane.agent_status_changed', 'pane_id': 'w1:p1'},
      ]);
      await waitFor(
        () => events.any((e) => e.event == 'connected'),
        what: 'connected',
      );

      fake.emit('pane.agent_status_changed', {
        'pane_id': 'w1:p1',
        'workspace_id': 'w1',
        'agent_status': 'blocked',
      });
      await waitFor(
        () => events.any((e) => e.event == 'pane.agent_status_changed'),
        what: 'evento',
      );
      final ev = events.firstWhere(
        (e) => e.event == 'pane.agent_status_changed',
      );
      expect(ev.paneId, 'w1:p1');
      expect(ev.status, SessionStatus.blocked);

      // herdr se cae y vuelve: reconecta solo.
      fake.dropSubscribers();
      await waitFor(() => fake.subscriberCount == 1, what: 'reconexión');
      // Cambia el conjunto de panes: resubscribe usa el nuevo.
      panes = ['w1:p1', 'w1:p2'];
      client.resubscribe();
      await waitFor(
        () =>
            fake.requests
                .where((r) => r['method'] == 'events.subscribe')
                .length >=
            3,
        what: 'resuscripción',
      );
      final last = fake.requests.lastWhere(
        (r) => r['method'] == 'events.subscribe',
      );
      expect((last['params']['subscriptions'] as List).length, 5);
    },
  );

  test('si herdr no está, reintenta con backoff hasta que aparece', () async {
    await fake.stop();
    final late = FakeHerdr('${tmp.path}/h.sock');
    final c = HerdrClient(
      late.path,
      requestTimeout: const Duration(milliseconds: 500),
      maxBackoff: const Duration(milliseconds: 100),
    );
    final connected = Completer<void>();
    c.events.listen((e) {
      if (e.event == 'connected' && !connected.isCompleted) {
        connected.complete();
      }
    });
    c.startEvents(() async => []);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(c.eventsConnected, isFalse);
    await late.start();
    await connected.future.timeout(const Duration(seconds: 5));
    expect(c.eventsConnected, isTrue);
    await c.stop();
    await late.stop();
    // tearDown vuelve a parar fake: ya parado, no debe fallar
    fake = FakeHerdr('${tmp.path}/otro.sock');
    await fake.start();
  });
}
