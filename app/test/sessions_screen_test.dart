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
}
