import 'dart:convert';

import 'package:test/test.dart';
import 'package:therd_protocol/protocol.dart';

final t0 = DateTime.utc(2026, 11, 18, 10, 30, 15);

const q = QuestionSpec(
  question: '¿Qué framework?',
  header: 'Framework',
  options: [
    QuestionOption(label: 'React', description: 'UI'),
    QuestionOption(label: 'Vue'),
  ],
  multiSelect: true,
);

final items = <ChatItem>[
  UserPromptItem(id: 'u1', sessionId: 's', seq: 1, timestamp: t0, text: 'hola'),
  UserPromptItem(
    id: 'u2',
    sessionId: 's',
    seq: 1,
    timestamp: t0,
    text: '',
    images: ['ab12'],
  ),
  AssistantTextItem(
    id: 'a1',
    sessionId: 's',
    seq: 2,
    timestamp: t0,
    text: '**md**',
  ),
  ThinkingItem(id: 't1', sessionId: 's', seq: 3, timestamp: t0, text: 'pienso'),
  ToolCallItem(
    id: 'toolu_1',
    sessionId: 's',
    seq: 4,
    timestamp: t0,
    toolName: 'Bash',
    input: {'command': 'ls', 'n': 1},
    status: ToolStatus.error,
    result: 'fallo',
    isError: true,
    durationMs: 120,
    images: ['cd34'],
  ),
  ToolCallItem(
    id: 'toolu_2',
    sessionId: 's',
    seq: 5,
    timestamp: t0,
    toolName: 'Read',
  ),
  PermissionItem(
    id: 'p1',
    sessionId: 's',
    seq: 6,
    timestamp: t0,
    requestId: 'r1',
    toolName: 'Bash',
    toolInput: {'command': 'git push'},
    resolution: Resolution.allowed,
  ),
  QuestionItem(
    id: 'q1',
    sessionId: 's',
    seq: 7,
    timestamp: t0,
    requestId: 'r2',
    questions: [q],
    answers: {'¿Qué framework?': 'React, Vue'},
    resolution: Resolution.answered,
  ),
  PlanItem(
    id: 'pl1',
    sessionId: 's',
    seq: 8,
    timestamp: t0,
    requestId: 'r3',
    plan: '# Plan',
  ),
  MarkerItem(
    id: 'm1',
    sessionId: 's',
    seq: 9,
    timestamp: t0,
    kind: MarkerKind.turnEnd,
    durationMs: 5000,
  ),
  MarkerItem(
    id: 'm2',
    sessionId: 's',
    seq: 10,
    timestamp: t0,
    kind: MarkerKind.compact,
    text: 'c',
  ),
  ToolCallItem(
    id: 'toolu_3',
    sessionId: 's',
    seq: 11,
    timestamp: t0,
    toolName: 'Task',
    input: {'subagent_type': 'Explore', 'description': 'Buscar'},
    subagent: SubagentInfo(
      agentId: 'a1',
      steps: [
        SubagentStep(
          id: 'toolu_x',
          name: 'Grep',
          input: {'pattern': 'foo'},
          status: ToolStatus.ok,
        ),
        SubagentStep(id: 'toolu_y', name: 'Read'),
      ],
      toolCount: 7,
      finished: true,
      durationMs: 4200,
      finalText: 'Hecho',
    ),
  ),
];

final session = SessionInfo(
  sessionId: 's',
  paneId: 'w1:p1',
  workspaceId: 'w1',
  title: 'Título',
  cwd: '/tmp',
  branch: 'main',
  status: SessionStatus.working,
  model: 'opus',
  mode: 'plan',
  lastSeq: 10,
  seenSeq: 7,
);

final pending = Pending(
  requestId: 'r1',
  sessionId: 's',
  kind: PendingKind.question,
  toolName: 'AskUserQuestion',
  toolInput: {'a': 1},
  suggestions: [
    {'type': 'addRules', 'destination': 'localSettings'},
  ],
  questions: [q],
  plan: 'p',
  createdAt: t0,
);

