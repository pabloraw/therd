import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/data/app_state.dart';
import 'package:therd/src/data/therd_client.dart';
import 'package:therd_protocol/protocol.dart';

import 'support/fakes.dart';

AppState apply(AppState s, ServerMessage m) => reduce(s, m);

AppState subscribed([AppState? base]) =>
    (base ?? const AppState()).copyWith(chats: {'s1': const ChatState()});

void main() {
  group('mergeItems', () {
    test('ordena por seq y sustituye por id', () {
      final merged = mergeItems(
        [userItem(1, 'a'), asstItem(3, 'c')],
        [userItem(2, 'b'), asstItem(3, 'c2', id: 'a3')],
      );
      expect(merged.map((i) => i.seq), [1, 2, 3]);
      expect((merged.last as AssistantTextItem).text, 'c2');
    });
  });

  group('items', () {
    test('append y update fusionan por id', () {
      var s = subscribed();
      s = apply(s, ItemAppendMessage(item: userItem(1, 'hola')));
      s = apply(s, ItemAppendMessage(item: asstItem(2, 'uno')));
      s = apply(s, ItemUpdateMessage(item: asstItem(2, 'uno dos', id: 'a2')));
      s = apply(s, ItemAppendMessage(item: asstItem(2, 'uno dos', id: 'a2')));
      final items = s.chat('s1').items;
      expect(items.length, 2);
      expect((items[1] as AssistantTextItem).text, 'uno dos');
    });

    test('el update de una tool call cambia su estado', () {
      var s = subscribed();
      final running = ToolCallItem(
        id: 'tu1',
        sessionId: 's1',
        seq: 1,
        timestamp: t(1),
        toolName: 'Bash',
      );
      s = apply(s, ItemAppendMessage(item: running));
      s = apply(
        s,
        ItemUpdateMessage(
          item: running.copyWith(status: ToolStatus.ok, result: 'listo'),
        ),
      );
      final item = s.chat('s1').items.single as ToolCallItem;
      expect(item.status, ToolStatus.ok);
      expect(item.result, 'listo');
    });

    test('items de una sesión sin suscripción no crean chat', () {
      final s = apply(
        const AppState(),
        ItemAppendMessage(item: userItem(1, 'x')),
      );
      expect(s.chats, isEmpty);
    });

    test('el item actualiza lastSeq de la sesión', () {
      var s = const AppState(sessions: [SessionInfo(sessionId: 's1')]);
      s = apply(s, ItemAppendMessage(item: userItem(7, 'x')));
      expect(s.session('s1')!.lastSeq, 7);
    });
  });

  group('prompts provisionales', () {
    Outgoing out(String id, String text, {int after = 1, DateTime? at}) =>
        Outgoing(
          id: '$kLocalPrefix$id',
          sessionId: 's1',
          text: text,
          afterSeq: after,
          sentAt: at ?? t(10),
        );

    AppState sending(List<Outgoing> o) => subscribed().copyWith(
      chats: {
        's1': ChatState(items: [userItem(1, 'Sí')], outgoing: o),
      },
    );

    test('se pintan al final hasta que vuelve el prompt', () {
      var s = sending([out('1', 'Sí')]);
      expect(s.chat('s1').view.map((i) => i.id), ['u1', 'local:1']);
      s = apply(s, ItemAppendMessage(item: asstItem(2, 'sigo')));
      expect(s.chat('s1').view.last.id, 'local:1');
      s = apply(s, ItemAppendMessage(item: userItem(3, '  Sí ')));
      expect(s.chat('s1').outgoing, isEmpty);
      expect(s.chat('s1').view.last.id, 'u3');
    });

    test('un prompt anterior al envío no lo confirma', () {
      final s = apply(
        sending([out('1', 'Sí', after: 5)]),
        BacklogMessage(
          sessionId: 's1',
          items: [userItem(1, 'Sí')],
          cursor: 1,
          hasMore: false,
        ),
      );
      expect(s.chat('s1').outgoing, hasLength(1));
    });

    test('casa por texto y, si no, el más antiguo', () {
      var s = sending([out('1', 'uno'), out('2', 'dos')]);
      s = apply(s, ItemAppendMessage(item: userItem(2, 'dos')));
      expect(s.chat('s1').outgoing.map((o) => o.text), ['uno']);
      s = apply(s, ItemAppendMessage(item: userItem(3, 'reescrito')));
      expect(s.chat('s1').outgoing, isEmpty);
    });

    test('un error justo al enviar quita el provisional', () {
      final s = reduce(
        sending([out('1', 'hola')]),
        const ErrorMessage(
          code: ErrorCode.herdrUnavailable,
          message: 'herdr no responde',
        ),
        now: t(12),
      );
      expect(s.chat('s1').outgoing, isEmpty);
      expect(s.notice, isNotNull);
    });

    test('un error mucho después no lo toca', () {
      final s = reduce(
        sending([out('1', 'hola')]),
        const ErrorMessage(code: ErrorCode.badRequest, message: 'x'),
        now: t(10).add(const Duration(minutes: 1)),
      );
      expect(s.chat('s1').outgoing, hasLength(1));
    });
  });

  group('backlog y paginación', () {
    test('primer backlog fija cursor, hasMore y pendientes', () {
      final p = permissionPending();
      final s = apply(
        subscribed(),
        BacklogMessage(
          sessionId: 's1',
          items: [userItem(5, 'a'), asstItem(6, 'b')],
          cursor: 5,
          hasMore: true,
          pending: [p],
        ),
      );
      final chat = s.chat('s1');
      expect(chat.loaded, isTrue);
      expect(chat.cursor, 5);
      expect(chat.hasMore, isTrue);
      expect(s.pendingOf('s1').single.requestId, 'r1');
    });

    test('la página anterior se antepone y no toca los pendientes', () {
      var s = apply(
        subscribed(),
        BacklogMessage(
          sessionId: 's1',
          items: [userItem(5, 'a'), asstItem(6, 'b')],
          cursor: 5,
          hasMore: true,
          pending: [permissionPending()],
        ),
      );
      s = s.copyWith(chats: {'s1': s.chat('s1').copyWith(loadingOlder: true)});
      s = apply(
        s,
        BacklogMessage(
          sessionId: 's1',
          items: [userItem(3, 'x'), asstItem(4, 'y')],
          cursor: 3,
          hasMore: false,
        ),
      );
      final chat = s.chat('s1');
      expect(chat.items.map((i) => i.seq), [3, 4, 5, 6]);
      expect(chat.cursor, 3);
      expect(chat.hasMore, isFalse);
      expect(chat.loadingOlder, isFalse);
      expect(s.pendingOf('s1'), hasLength(1));
    });

    test('reconexión sin hueco conserva el histórico', () {
      var s = apply(
        subscribed(),
        BacklogMessage(
          sessionId: 's1',
          items: [userItem(1, 'a'), asstItem(2, 'b')],
          cursor: 1,
        ),
      );
      s = apply(
        s,
        BacklogMessage(
          sessionId: 's1',
          items: [asstItem(2, 'b'), userItem(3, 'c')],
          cursor: 2,
          hasMore: true,
        ),
      );
      final chat = s.chat('s1');
      expect(chat.items.map((i) => i.seq), [1, 2, 3]);
      expect(chat.cursor, 1);
      expect(chat.hasMore, isFalse);
    });

    test('reconexión con hueco reemplaza la ventana', () {
      var s = apply(
        subscribed(),
        BacklogMessage(sessionId: 's1', items: [userItem(1, 'a')], cursor: 1),
      );
      s = apply(
        s,
        BacklogMessage(
          sessionId: 's1',
          items: [userItem(50, 'z'), asstItem(51, 'w')],
          cursor: 50,
          hasMore: true,
        ),
      );
      final chat = s.chat('s1');
      expect(chat.items.map((i) => i.seq), [50, 51]);
      expect(chat.hasMore, isTrue);
      expect(chat.cursor, 50);
    });

    test('el backlog inicial sin pendientes limpia los viejos', () {
      var s = apply(subscribed(), PendingMessage(pending: permissionPending()));
      expect(s.pendingOf('s1'), hasLength(1));
      s = apply(s, const BacklogMessage(sessionId: 's1'));
      expect(s.pendingOf('s1'), isEmpty);
    });
  });

  group('pendientes', () {
    test('se añaden, no se duplican y se resuelven', () {
      var s = const AppState();
      s = apply(s, PendingMessage(pending: permissionPending(id: 'r1')));
      s = apply(
        s,
        PendingMessage(
          pending: permissionPending(id: 'r1', tool: 'Edit'),
        ),
      );
      s = apply(s, PendingMessage(pending: permissionPending(id: 'r2')));
      expect(s.pendingOf('s1').map((p) => p.requestId), ['r1', 'r2']);
      expect(s.pendingOf('s1').first.toolName, 'Edit');
      s = apply(
        s,
        const PendingResolvedMessage(
          requestId: 'r1',
          sessionId: 's1',
          resolution: Resolution.allowed,
        ),
      );
      expect(s.pendingOf('s1').map((p) => p.requestId), ['r2']);
      s = apply(
        s,
        const PendingResolvedMessage(
          requestId: 'r2',
          sessionId: '',
          resolution: Resolution.cancelled,
        ),
      );
      expect(s.pending, isEmpty);
    });
  });

  group('sesiones y avisos', () {
    test('hello, sessions y status', () {
      var s = const AppState();
      s = apply(
        s,
        const HelloMessage(
          sessions: [SessionInfo(sessionId: 's1', title: 'A')],
        ),
      );
      expect(s.sessions.single.title, 'A');
      s = apply(
        s,
        const StatusMessage(sessionId: 's1', status: SessionStatus.working),
      );
      expect(s.session('s1')!.status, SessionStatus.working);
      s = apply(s, const SessionsMessage(sessions: []));
      expect(s.sessions, isEmpty);
    });

    test('un error genera un aviso con id creciente', () {
      var s = const AppState();
      s = apply(
        s,
        const ErrorMessage(code: ErrorCode.agentBlocked, message: 'Bloqueado'),
      );
      s = apply(
        s,
        const ErrorMessage(code: ErrorCode.agentBlocked, message: 'Bloqueado'),
      );
      expect(s.notice!.id, 2);
      expect(s.notice!.message, 'Bloqueado');
    });
  });

  group('revisión', () {
    test('hello vacía los pendientes', () {
      var s = apply(subscribed(), PendingMessage(pending: permissionPending()));
      expect(s.pending, isNotEmpty);
      s = apply(
        s,
        const HelloMessage(sessions: [SessionInfo(sessionId: 's1')]),
      );
      expect(s.pending, isEmpty);
    });

    test('unknown_session libera loadingOlder', () {
      var s = const AppState().copyWith(
        chats: {
          's1': const ChatState(loadingOlder: true, awaitingInitial: true),
        },
      );
      s = apply(
        s,
        const ErrorMessage(code: ErrorCode.unknownSession, message: 'x'),
      );
      expect(s.chat('s1').loadingOlder, isFalse);
      expect(s.chat('s1').awaitingInitial, isFalse);
    });

    test('el backlog inicial limpia awaitingInitial', () {
      var s = const AppState().copyWith(
        chats: {'s1': const ChatState(awaitingInitial: true)},
      );
      s = apply(
        s,
        BacklogMessage(sessionId: 's1', items: [userItem(1, 'a')], cursor: 1),
      );
      expect(s.chat('s1').awaitingInitial, isFalse);
    });

    test('sesión suscrita que desaparece pierde su chat', () {
      var s = subscribed();
      s = apply(s, const SessionsMessage(sessions: []));
      expect(s.chats, isEmpty);
    });

    test('describeError oculta el token', () {
      final t = describeError(
        Exception(
          "Connection to 'http://h:1/?token=abc123&x=1' was not upgraded",
        ),
        null,
      );
      expect(t.contains('abc123'), isFalse);
    });
  });
}
