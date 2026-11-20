import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/therd_client.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/ui/sessions_screen.dart';
import 'package:therd/src/ui/theme.dart';
import 'package:therd_protocol/protocol.dart';

import 'support/fakes.dart';

const cfg = ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'tk');

Future<FakeClient> pumpList(
  WidgetTester tester, {
  List<WorkspaceInfo> workspaces = const [],
  List<SessionInfo> sessions = const [],
  int daemonVersion = protocolVersion,
}) async {
  final client = FakeClient();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientProvider.overrideWithValue(client),
        settingsStoreProvider.overrideWithValue(MemorySettingsStore(cfg)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: const SessionsScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  client.emit(
    HelloMessage(
      version: daemonVersion,
      workspaces: workspaces,
      sessions: sessions,
    ),
  );
  await tester.pump();
  await tester.pump();
  return client;
}

void main() {
  const oldDaemon =
      'El daemon del PC es de una versión anterior: '
      'actualízalo para usar todo.';
  const oldApp = 'La app es de una versión anterior al daemon: actualízala.';

  testWidgets('aviso si el daemon es de una versión anterior', (tester) async {
    await pumpList(tester, daemonVersion: protocolVersion - 1);
    expect(find.text(oldDaemon), findsOneWidget);
    expect(find.text(oldApp), findsNothing);
  });

  testWidgets('aviso si la app es más vieja que el daemon', (tester) async {
    await pumpList(tester, daemonVersion: protocolVersion + 1);
    expect(find.text(oldApp), findsOneWidget);
    expect(find.text(oldDaemon), findsNothing);
  });

  testWidgets('sin aviso si las versiones casan', (tester) async {
    await pumpList(tester);
    expect(find.text(oldApp), findsNothing);
    expect(find.text(oldDaemon), findsNothing);
  });

  testWidgets('lista con ramas, sin etiquetas de estado y filtros', (
    tester,
  ) async {
    await pumpList(
      tester,
      workspaces: const [
        WorkspaceInfo(
          workspaceId: 'w1',
          number: 1,
          label: 'app',
          branch: 'main',
        ),
      ],
      sessions: const [
        SessionInfo(
          sessionId: 'a',
          workspaceId: 'w1',
          title: 'Primera',
          status: SessionStatus.blocked,
        ),
        SessionInfo(
          sessionId: 'b',
          workspaceId: 'w1',
          title: 'Segunda',
          branch: 'feat/x',
          status: SessionStatus.working,
        ),
      ],
    );
    expect(find.text('Sesiones'), findsOneWidget);
    expect(find.text('app'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('feat/x'), findsOneWidget);
    expect(find.text('Esperando'), findsNothing);
    expect(find.text('Te esperan 1'), findsOneWidget);
    expect(find.text('Sin leer 0'), findsOneWidget);

    await tester.tap(find.text('Te esperan 1'));
    await tester.pump();
    expect(find.text('Primera'), findsOneWidget);
    expect(find.text('Segunda'), findsNothing);
    expect(find.text('app'), findsOneWidget);

    await tester.tap(find.text('Sin leer 0'));
    await tester.pump();
    expect(find.text('app'), findsNothing);
    expect(find.text('No hay sesiones sin leer.'), findsOneWidget);
  });

  testWidgets('vacía y conectada', (tester) async {
    await pumpList(tester);
    expect(
      find.text('No hay sesiones de Claude Code en herdr.'),
      findsOneWidget,
    );
    expect(find.text('Todas'), findsNothing);
  });

  testWidgets('token rechazado muestra la franja tocable', (tester) async {
    final client = await pumpList(tester);
    client.setLink(const LinkStatus(LinkState.unauthorized));
    await tester.pump();
    await tester.pump();
    expect(find.text('Token rechazado'), findsOneWidget);
    expect(
      find.text('Token rechazado. Toca para volver a emparejar.'),
      findsOneWidget,
    );
  });

  group('abrir y cerrar desde la lista', () {
    const repo = WorkspaceInfo(
      workspaceId: 'w1',
      number: 1,
      label: 'app',
      repoName: 'app',
      branch: 'main',
    );
    const tree = WorkspaceInfo(
      workspaceId: 'w2',
      number: 2,
      label: 'wt',
      branch: 'feat/a',
      isLinkedWorktree: true,
      parentWorkspaceId: 'w1',
    );
    const s1 = SessionInfo(
      sessionId: 's1',
      workspaceId: 'w1',
      paneId: 'w1:p1',
      title: 'Principal',
    );
    const s2 = SessionInfo(
      sessionId: 's2',
      workspaceId: 'w2',
      paneId: 'w2:p1',
      title: 'En worktree',
    );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets(
      'long tap en el repo: nueva sesión en un worktree y se abre su chat',
      (tester) async {
        final client = await pumpList(
          tester,
          workspaces: const [repo, tree],
          sessions: const [s1, s2],
        );
        await tester.longPress(find.text('app'));
        await settle(tester);
        expect(find.text('Nueva sesión'), findsOneWidget);
        expect(find.text('Nuevo worktree'), findsOneWidget);

        await tester.tap(find.text('Nueva sesión'));
        await settle(tester);
        // Con worktrees se elige dónde.
        expect(find.text('Nueva sesión en'), findsOneWidget);
        await tester.tap(find.text('feat/a').last);
        await settle(tester);

        await tester.enterText(find.byType(TextField), 'Revisa el diff');
        await tester.tap(find.text('Abrir sesión'));
        await settle(tester);

        final open = client.sentOf<OpenSessionMessage>().single;
        expect(open.workspaceId, 'w2');
        expect(open.branch, isNull);
        expect(open.prompt, 'Revisa el diff');
        expect(find.text('Abriendo sesión en el PC…'), findsOneWidget);

        client.emit(
          SessionOpenedMessage(
            opId: open.opId,
            paneId: 'w2:p7',
            workspaceId: 'w2',
          ),
        );
        await settle(tester);
        client.emit(
          const SessionsMessage(
            workspaces: [repo, tree],
            sessions: [
              s1,
              s2,
              SessionInfo(
                sessionId: 's3',
                workspaceId: 'w2',
                paneId: 'w2:p7',
                title: 'Nueva',
              ),
            ],
          ),
        );
        await settle(tester);
        expect(find.text('Abriendo sesión en el PC…'), findsNothing);
        expect(
          client.sentOf<SubscribeMessage>().map((m) => m.sessionId),
          contains('s3'),
        );
      },
    );

    testWidgets('nuevo worktree pide rama y la base sale de la actual', (
      tester,
    ) async {
      final client = await pumpList(
        tester,
        workspaces: const [repo],
        sessions: const [s1],
      );
      await tester.longPress(find.text('app'));
      await settle(tester);
      await tester.tap(find.text('Nuevo worktree'));
      await settle(tester);

      await tester.tap(find.text('Crear y abrir'));
      await settle(tester);
      expect(find.text('Pon el nombre de la rama.'), findsOneWidget);
      expect(client.sentOf<OpenSessionMessage>(), isEmpty);

      await tester.enterText(find.byType(TextField).first, 'feat/nueva');
      await tester.tap(find.text('Crear y abrir'));
      await settle(tester);
      final open = client.sentOf<OpenSessionMessage>().single;
      expect(open.workspaceId, 'w1');
      expect(open.branch, 'feat/nueva');
      expect(open.base, 'main');
      expect(open.prompt, isNull);
    });

    testWidgets('un error al abrir quita la franja y sale el aviso', (
      tester,
    ) async {
      final client = await pumpList(
        tester,
        workspaces: const [repo],
        sessions: const [s1],
      );
      await tester.longPress(find.text('app'));
      await settle(tester);
      await tester.tap(find.text('Nueva sesión'));
      await settle(tester);
      await tester.tap(find.text('Abrir sesión'));
      await settle(tester);
      final open = client.sentOf<OpenSessionMessage>().single;
      client.emit(
        ErrorMessage(
          code: ErrorCode.actionFailed,
          message: 'No se pudo abrir la sesión: no arrancó',
          requestId: open.opId,
        ),
      );
      await settle(tester);
      expect(find.text('Abriendo sesión en el PC…'), findsNothing);
      expect(
        find.text('No se pudo abrir la sesión: no arrancó'),
        findsOneWidget,
      );
    });

    testWidgets('long tap en una sesión de worktree: cerrar y quitar', (
      tester,
    ) async {
      final client = await pumpList(
        tester,
        workspaces: const [repo, tree],
        sessions: const [s1, s2],
      );
      await tester.longPress(find.text('En worktree'));
      await settle(tester);
      expect(find.text('Nueva sesión aquí'), findsOneWidget);
      expect(find.text('Quitar worktree'), findsOneWidget);

      await tester.tap(find.text('Cerrar sesión'));
      await settle(tester);
      await tester.tap(find.text('Cerrar'));
      await settle(tester);
      expect(client.sentOf<CloseSessionMessage>().single.sessionId, 's2');

      await tester.longPress(find.text('En worktree'));
      await settle(tester);
      await tester.tap(find.text('Quitar worktree'));
      await settle(tester);
      await tester.tap(find.text('Cancelar'));
      await settle(tester);
      expect(client.sentOf<RemoveWorktreeMessage>(), isEmpty);

      await tester.longPress(find.text('En worktree'));
      await settle(tester);
      await tester.tap(find.text('Quitar worktree'));
      await settle(tester);
      await tester.tap(find.text('Quitar'));
      await settle(tester);
      expect(client.sentOf<RemoveWorktreeMessage>().single.workspaceId, 'w2');
    });

    testWidgets('en el checkout principal no se ofrece quitar worktree', (
      tester,
    ) async {
      await pumpList(tester, workspaces: const [repo], sessions: const [s1]);
      await tester.longPress(find.text('Principal'));
      await settle(tester);
      expect(find.text('Cerrar sesión'), findsOneWidget);
      expect(find.text('Quitar worktree'), findsNothing);
    });
  });
}
