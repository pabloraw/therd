import 'package:test/test.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_protocol/protocol.dart';

AssistantTextItem text(String id, [String t = 'x']) => AssistantTextItem(
  id: id,
  sessionId: 's',
  seq: 0,
  timestamp: DateTime.utc(2026, 1, 1),
  text: t,
);

ToolCallItem tool(String id) => ToolCallItem(
  id: id,
  sessionId: 's',
  seq: 0,
  timestamp: DateTime.utc(2026, 1, 1),
  toolName: 'Bash',
);

void main() {
  late SessionStore store;
  late List<StoreEvent> events;
  setUp(() {
    store = SessionStore()..upsertSession('s', cwd: '/home/x/proyecto');
    events = [];
    store.events.listen(events.add);
  });

  test('seq monotónico y dedup por id', () {
    store.ingest('s', text('a'));
    store.ingest('s', text('b'));
    expect(store.ingest('s', text('a', 'otro')), isNull);
    expect(store.itemsOf('s').map((e) => e.seq), [1, 2]);
    expect(events.whereType<ItemAppended>(), hasLength(2));
    expect(store.info('s')!.lastSeq, 2);
  });

  test('ingest en sesión desconocida no hace nada', () {
    expect(store.ingest('zz', text('a')), isNull);
  });

  test('tarjeta de herramienta: running, ok con duración y resultado', () {
    store.ingest('s', tool('t1'));
    store.completeTool(
      's',
      't1',
      isError: false,
      result: 'salida',
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
    );
    final t = store.itemById('s', 't1') as ToolCallItem;
    expect(t.status, ToolStatus.ok);
    expect(t.result, 'salida');
    expect(t.durationMs, 2000);
    expect(events.whereType<ItemUpdated>(), hasLength(1));
    // idempotente: repetir el mismo cierre no emite otro update
    store.completeTool(
      's',
      't1',
      isError: false,
      result: 'salida',
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
    );
    expect(events.whereType<ItemUpdated>(), hasLength(1));
  });

  test('resultado que llega antes que la tarjeta se aplica al crearla', () {
    store.completeTool('s', 't9', isError: true, result: 'fallo');
    store.ingest('s', tool('t9'));
    final t = store.itemById('s', 't9') as ToolCallItem;
    expect(t.status, ToolStatus.error);
    expect(t.isError, isTrue);
  });

  test('prompt creado por hook se reconcilia con la línea del transcript', () {
    store.ingest(
      's',
      UserPromptItem(
        id: 'hook:prompt:1',
        sessionId: 's',
        seq: 0,
        timestamp: DateTime.utc(2026),
        text: 'hola',
      ),
    );
    final r = store.ingest(
      's',
      UserPromptItem(
        id: 'uuid-real',
        sessionId: 's',
        seq: 0,
        timestamp: DateTime.utc(2026),
        text: 'hola',
        images: ['ab.png'],
      ),
    );
    expect(r, isNull);
    expect(store.itemsOf('s'), hasLength(1));
    // Las imágenes del transcript pasan al prompt del hook.
    expect((store.itemsOf('s').single as UserPromptItem).images, ['ab.png']);
    // la línea repetida del transcript tampoco duplica
    expect(
      store.ingest(
        's',
        UserPromptItem(
          id: 'uuid-real',
          sessionId: 's',
          seq: 0,
          timestamp: DateTime.utc(2026),
          text: 'hola',
        ),
      ),
      isNull,
    );
    expect(store.itemsOf('s'), hasLength(1));
  });

  test('el plan del transcript no duplica el plan creado por hook', () {
    store.ingest(
      's',
      PlanItem(
        id: 'plan:r1',
        sessionId: 's',
        seq: 0,
        timestamp: DateTime.utc(2026),
        requestId: 'r1',
        plan: 'P',
      ),
    );
    store.ingest(
      's',
      PlanItem(
        id: 'toolu_p',
        sessionId: 's',
        seq: 0,
        timestamp: DateTime.utc(2026),
        requestId: '',
        plan: 'P',
      ),
    );
    expect(store.itemsOf('s'), hasLength(1));
  });

  test('upsertPendingItem adopta el plan que ya trajo el transcript', () {
    store.ingest(
      's',
      PlanItem(
        id: 'toolu_p',
        sessionId: 's',
        seq: 0,
        timestamp: DateTime.utc(2026),
        requestId: '',
        plan: 'P',
      ),
    );
    final r =
        store.upsertPendingItem(
              's',
              PlanItem(
                id: 'plan:r1',
                sessionId: 's',
                seq: 0,
                timestamp: DateTime.utc(2026),
                requestId: 'r1',
                plan: 'P',
              ),
            )
            as PlanItem;
    expect(store.itemsOf('s'), hasLength(1));
    expect(r.id, 'toolu_p');
    expect(r.requestId, 'r1');
  });

  test('pregunta del transcript se cierra con el resultado', () {
    store.ingest(
      's',
      QuestionItem(
        id: 'tq',
        sessionId: 's',
        seq: 0,
        timestamp: DateTime.utc(2026),
        requestId: '',
        questions: const [QuestionSpec(question: '¿Cuál?')],
      ),
    );
    store.completeTool(
      's',
      'tq',
      isError: false,
      result: 'User has answered your questions: "¿Cuál?"="A". Continúa.',
    );
    final q = store.itemById('s', 'tq') as QuestionItem;
    expect(q.resolution, Resolution.answered);
    expect(q.answers, {'¿Cuál?': 'A'});
  });

  test('backlog paginado hacia atrás', () {
    for (var i = 1; i <= 10; i++) {
      store.ingest('s', text('i$i'));
    }
    var page = store.backlog('s', limit: 4);
    expect(page.items.map((e) => e.seq), [7, 8, 9, 10]);
    expect(page.cursor, 7);
    expect(page.hasMore, isTrue);
    page = store.backlog('s', before: page.cursor, limit: 4);
    expect(page.items.map((e) => e.seq), [3, 4, 5, 6]);
    expect(page.cursor, 3);
    expect(page.hasMore, isTrue);
    page = store.backlog('s', before: page.cursor, limit: 4);
    expect(page.items.map((e) => e.seq), [1, 2]);
    expect(page.hasMore, isFalse);
    expect(store.backlog('zz').items, isEmpty);
  });

  test('límite de items por sesión descarta los más antiguos', () {
    final small = SessionStore(maxItemsPerSession: 50)..upsertSession('s');
    for (var i = 1; i <= 300; i++) {
      small.ingest('s', text('i$i'));
    }
    final items = small.itemsOf('s');
    expect(items.length, lessThanOrEqualTo(50));
    expect(items.last.seq, 300);
    expect(small.itemById('s', 'i1'), isNull);
  });

  test('título: herdr, luego ai-title, luego carpeta; estado y eventos', () {
    expect(store.info('s')!.title, 'proyecto');
    store.updateMeta('s', title: 'Título IA');
    expect(store.info('s')!.title, 'Título IA');
    store.upsertSession('s', herdrTitle: 'Claude Code');
    expect(store.info('s')!.title, 'Título IA');
    store.upsertSession('s', herdrTitle: 'Título herdr');
    expect(store.info('s')!.title, 'Título herdr');

    events.clear();
    store.setStatus('s', SessionStatus.working);
    store.setStatus('s', SessionStatus.working);
    expect(events.whereType<StatusChanged>(), hasLength(1));
  });

  test('pruneHerdrSessions solo quita las que venían de herdr', () {
    store.upsertSession('h1', fromHerdr: true, paneId: 'w:p1');
    expect(store.sessionIdForPane('w:p1'), 'h1');
    expect(store.pruneHerdrSessions({'otra'}), ['h1']);
    expect(store.has('s'), isTrue);
    expect(store.has('h1'), isFalse);
  });
}
