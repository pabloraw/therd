import 'dart:async';

import 'package:test/test.dart';
import 'package:therd_daemon/src/seen_sync.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_protocol/protocol.dart';

AssistantTextItem text(String id) => AssistantTextItem(
  id: id,
  sessionId: 's',
  seq: 0,
  timestamp: DateTime.utc(2026, 1, 1),
  text: 'x',
);

/// herdr falso: un pane enfocado y el registro de focos.
class FakeFocus implements FocusIo {
  FakeFocus([this.current]);
  String? current;
  final focused = <String>[];

  @override
  Future<String?> currentPane() async => current;

  @override
  Future<void> focusPane(String paneId) async {
    focused.add(paneId);
    current = paneId;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late SessionStore store;
  late List<StoreEvent> events;

  setUp(() {
    store = SessionStore()..upsertSession('s', paneId: 'p1');
    events = [];
    store.events.listen(events.add);
  });

  group('store', () {
    test('markSeen avanza, no pasa del último seq y avisa', () {
      store.ingest('s', text('a'));
      store.ingest('s', text('b'));
      expect(store.markSeen('s', 1), isTrue);
      expect(store.markSeen('s', 1), isFalse);
      expect(store.markSeen('s', 99), isTrue);
      expect(store.info('s')!.seenSeq, 2);
      expect(events.whereType<SeenChanged>().map((e) => e.seq), [1, 2]);
    });

    test('herdr en idle quiere decir visto en el PC', () {
      store.ingest('s', text('a'));
      store.setHerdrStatus('s', SessionStatus.done);
      expect(store.info('s')!.seenSeq, 0);
      store.setHerdrStatus('s', SessionStatus.idle);
      expect(store.info('s')!.seenSeq, 1);
    });

    test('enfocar el pane en el PC lo da por visto', () {
      store.ingest('s', text('a'));
      store.setFocusedPane('p1');
      expect(store.info('s')!.seenSeq, 1);
    });

    test('lo que llega a la sesión que se mira en el PC queda visto', () {
      store.setHerdrStatus('s', SessionStatus.idle);
      store.setFocusedPane('p1');
      store.ingest('s', text('a'));
      expect(store.info('s')!.seenSeq, 1);
    });

    test('lo que llega a una sesión sin enfocar no queda visto', () {
      store.setHerdrStatus('s', SessionStatus.idle);
      store.setFocusedPane('otro');
      store.ingest('s', text('a'));
      expect(store.info('s')!.seenSeq, 0);
    });
  });

  group('SeenSync', () {
    late FakeFocus io;
    late SeenSync sync;

    setUp(() {
      io = FakeFocus('p9');
      sync = SeenSync(store: store, io: io, settle: Duration.zero)..start();
      store.ingest('s', text('a'));
      store.ingest('s', text('b'));
    });

    tearDown(() => sync.dispose());

    test('leído en el móvil y terminado sin ver: enfoca y vuelve', () async {
      store.setHerdrStatus('s', SessionStatus.done);
      sync.fromApp('s', 2);
      await settle();
      expect(io.focused, ['p1', 'p9']);
      expect(store.info('s')!.seenSeq, 2);
      expect(store.herdrStatusOf('s'), SessionStatus.idle);
    });

    test('si herdr ya la da por vista no toca el PC', () async {
      store.setHerdrStatus('s', SessionStatus.idle);
      sync.fromApp('s', 2);
      await settle();
      expect(io.focused, isEmpty);
    });

    test('si al móvil le falta lo último no toca el PC', () async {
      store.setHerdrStatus('s', SessionStatus.done);
      sync.fromApp('s', 1);
      await settle();
      expect(io.focused, isEmpty);
      expect(store.info('s')!.seenSeq, 1);
    });

    test('ya leído en el móvil y herdr pasa a done después', () async {
      store.setHerdrStatus('s', SessionStatus.working);
      sync.fromApp('s', 2);
      await settle();
      expect(io.focused, isEmpty);
      store.setHerdrStatus('s', SessionStatus.done);
      sync.onHerdrStatus('s', SessionStatus.done);
      await settle();
      expect(io.focused, ['p1', 'p9']);
    });

    test('si ya estaba enfocada no hace falta volver', () async {
      io.current = 'p1';
      store.setHerdrStatus('s', SessionStatus.done);
      sync.fromApp('s', 2);
      await settle();
      expect(io.focused, ['p1']);
    });

    test('dos avisos seguidos enfocan una sola vez', () async {
      store.setHerdrStatus('s', SessionStatus.done);
      sync.fromApp('s', 2);
      sync.fromApp('s', 2);
      await settle();
      expect(io.focused, ['p1', 'p9']);
    });
  });
}