final server = <ServerMessage>[
  HelloMessage(sessions: [session]),
  SessionsMessage(sessions: [session]),
  BacklogMessage(
    sessionId: 's',
    items: items,
    cursor: 1,
    hasMore: true,
    pending: [pending],
  ),
  ItemAppendMessage(item: items[3]),
  ItemUpdateMessage(item: items[4]),
  const StatusMessage(sessionId: 's', status: SessionStatus.blocked),
  PendingMessage(pending: pending),
  const PendingResolvedMessage(
    requestId: 'r1',
    sessionId: 's',
    resolution: Resolution.cancelled,
  ),
  const ErrorMessage(
    code: ErrorCode.agentBlocked,
    message: 'bloqueado',
    requestId: 's',
  ),
  const PongMessage(),
  const SeenMessage(sessionId: 's1', seq: 9),
];

const client = <ClientMessage>[
  AuthMessage(token: 'tok'),
  SubscribeMessage(sessionId: 's', before: 5, limit: 50),
  SubscribeMessage(sessionId: 's'),
  UnsubscribeMessage(sessionId: 's'),
  PromptMessage(sessionId: 's', text: 'hola\nmundo'),
  PromptMessage(
    sessionId: 's',
    text: '',
    images: [PromptImage(mime: 'image/png', data: 'iVBORw0K')],
  ),
  InterruptMessage(sessionId: 's'),
  PermissionMessage(requestId: 'r', allow: true, always: true),
  PermissionMessage(requestId: 'r', allow: false, message: 'no'),
  AnswerMessage(requestId: 'r', answers: {'¿Qué?': 'A'}),
  ReleaseMessage(requestId: 'r'),
  PingMessage(),
  MarkSeenMessage(sessionId: 's1', seq: 9),
  PushRegisterMessage(endpoint: 'http://h/up1?up=1', previous: 'http://h/up0'),
  PushUnregisterMessage(endpoint: 'http://h/up1?up=1'),
];

