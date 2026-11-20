import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/ui/chat_items.dart';
import 'package:therd/src/ui/chat_screen.dart';
import 'package:therd/src/ui/composer.dart';
import 'package:therd/src/ui/pending_bar.dart';
import 'package:therd/src/ui/theme.dart';
import 'package:therd/src/ui/tool_card.dart';
import 'package:therd_protocol/protocol.dart';

import 'support/fakes.dart';

const cfg = ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'tk');

/// Monta el chat de la sesión s1 con un cliente falso ya conectado.
Future<FakeClient> pumpChat(
  WidgetTester tester, {
  List<ChatItem> items = const [],
  List<Pending> pending = const [],
  SessionStatus status = SessionStatus.idle,
}) async {
  final client = FakeClient();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientProvider.overrideWithValue(client),
        settingsStoreProvider.overrideWithValue(MemorySettingsStore(cfg)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ChatScreen(sessionId: 's1'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  client
    ..emit(
      HelloMessage(
        sessions: [
          SessionInfo(sessionId: 's1', title: 'Prueba', status: status),
        ],
      ),
    )
    ..emit(
      BacklogMessage(
        sessionId: 's1',
        items: items,
        cursor: items.isEmpty ? 0 : items.first.seq,
        pending: pending,
      ),
    );
  await tester.pump();
  await tester.pump();
  return client;
}

void main() {
  testWidgets(
    'tarjeta de permiso: Permitir, Permitir siempre y Contestar en el PC',
    (tester) async {
      final client = await pumpChat(
        tester,
        pending: [
          permissionPending(
            suggestions: [
              {'type': 'addRules'},
            ],
          ),
        ],
      );
      expect(find.text('Permiso para ejecutar un comando'), findsOneWidget);
      expect(find.text('git push origin main'), findsOneWidget);
      expect(find.text('Permitir siempre'), findsOneWidget);

      await tester.tap(find.text('Permitir siempre'));
      await tester.pump();
      var m = client.sentOf<PermissionMessage>().single;
      expect((m.requestId, m.allow, m.always), ('r1', true, true));

      await tester.tap(find.text('Permitir'));
      await tester.pump();
      m = client.sentOf<PermissionMessage>().last;
      expect((m.allow, m.always), (true, false));

      await tester.tap(find.text('Contestar en el PC'));
      await tester.pump();
      expect(client.sentOf<ReleaseMessage>().single.requestId, 'r1');
    },
  );

  testWidgets(
    'sin suggestions no hay Permitir siempre; Denegar lleva mensaje',
    (tester) async {
      final client = await pumpChat(tester, pending: [permissionPending()]);
      expect(find.text('Permitir siempre'), findsNothing);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Denegar'));
      await tester.pumpAndSettle();
      expect(find.text('Motivo para Claude (opcional)'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(PermissionCard),
          matching: find.byType(TextField),
        ),
        'demasiado arriesgado',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Denegar'));
      await tester.pumpAndSettle();
      final m = client.sentOf<PermissionMessage>().single;
      expect(m.allow, isFalse);
      expect(m.message, 'demasiado arriesgado');
    },
  );

  testWidgets('con pendiente la hoja sustituye a la caja de texto', (
    tester,
  ) async {
    await pumpChat(tester, pending: [permissionPending()]);
    expect(find.byType(PendingBar), findsOneWidget);
    expect(find.byType(Composer), findsNothing);
    expect(find.text('Escribe a Claude'), findsNothing);
  });

  testWidgets('pending.resolved retira la barra y reactiva el composer', (
    tester,
  ) async {
    final client = await pumpChat(tester, pending: [permissionPending()]);
    client.emit(
      const PendingResolvedMessage(
        requestId: 'r1',
        sessionId: 's1',
        resolution: Resolution.cancelled,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Permiso para ejecutar un comando'), findsNothing);
    expect(find.text('Escribe a Claude'), findsOneWidget);
  });

  testWidgets('pregunta: opción única, multiSelect y texto libre Otra', (
    tester,
  ) async {
    final q = Pending(
      requestId: 'q1',
      sessionId: 's1',
      kind: PendingKind.question,
      toolName: 'AskUserQuestion',
      createdAt: t(1),
      questions: const [
        QuestionSpec(
          question: '¿Qué framework?',
          header: 'Framework',
          options: [
            QuestionOption(label: 'React', description: 'Biblioteca de UI'),
            QuestionOption(label: 'Vue'),
          ],
        ),
        QuestionSpec(
          question: '¿Qué extras?',
          multiSelect: true,
          options: [
            QuestionOption(label: 'Tests'),
            QuestionOption(label: 'Lint'),
          ],
        ),
      ],
    );
    final client = await pumpChat(tester, pending: [q]);
    expect(find.text('¿Qué framework?'), findsOneWidget);
    expect(find.text('Biblioteca de UI'), findsOneWidget);

    // Sin responder todo, Enviar está desactivado.
    FilledButton send() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Enviar respuesta'),
    );
    expect(send().onPressed, isNull);

    // La hoja mide como mucho media pantalla y hace scroll interno.
    Future<void> tapScrolled(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
      await tester.pump();
    }

    await tapScrolled(find.text('React'));
    await tapScrolled(find.text('Tests'));
    await tapScrolled(find.text('Lint'));
    expect(send().onPressed, isNotNull);

    // Otra en la pregunta única sustituye a React.
    await tapScrolled(find.text('Otra').first);
    await tester.enterText(
      find.descendant(
        of: find.byType(QuestionCard),
        matching: find.byType(TextField),
      ),
      'Svelte',
    );
    await tester.pump();

    await tester.tap(find.text('Enviar respuesta'));
    await tester.pump();
    final a = client.sentOf<AnswerMessage>().single;
    expect(a.requestId, 'q1');
    expect(a.answers, {
      '¿Qué framework?': 'Svelte',
      '¿Qué extras?': 'Tests, Lint',
    });
  });

  testWidgets('con el teclado abierto la hoja de pregunta no desborda', (
    tester,
  ) async {
    final q = Pending(
      requestId: 'q2',
      sessionId: 's1',
      kind: PendingKind.question,
      toolName: 'AskUserQuestion',
      createdAt: t(1),
      questions: const [
        QuestionSpec(
          question: '¿Qué verduras?',
          multiSelect: true,
          options: [
            QuestionOption(label: 'Tomate', description: 'Rojo'),
            QuestionOption(label: 'Lechuga', description: 'Verde'),
            QuestionOption(label: 'Pimiento', description: 'Varios'),
          ],
        ),
      ],
    );
    await pumpChat(tester, pending: [q]);
    await tester.ensureVisible(find.text('Otra'));
    await tester.pump();
    await tester.tap(find.text('Otra'));
    await tester.pump();
    // Teclado: la mitad inferior de la pantalla.
    tester.view.viewInsets = FakeViewPadding(
      bottom: tester.view.physicalSize.height / 2,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Enviar respuesta'), findsOneWidget);
  });

  testWidgets('plan: Aprobar y Rechazar con feedback', (tester) async {
    final plan = Pending(
      requestId: 'p1',
      sessionId: 's1',
      kind: PendingKind.plan,
      toolName: 'ExitPlanMode',
      plan: '# Plan\n\n- paso uno',
      createdAt: t(1),
    );
    final client = await pumpChat(tester, pending: [plan]);
    expect(find.text('Claude propone un plan'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Rechazar'));
    await tester.pumpAndSettle();
    expect(find.text('Qué cambiarías (opcional)'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(PlanCard),
        matching: find.byType(TextField),
      ),
      'Falta el paso de tests',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Rechazar'));
    await tester.pumpAndSettle();
    final m = client.sentOf<PermissionMessage>().single;
    expect(
      (m.requestId, m.allow, m.message),
      ('p1', false, 'Falta el paso de tests'),
    );

    // Tras enviar el rechazo la hoja sigue montada en el test (sin backlog nuevo).
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancelar'));
    await tester.pump();
    await tester.tap(find.text('Aprobar'));
    await tester.pump();
    expect(client.sentOf<PermissionMessage>().last.allow, isTrue);
  });

  testWidgets('ToolCall de Edit muestra el mini diff al expandir', (
    tester,
  ) async {
    final edit = ToolCallItem(
      id: 'tu1',
      sessionId: 's1',
      seq: 2,
      timestamp: t(2),
      toolName: 'Edit',
      status: ToolStatus.ok,
      durationMs: 1200,
      input: const {
        'file_path': '/home/user/proyecto/lib/main.dart',
        'old_string': 'final a = 1;',
        'new_string': 'final a = 2;\nfinal b = 3;',
      },
    );
    await pumpChat(tester, items: [userItem(1, 'cambia a'), edit]);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('/home/user/proyecto/lib/main.dart'), findsOneWidget);
    expect(find.text('- final a = 1;'), findsNothing);

    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(find.text('- final a = 1;'), findsOneWidget);
    expect(find.text('+ final a = 2;'), findsOneWidget);
    expect(find.text('+ final b = 3;'), findsOneWidget);
  });

  testWidgets('nombre MCP largo se acorta y no desborda la cabecera', (
    tester,
  ) async {
    final mcp = ToolCallItem(
      id: 'tu3',
      sessionId: 's1',
      seq: 2,
      timestamp: t(2),
      toolName: 'mcp__claude_ai_Gmail__search_threads_with_a_very_long_name',
      status: ToolStatus.ok,
      durationMs: 1600,
      input: const {'query': 'certificado de representación de Logalty'},
    );
    await pumpChat(tester, items: [userItem(1, 'busca'), mcp]);
    expect(tester.takeException(), isNull);
    expect(
      find.text('Gmail: search_threads_with_a_very_long_name'),
      findsOneWidget,
    );
  });

  testWidgets('ToolCall de Bash muestra comando y salida', (tester) async {
    final bash = ToolCallItem(
      id: 'tu2',
      sessionId: 's1',
      seq: 1,
      timestamp: t(1),
      toolName: 'Bash',
      status: ToolStatus.ok,
      result: 'dos\ntres',
      input: const {'command': 'ls -la'},
    );
    await pumpChat(tester, items: [bash]);
    await tester.tap(find.text('Bash'));
    await tester.pump();
    expect(find.text('\$ ls -la'), findsOneWidget);
    expect(find.text('dos\ntres'), findsOneWidget);
  });

  testWidgets('Stop sustituye a Enviar mientras trabaja y manda interrupt', (
    tester,
  ) async {
    final client = await pumpChat(tester, status: SessionStatus.working);
    expect(find.byTooltip('Enviar'), findsNothing);
    await tester.tap(find.byTooltip('Detener'));
    await tester.pump();
    expect(client.sentOf<InterruptMessage>().single.sessionId, 's1');
  });

  testWidgets('enviar un prompt y mostrar el error agent_blocked', (
    tester,
  ) async {
    final client = await pumpChat(tester);
    await tester.enterText(find.byType(TextField), 'haz algo');
    await tester.pump();
    await tester.tap(find.byTooltip('Enviar'));
    await tester.pump();
    expect(client.sentOf<PromptMessage>().single.text, 'haz algo');

    client.emit(
      const ErrorMessage(
        code: ErrorCode.agentBlocked,
        message: 'Claude espera una respuesta en el PC',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Claude espera una respuesta en el PC'), findsOneWidget);
  });

  testWidgets('markers, thinking plegado y burbuja de usuario', (tester) async {
    await pumpChat(
      tester,
      items: [
        userItem(1, 'hola'),
        ThinkingItem(
          id: 'th',
          sessionId: 's1',
          seq: 2,
          timestamp: t(2),
          text: 'pienso en voz alta',
        ),
        MarkerItem(
          id: 'm',
          sessionId: 's1',
          seq: 3,
          timestamp: t(3),
          kind: MarkerKind.compact,
        ),
      ],
    );
    expect(find.text('hola'), findsOneWidget);
    expect(find.text('Conversación compactada'), findsOneWidget);
    expect(find.text('pienso en voz alta'), findsNothing);
    await tester.tap(find.text('Pensando'));
    await tester.pump();
    expect(find.text('pienso en voz alta'), findsOneWidget);
  });

  testWidgets('herramientas consecutivas van en una sola tarjeta', (
    tester,
  ) async {
    ToolCallItem tool(int seq, String name) => ToolCallItem(
      id: 'k$seq',
      sessionId: 's1',
      seq: seq,
      timestamp: t(seq),
      toolName: name,
      status: ToolStatus.ok,
      input: const {'command': 'ls'},
    );
    final items = <ChatItem>[
      userItem(1, 'hola'),
      ThinkingItem(
        id: 'th',
        sessionId: 's1',
        seq: 2,
        timestamp: t(2),
        text: 'x',
      ),
      tool(3, 'Bash'),
      tool(4, 'Read'),
      userItem(5, 'otra'),
      tool(6, 'Grep'),
    ];
    final rows = groupChatItems(items);
    expect(rows.map((r) => r.items.length), [1, 3, 1, 1]);
    expect(rows.map((r) => r.isGroup), [false, true, false, true]);

    await pumpChat(tester, items: items);
    expect(find.byType(ToolGroupCard), findsNWidgets(2));
    expect(find.text('Pensando'), findsOneWidget);
    expect(find.text('Tú'), findsNWidgets(2));
  });

  testWidgets('respuestas rápidas con Claude libre envían su texto', (
    tester,
  ) async {
    final client = await pumpChat(tester, items: [userItem(1, 'hola')]);
    expect(find.text('Continúa'), findsOneWidget);
    await tester.tap(find.text('Continúa'));
    await tester.pump();
    expect(client.sentOf<PromptMessage>().single.text, 'Continúa');
  });

  testWidgets('trabajando sale «Pensando» al final del chat', (tester) async {
    await pumpChat(
      tester,
      items: [userItem(1, 'hola')],
      status: SessionStatus.working,
    );
    await tester.pump();
    expect(find.byType(ThinkingIndicator), findsOneWidget);
  });

  final many = [for (var i = 1; i <= 20; i++) userItem(i, 'mensaje $i')];

  testWidgets('lo que llega mientras se lee no mueve la vista', (tester) async {
    final client = await pumpChat(tester, items: many);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('mensaje 16'));

    client.emit(ItemAppendMessage(item: asstItem(21, 'respuesta nueva')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('mensaje 16')), before);
    expect(find.text('1 mensaje nuevo'), findsOneWidget);
  });

  testWidgets('un prompt nuevo estando abajo sube arriba del todo', (
    tester,
  ) async {
    final client = await pumpChat(tester, items: many);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('mensaje 20')).dy, greaterThan(300));

    client.emit(ItemAppendMessage(item: userItem(21, 'turno nuevo')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('turno nuevo')).dy, lessThan(150));

    // La respuesta aparece debajo sin mover el turno.
    final pinned = tester.getTopLeft(find.text('turno nuevo'));
    client.emit(ItemAppendMessage(item: asstItem(22, 'debajo')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('turno nuevo')), pinned);
  });

  testWidgets('lo enviado sale al momento y su confirmación no lo mueve', (
    tester,
  ) async {
    final client = await pumpChat(tester, items: many);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continúa'));
    await tester.pumpAndSettle();
    expect(client.sentOf<PromptMessage>().single.text, 'Continúa');
    final sending = find.text('Enviando');
    expect(sending, findsOneWidget);
    final pinned = tester.getTopLeft(sending);
    expect(pinned.dy, lessThan(150));

    client.emit(ItemAppendMessage(item: userItem(21, 'Continúa')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Enviando'), findsNothing);
    // El prompt real ocupa el sitio del provisional, sin animar ni saltar.
    final tu = find.text('Tú').last;
    expect(tester.getTopLeft(tu).dy, pinned.dy);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(tu).dy, pinned.dy);
  });

  testWidgets('trabajando no hay respuestas rápidas', (tester) async {
    await pumpChat(
      tester,
      items: [userItem(1, 'hola')],
      status: SessionStatus.working,
    );
    expect(find.text('Continúa'), findsNothing);
  });

  group('tarjeta de subagente', () {
    ToolCallItem task({
      ToolStatus status = ToolStatus.ok,
      SubagentInfo? sub,
      String name = 'Agent',
      Map<String, dynamic>? input,
    }) => ToolCallItem(
      id: 'task1',
      sessionId: 's1',
      seq: 2,
      timestamp: t(2),
      toolName: name,
      status: status,
      result: 'Resultado del Task',
      input:
          input ??
          const {
            'subagent_type': 'Explore',
            'description': 'Buscar el cliente HTTP',
            'prompt': 'Localiza dónde se crea el cliente HTTP.',
          },
      subagent: sub,
    );

    const steps = [
      SubagentStep(
        id: 'a',
        name: 'Grep',
        input: {'pattern': 'HttpClient'},
        status: ToolStatus.ok,
      ),
      SubagentStep(
        id: 'b',
        name: 'Read',
        input: {'file_path': '/p/client.dart'},
      ),
    ];

    testWidgets('trabajando: plegada muestra lo último que hace', (
      tester,
    ) async {
      final item = task(
        status: ToolStatus.running,
        sub: const SubagentInfo(
          agentId: 'a1',
          steps: steps,
          toolCount: 2,
          durationMs: 3000,
        ),
      );
      await pumpChat(tester, items: [userItem(1, 'busca'), item]);
      expect(find.text('Explore'), findsOneWidget);
      expect(find.text('Buscar el cliente HTTP'), findsOneWidget);
      expect(find.text('Trabajando'), findsOneWidget);
      expect(find.text('3.0 s'), findsOneWidget);
      expect(find.text('Read /p/client.dart'), findsOneWidget);
      expect(find.text('Prompt'), findsNothing);
      expect(find.text('Hecho'), findsNothing);
    });

    testWidgets('hecha y desplegada: prompt, herramientas y respuesta', (
      tester,
    ) async {
      final item = task(
        sub: const SubagentInfo(
          agentId: 'a1',
          steps: [
            SubagentStep(
              id: 'a',
              name: 'Grep',
              input: {'pattern': 'HttpClient'},
              status: ToolStatus.ok,
            ),
            SubagentStep(
              id: 'b',
              name: 'Bash',
              input: {'command': 'cat falta.txt'},
              status: ToolStatus.error,
            ),
          ],
          toolCount: 2,
          finished: true,
          durationMs: 8000,
          finalText: 'Se crea en **client.dart**',
        ),
      );
      await pumpChat(tester, items: [userItem(1, 'busca'), item]);
      expect(find.text('Hecho'), findsOneWidget);
      expect(find.text('2 herramientas'), findsOneWidget);
      expect(find.text('Respuesta'), findsNothing);

      await tester.tap(find.text('Explore'));
      await tester.pump();
      expect(find.text('Prompt'), findsOneWidget);
      expect(
        find.text('Localiza dónde se crea el cliente HTTP.'),
        findsOneWidget,
      );
      expect(find.text('HttpClient'), findsOneWidget);
      expect(find.text('cat falta.txt'), findsOneWidget);
      expect(find.text('Respuesta'), findsOneWidget);
      expect(find.byType(TherdMarkdown), findsOneWidget);
    });

    testWidgets('sin subagent_type se llama Subagente; Task también', (
      tester,
    ) async {
      final item = task(name: 'Task', input: const {'description': 'Algo'});
      await pumpChat(tester, items: [userItem(1, 'x'), item]);
      expect(find.text('Subagente'), findsOneWidget);
      expect(find.text('Hecho'), findsOneWidget);
    });

    testWidgets('en segundo plano manda el subagente aunque el Task esté ok', (
      tester,
    ) async {
      final item = task(
        sub: const SubagentInfo(agentId: 'a1', steps: steps, toolCount: 2),
      );
      await pumpChat(tester, items: [userItem(1, 'x'), item]);
      expect(find.text('Trabajando'), findsOneWidget);
    });

    testWidgets('error del Task', (tester) async {
      final item = task(status: ToolStatus.error);
      await pumpChat(tester, items: [userItem(1, 'x'), item]);
      expect(find.text('Error'), findsOneWidget);
    });

    testWidgets('corta el grupo de herramientas', (tester) async {
      ToolCallItem tool(int seq) => ToolCallItem(
        id: 'tt$seq',
        sessionId: 's1',
        seq: seq,
        timestamp: t(seq),
        toolName: 'Read',
        status: ToolStatus.ok,
      );
      final rows = groupChatItems([tool(1), task(), tool(3)]);
      expect(rows, hasLength(3));
      expect(rows[1].isGroup, isFalse);
    });
  });
}
