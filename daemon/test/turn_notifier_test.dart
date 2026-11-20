import 'dart:async';

import 'package:test/test.dart';
import 'package:therd_daemon/src/config.dart';
import 'package:therd_daemon/src/log.dart';
import 'package:therd_daemon/src/notifier.dart';
import 'package:therd_daemon/src/pending.dart';
import 'package:therd_daemon/src/push_registry.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_protocol/protocol.dart';

import 'notifier_test.dart' show FakeNtfy, pend;

AssistantTextItem text(String id, String t) => AssistantTextItem(
  id: id,
  sessionId: 's1',
  seq: 0,
  timestamp: DateTime.utc(2026, 1, 1),
  text: t,
);

Future<void> pause([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeNtfy ntfy;
  late SessionStore store;
  late PendingManager pm;
  late TurnNotifier n;
  var clients = 0;

  TurnNotifier make({bool unified = true, bool topic = false}) {
    final reg = PushRegistry();
    if (unified) reg.register('${ntfy.url}/upABC?up=1');
    return TurnNotifier(
      store: store,
      pendings: pm,
      client: topic ? NtfyClient(NtfyConfig(url: ntfy.url, topic: 't')) : null,
      hasClients: () => clients > 0,
      push: reg,
      settle: const Duration(milliseconds: 30),
    )..start();
  }

  Future<void> flush() async {
    await pause();
    await Future.wait(n.inFlight);
  }

  List<PushPayload?> payloads() => [
    for (final p in ntfy.posts) PushPayload.fromJson(p),
  ];

  setUp(() async {
    Log.sink = (_) {};
    ntfy = FakeNtfy();
    await ntfy.start();
    store = SessionStore()
      ..upsertSession(
        's1',
        cwd: '/home/u/proyecto',
        status: SessionStatus.idle,
      );
    store.updateMeta('s1', title: 'Arreglar login');
    pm = PendingManager(timeout: const Duration(minutes: 1));
    clients = 0;
    store.ingest('s1', text('a', 'Primero\n\nHecho:   login arreglado'));
    n = make();
  });

  tearDown(() async {
    await n.dispose();
    pm.dispose();
    await store.dispose();
    await ntfy.stop();
  });

  test('avisa tras el margen con título y trozo del último texto', () async {
    n.onTurnEnd('s1');
    await pause(10);
    expect(ntfy.posts, isEmpty);
    await flush();
    final p = payloads().single as PushTurnDone;
    expect(p.sessionId, 's1');
    expect(p.title, 'Terminado: Arreglar login');
    expect(p.body, 'Primero Hecho: login arreglado');
  });

  test('dos señales del mismo turno cuentan una vez', () async {
    n.onTurnEnd('s1');
    n.onTurnEnd('s1');
    await flush();
    n.onTurnEnd('s1'); // otra vez sin seq nuevo
    await flush();
    expect(ntfy.posts, hasLength(1));
  });

  test('no avisa si ya se vio en el margen', () async {
    n.onTurnEnd('s1');
    store.markSeen('s1', 1);
    await flush();
    expect(ntfy.posts, isEmpty);
  });

  test('no avisa con una app conectada', () async {
    clients = 1;
    n.onTurnEnd('s1');
    await flush();
    expect(ntfy.posts, isEmpty);
  });

  test('no avisa con un pendiente abierto', () async {
    pm.open(pend('r1'));
    n.onTurnEnd('s1');
    await flush();
    expect(ntfy.posts, isEmpty);
    pm.release('r1');
  });

  test('un turno nuevo en el margen cancela el aviso', () async {
    n.onTurnEnd('s1');
    store.setStatus('s1', SessionStatus.working);
    await flush();
    expect(ntfy.posts, isEmpty);
  });

  test('se retira al verse y no antes', () async {
    store.ingest('s1', text('b', 'Segundo'));
    n.onTurnEnd('s1');
    await flush();
    expect(ntfy.posts, hasLength(1));
    store.markSeen('s1', 1);
    await flush();
    expect(ntfy.posts, hasLength(1));
    store.markSeen('s1', 2);
    await flush();
    expect(payloads().last, isA<PushTurnCleared>());
    expect((payloads().last as PushTurnCleared).sessionId, 's1');
  });

  test('se retira al empezar un turno nuevo, una sola vez', () async {
    n.onTurnEnd('s1');
    await flush();
    store.setStatus('s1', SessionStatus.working);
    store.markSeen('s1', 1);
    await flush();
    expect(payloads().whereType<PushTurnCleared>(), hasLength(1));
  });

  test('un turno nuevo sustituye al aviso (mismo sessionId)', () async {
    n.onTurnEnd('s1');
    await flush();
    store.setStatus('s1', SessionStatus.working);
    store.ingest('s1', text('b', 'Otro final'));
    store.setStatus('s1', SessionStatus.idle);
    n.onTurnEnd('s1');
    await flush();
    final dones = payloads().whereType<PushTurnDone>().toList();
    expect(dones, hasLength(2));
    expect(dones.last.body, 'Otro final');
  });

  test('sin UnifiedPush cae al topic de ntfy con enlace', () async {
    await n.dispose();
    n = make(unified: false, topic: true);
    n.onTurnEnd('s1');
    await flush();
    final m = ntfy.posts.single;
    expect(m['title'], 'Terminado: Arreglar login');
    expect(m['click'], 'therd://session/s1');
  });

  test('sin transporte no hace nada', () async {
    await n.dispose();
    n = make(unified: false);
    n.onTurnEnd('s1');
    await flush();
    expect(ntfy.posts, isEmpty);
  });
}