void main() {
  group('items', () {
    for (final it in items) {
      test('ida y vuelta ${it.type} ${it.id}', () {
        final json =
            jsonDecode(jsonEncode(it.toJson())) as Map<String, dynamic>;
        final back = ChatItem.fromJson(json);
        expect(back.runtimeType, it.runtimeType);
        expect(jsonEncode(back.toJson()), jsonEncode(it.toJson()));
        expect(back.timestamp, t0);
      });
    }

    test('tipo desconocido da UnknownItem y conserva el JSON', () {
      final raw = {
        'type': 'futuro',
        'id': 'x',
        'sessionId': 's',
        'seq': 3,
        'foo': 1,
      };
      final it = ChatItem.fromJson(raw);
      expect(it, isA<UnknownItem>());
      expect(it.toJson(), raw);
    });

    test('campos ausentes no lanzan', () {
      final it = ChatItem.fromJson({'type': 'tool_call'});
      expect(it, isA<ToolCallItem>());
      expect((it as ToolCallItem).status, ToolStatus.running);
    });

    test('copyWith de ToolCallItem', () {
      final c = (items[5] as ToolCallItem).copyWith(
        status: ToolStatus.ok,
        result: 'fin',
      );
      expect(c.id, 'toolu_2');
      expect(c.status, ToolStatus.ok);
      expect(c.result, 'fin');
    });

    test('subagente: sin el campo se queda en null y no se serializa', () {
      expect((items[5] as ToolCallItem).subagent, isNull);
      expect(items[5].toJson().containsKey('subagent'), isFalse);
      final t = items.last as ToolCallItem;
      expect(t.subagent!.steps.last.status, ToolStatus.running);
      expect(t.copyWith(status: ToolStatus.ok).subagent, t.subagent);
    });
  });

  group('modelos', () {
    test('SessionInfo', () {
      final back = SessionInfo.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(back.toJson(), session.toJson());
    });
    test('Pending', () {
      final back = Pending.fromJson(
        jsonDecode(jsonEncode(pending.toJson())) as Map<String, dynamic>,
      );
      expect(back.toJson(), pending.toJson());
      expect(back.questions.single.multiSelect, isTrue);
    });
    test('enums desconocidos caen a valor por defecto', () {
      expect(SessionStatus.parse('raro'), SessionStatus.unknown);
      expect(MarkerKind.parse('raro'), MarkerKind.other);
    });
  });

  group('mensajes', () {
    for (final m in [...server, ...client]) {
      test('ida y vuelta ${m.type} (${m.runtimeType})', () {
        final back = decodeMessage(m.encode());
        expect(back.runtimeType, m.runtimeType);
        expect(back.encode(), m.encode());
        expect(back, isNot(isA<UnknownMessage>()));
      });
    }

    test('valores de type son únicos', () {
      final types = {
        for (final m in [...server, ...client]) m.runtimeType: m.type,
      }.values.toList();
      expect(types.toSet().length, types.length);
    });

    test('tipo desconocido da UnknownMessage', () {
      final m = decodeMessage('{"type":"nuevo","x":1}');
      expect(m, isA<UnknownMessage>());
      expect((m as UnknownMessage).rawType, 'nuevo');
      expect(m.toJson(), {'type': 'nuevo', 'x': 1});
    });

    test('JSON roto o no objeto no lanza', () {
      expect(decodeMessage('no es json'), isA<UnknownMessage>());
      expect(decodeMessage('[1,2]'), isA<UnknownMessage>());
      expect(decodeMessage('{}'), isA<UnknownMessage>());
    });

    test('cuerpo inválido de un tipo conocido da UnknownMessage', () {
      expect(decodeMessage('{"type":"prompt"}'), isA<UnknownMessage>());
    });

    test('switch exhaustivo sobre Message', () {
      String name(Message m) => switch (m) {
        HelloMessage() => 'hello',
        SessionsMessage() => 'sessions',
        BacklogMessage() => 'backlog',
        ItemAppendMessage() => 'item.append',
        ItemUpdateMessage() => 'item.update',
        StatusMessage() => 'status',
        PendingMessage() => 'pending',
        PendingResolvedMessage() => 'pending.resolved',
        ErrorMessage() => 'error',
        PongMessage() => 'pong',
        SeenMessage() => 'seen',
        MarkSeenMessage() => 'mark_seen',
        AuthMessage() => 'auth',
        SubscribeMessage() => 'subscribe',
        UnsubscribeMessage() => 'unsubscribe',
        PromptMessage() => 'prompt',
        InterruptMessage() => 'interrupt',
        PermissionMessage() => 'permission',
        AnswerMessage() => 'answer',
        ReleaseMessage() => 'release',
        PingMessage() => 'ping',
        PushRegisterMessage() => 'push_register',
        PushUnregisterMessage() => 'push_unregister',
        UnknownMessage() => 'unknown',
      };
      for (final m in [...server, ...client]) {
        expect(name(m), m.type);
      }
    });

    test('avisos push de ida y vuelta', () {
      const payloads = <PushPayload>[
        PushPending(
          requestId: 'r',
          sessionId: 's',
          kind: PendingKind.plan,
          title: 'Plan para revisar',
          body: 'therd\nRefactor',
          canAlways: true,
        ),
        PushResolved(requestId: 'r'),
        PushTurnDone(sessionId: 's', title: 'Terminado: therd', body: 'Hecho'),
        PushTurnCleared(sessionId: 's'),
      ];
      for (final p in payloads) {
        final back = PushPayload.fromJson(p.toJson())!;
        expect(back.runtimeType, p.runtimeType);
        expect(back.toJson(), p.toJson());
      }
      expect(PushPayload.fromJson({'type': 'otro'}), isNull);
    });

    test('protocolVersion en hello', () {
      expect(const HelloMessage().toJson()['version'], protocolVersion);
      expect(protocolVersion, 2);
    });

    test('hello roundtrip con versión', () {
      final back =
          Message.fromJson(const HelloMessage(version: 2).toJson())
              as HelloMessage;
      expect(back.version, 2);
    });

    test('hello sin versión cuenta como 1', () {
      final json = const HelloMessage().toJson()..remove('version');
      final back = Message.fromJson(json) as HelloMessage;
      expect(back.version, 1);
    });
  });
}
