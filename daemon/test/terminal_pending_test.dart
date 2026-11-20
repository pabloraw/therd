import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/hook_event.dart';
import 'package:therd_daemon/src/hook_router.dart';
import 'package:therd_daemon/src/pending.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_daemon/src/transcript_tailer.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

String fixture(String name) =>
    File('test/fixtures/$name.txt').readAsStringSync();

void main() {
  late SessionStore store;
  late PendingManager pendings;
  late TranscriptHub hub;
  late HookRouter router;
  late FakeTerminal term;

  setUp(() {
    store = SessionStore()..upsertSession('s1', paneId: 'w1:p1');
    pendings = PendingManager(timeout: const Duration(seconds: 5));
    hub = TranscriptHub(store);
    term = FakeTerminal(fixture('permiso_bash'));
    router = HookRouter(
      store: store,
      hub: hub,
      pendings: pendings,
      projectsDir: '/tmp/no-existe',
      plansDir: '/tmp/no-existe/plans',
      hasClients: () => false,
      terminal: term,
      terminalPoll: const Duration(milliseconds: 10),
      keyPause: Duration.zero,
      confirmAttempts: 5,
      planFallbackDelay: const Duration(milliseconds: 30),
    );
  });

  tearDown(() async {
    router.dispose();
    await hub.stop();
    pendings.dispose();
  });

  HookEvent permission({
    String tool = 'Bash',
    Map<String, dynamic> input = const {'command': 'touch prueba.txt'},
    List<Map<String, dynamic>> suggestions = const [],
  }) => HookEvent(
    name: 'PermissionRequest',
    sessionId: 's1',
    paneId: 'w1:p1',
    toolName: tool,
    toolInput: input,
    raw: {'permission_suggestions': suggestions},
  );

  final questions = [
    {
      'question': '¿Cuál es tu color favorito?',
      'header': 'Color',
      'options': [
        {'label': 'Rojo'},
        {'label': 'Verde'},
        {'label': 'Azul'},
      ],
    },
  ];

  HookEvent ask() => HookEvent(
    name: 'PreToolUse',
    sessionId: 's1',
    paneId: 'w1:p1',
    toolName: 'AskUserQuestion',
    toolUseId: 'tu-q',
    toolInput: {'questions': questions},
  );

  Future<Pending> waitPending() async {
    for (var i = 0; i < 200; i++) {
      final open = pendings.forSession('s1');
      if (open.isNotEmpty) return open.single;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no se abrió el pendiente');
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  group('hook que no se retiene (sin app)', () {
    test(
      'permiso: abre un pendiente con el mismo contenido que el retenido',
      () async {
        const sug = {'type': 'addRules', 'behavior': 'allow'};
        router.onEvent(permission(suggestions: [sug]));
        final p = await waitPending();
        expect(p.kind, PendingKind.permission);
        expect(p.toolName, 'Bash');
        expect(p.toolInput['command'], 'touch prueba.txt');
        expect(p.suggestions, [sug]);
        expect(store.info('s1')!.status, SessionStatus.blocked);
        final item = store.itemsOf('s1').whereType<PermissionItem>().single;
        expect(item.requestId, p.requestId);
        expect(item.resolution, isNull);
      },
    );

    test('permitir pulsa 1 y marca la tarjeta', () async {
      router.onEvent(permission());
      final p = await waitPending();
      pendings.respondPermission(p.requestId, allow: true);
      await settle();
      expect(term.sent, [
        ['1'],
      ]);
      final item = store.itemsOf('s1').whereType<PermissionItem>().single;
      expect(item.resolution, Resolution.allowed);
    });

    test('permitir siempre pulsa la opción 2 si hay sugerencias', () async {
      router.onEvent(
        permission(
          suggestions: [
            {'type': 'addRules'},
          ],
        ),
      );
      final p = await waitPending();
      pendings.respondPermission(p.requestId, allow: true, always: true);
      await settle();
      expect(term.sent, [
        ['2'],
      ]);
    });

    test('siempre sin sugerencias se queda en permitir una vez', () async {
      router.onEvent(permission());
      final p = await waitPending();
      pendings.respondPermission(p.requestId, allow: true, always: true);
      await settle();
      expect(term.sent, [
        ['1'],
      ]);
    });

    test('denegar con mensaje: Down hasta «No», Tab, texto y Enter', () async {
      router.onEvent(permission());
      final p = await waitPending();
      pendings.respondPermission(
        p.requestId,
        allow: false,
        message: 'usa otro nombre',
      );
      await settle();
      expect(term.sent, [
        ['Down', 'Down', 'Down', 'Tab'],
        'usa otro nombre',
        ['Enter'],
      ]);
      final item = store.itemsOf('s1').whereType<PermissionItem>().single;
      expect(item.resolution, Resolution.denied);
    });

    test('denegar sin mensaje pulsa el número de «No»', () async {
      router.onEvent(permission());
      final p = await waitPending();
      pendings.respondPermission(p.requestId, allow: false);
      await settle();
      expect(term.sent, [
        ['4'],
      ]);
    });

    test('«Contestar en el PC» cierra sin pulsar nada', () async {
      router.onEvent(permission());
      final p = await waitPending();
      pendings.release(p.requestId);
      await settle();
      expect(term.sent, isEmpty);
      final item = store.itemsOf('s1').whereType<PermissionItem>().single;
      expect(item.resolution, Resolution.released);
    });

    test('si el diálogo desaparece (contestado en el PC) se cancela', () async {
      router.onEvent(permission());
      final p = await waitPending();
      term.screen = 'otra cosa';
      await settle();
      expect(pendings.byId(p.requestId), isNull);
      expect(term.sent, isEmpty);
      final item = store.itemsOf('s1').whereType<PermissionItem>().single;
      expect(item.resolution, Resolution.cancelled);
      expect(store.info('s1')!.status, SessionStatus.working);
    });

    test('UserPromptSubmit cancela el pendiente de terminal', () async {
      router.onEvent(permission());
      final p = await waitPending();
      router.onEvent(
        HookEvent(
          name: 'UserPromptSubmit',
          sessionId: 's1',
          paneId: 'w1:p1',
          raw: const {'prompt': 'sigue'},
        ),
      );
      await settle();
      expect(pendings.byId(p.requestId), isNull);
      expect(term.sent, isEmpty);
    });

    test('sin diálogo en pantalla no se abre nada', () async {
      term.screen = '❯ nada que ver';
      router.onEvent(permission());
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(pendings.count, 0);
      expect(store.itemsOf('s1').whereType<PermissionItem>(), isEmpty);
    });

    test('sin terminal (sin herdr) no se hace nada', () async {
      final r2 = HookRouter(
        store: store,
        hub: hub,
        pendings: pendings,
        projectsDir: '/tmp/no-existe',
        hasClients: () => false,
      );
      r2.onEvent(permission());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pendings.count, 0);
      r2.dispose();
    });

    test('pregunta: abre el pendiente y la contesta con el número', () async {
      term.screen = fixture('pregunta_simple');
      router.onEvent(ask());
      final p = await waitPending();
      expect(p.kind, PendingKind.question);
      expect(p.questions.single.options.length, 3);
      final item = store.itemsOf('s1').whereType<QuestionItem>().single;
      expect(item.requestId, p.requestId);
      pendings.respondAnswer(p.requestId, {
        '¿Cuál es tu color favorito?': 'Verde',
      });
      await settle();
      expect(term.sent, [
        ['2'],
      ]);
      final done = store.itemsOf('s1').whereType<QuestionItem>().single;
      expect(done.resolution, Resolution.answered);
      expect(done.answers, {'¿Cuál es tu color favorito?': 'Verde'});
    });

    test(
      'plan: abre el pendiente con el texto y aprueba con la opción 2',
      () async {
        term.screen = fixture('plan');
        router.onEvent(
          permission(tool: 'ExitPlanMode', input: {'plan': '# Plan\n1. A'}),
        );
        final p = await waitPending();
        expect(p.kind, PendingKind.plan);
        expect(p.plan, '# Plan\n1. A');
        final item = store.itemsOf('s1').whereType<PlanItem>().single;
        expect(item.requestId, p.requestId);
        pendings.respondPermission(p.requestId, allow: true);
        await settle();
        expect(term.sent, [
          ['2'],
        ]);
        expect(
          store.itemsOf('s1').whereType<PlanItem>().single.resolution,
          Resolution.allowed,
        );
      },
    );

    test('plan sin PermissionRequest: se abre desde su PreToolUse', () async {
      term.screen = fixture('plan');
      router.onEvent(
        HookEvent(
          name: 'PreToolUse',
          sessionId: 's1',
          paneId: 'w1:p1',
          toolName: 'ExitPlanMode',
          toolUseId: 'tu-plan',
          toolInput: const {'plan': '# Plan\n1. A'},
        ),
      );
      final p = await waitPending();
      expect(p.kind, PendingKind.plan);
      expect(p.plan, '# Plan\n1. A');
      pendings.respondPermission(p.requestId, allow: true);
      await settle();
      expect(term.sent, [
        ['2'],
      ]);
    });

    test(
      'plan con PreToolUse y PermissionRequest: un solo pendiente',
      () async {
        term.screen = fixture('plan');
        router.onEvent(
          HookEvent(
            name: 'PreToolUse',
            sessionId: 's1',
            paneId: 'w1:p1',
            toolName: 'ExitPlanMode',
            toolUseId: 'tu-plan',
            toolInput: const {'plan': '# Plan'},
          ),
        );
        router.onEvent(
          permission(tool: 'ExitPlanMode', input: {'plan': '# Plan'}),
        );
        await waitPending();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(pendings.forSession('s1'), hasLength(1));
        expect(store.itemsOf('s1').whereType<PlanItem>(), hasLength(1));
      },
    );

    test('plan rechazado con feedback: opción 3, texto y Enter', () async {
      term.screen = fixture('plan');
      router.onEvent(
        permission(tool: 'ExitPlanMode', input: {'plan': '# Plan'}),
      );
      final p = await waitPending();
      pendings.respondPermission(
        p.requestId,
        allow: false,
        message: 'Cambia el paso 1',
      );
      await settle();
      expect(term.sent, [
        ['3'],
        'Cambia el paso 1',
        ['Enter'],
      ]);
    });

    test(
      'un diálogo de otro tipo no vale: permiso con pantalla de plan',
      () async {
        term.screen = fixture('plan');
        router.onEvent(permission());
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(pendings.count, 0);
      },
    );
  });

  group('retenido que se libera', () {
    Future<Pending> hold() async {
      final h = await router.hold(permission());
      expect(h, isNotNull);
      return pendings.forSession('s1').single;
    }

    test(
      'al irse la última app se reabre respaldado por el terminal',
      () async {
        final held = await hold();
        final events = <PendingEvent>[];
        final sub = pendings.events.listen(events.add);
        pendings.releaseAll();
        await settle();
        await sub.cancel();

        // Mismo requestId y misma tarjeta, abierto de nuevo y sin resolver.
        final again = pendings.byId(held.requestId);
        expect(again, isNotNull);
        final item = store.itemsOf('s1').whereType<PermissionItem>().single;
        expect(item.requestId, held.requestId);
        expect(item.resolution, isNull);
        expect(events.whereType<PendingOpened>(), hasLength(1));

        pendings.respondPermission(held.requestId, allow: true);
        await settle();
        expect(term.sent, [
          ['1'],
        ]);
        expect(
          store.itemsOf('s1').whereType<PermissionItem>().single.resolution,
          Resolution.allowed,
        );
      },
    );

    test('ya en el terminal, otra app que entra y sale no lo cierra', () async {
      final held = await hold();
      pendings.releaseAll();
      await settle();
      expect(pendings.byId(held.requestId), isNotNull);

      // Una conexión breve (botón de la notificación) se va sin más.
      pendings.releaseAll();
      await settle();
      expect(pendings.byId(held.requestId), isNotNull);
      expect(
        store.itemsOf('s1').whereType<PermissionItem>().single.resolution,
        isNull,
      );
    });

    test('si el diálogo no sale, la tarjeta queda liberada', () async {
      final held = await hold();
      term.screen = 'nada';
      pendings.releaseAll();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(pendings.byId(held.requestId), isNull);
      expect(
        store.itemsOf('s1').whereType<PermissionItem>().single.resolution,
        Resolution.released,
      );
    });

    test('«Contestar en el PC» explícito no se reabre', () async {
      final held = await hold();
      pendings.release(held.requestId);
      await settle();
      expect(pendings.count, 0);
      expect(
        store.itemsOf('s1').whereType<PermissionItem>().single.resolution,
        Resolution.released,
      );
    });

    test('al expirar la espera también pasa al terminal', () async {
      pendings.timeout = const Duration(milliseconds: 20);
      final held = await hold();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(pendings.byId(held.requestId), isNotNull);
    });
  });
}
