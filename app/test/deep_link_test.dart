import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/deep_link.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/ui/app.dart';
import 'package:therd/src/ui/chat_screen.dart';
import 'package:therd/src/ui/sessions_screen.dart';
import 'package:therd_protocol/protocol.dart';

import 'support/fakes.dart';

const cfg = ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'tk');

class FakeLinks implements DeepLinkSource {
  final _ctl = StreamController<Uri>.broadcast();
  @override
  Stream<Uri> get links => _ctl.stream;
  void emit(String url) => _ctl.add(Uri.parse(url));
}

SessionInfo session(String id) =>
    SessionInfo(sessionId: id, workspaceId: 'w1', title: 'Sesión $id');

/// El chat tiene animaciones infinitas (cargando): pumpAndSettle no termina.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<(FakeClient, FakeLinks)> pumpApp(
  WidgetTester tester, {
  ConnectionConfig? config = cfg,
}) async {
  final client = FakeClient();
  final links = FakeLinks();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientProvider.overrideWithValue(client),
        settingsStoreProvider.overrideWithValue(MemorySettingsStore(config)),
        deepLinkSourceProvider.overrideWithValue(links),
      ],
      child: const TherdApp(),
    ),
  );
  return (client, links);
}

void main() {
  group('parseSessionLink', () {
    test('enlace válido', () {
      expect(parseSessionLink(Uri.parse('therd://session/abc-1')), 'abc-1');
      expect(parseSessionLink(Uri.parse('therd://session/abc-1/')), 'abc-1');
    });
    test('sin id', () {
      expect(parseSessionLink(Uri.parse('therd://session')), isNull);
      expect(parseSessionLink(Uri.parse('therd://session/')), isNull);
    });
    test('esquema o host ajenos', () {
      expect(parseSessionLink(Uri.parse('https://session/abc')), isNull);
      expect(parseSessionLink(Uri.parse('therd://otro/abc')), isNull);
    });
    test('demasiados segmentos', () {
      expect(parseSessionLink(Uri.parse('therd://session/a/b')), isNull);
    });
  });

  testWidgets('un enlace lleva al chat y atrás vuelve a la lista', (
    tester,
  ) async {
    final (client, links) = await pumpApp(tester);
    await tester.pump();
    await tester.pump();
    client.emit(HelloMessage(workspaces: const [], sessions: [session('s2')]));
    await tester.pump();
    expect(find.byType(SessionsScreen), findsOneWidget);

    links.emit('therd://session/s2');
    await settle(tester);
    expect(tester.widget<ChatScreen>(find.byType(ChatScreen)).sessionId, 's2');

    // El mismo enlace con el chat abierto no apila otro.
    links.emit('therd://session/s2');
    await settle(tester);
    expect(find.byType(ChatScreen), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester);
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(SessionsScreen), findsOneWidget);
  });

  testWidgets('arranque en frío: espera al hello y abre el chat', (
    tester,
  ) async {
    final (client, links) = await pumpApp(tester);
    links.emit('therd://session/s1'); // antes de cargar la config
    await tester.pump();
    await tester.pump();
    expect(find.byType(ChatScreen), findsNothing);
    client.emit(HelloMessage(workspaces: const [], sessions: [session('s1')]));
    await settle(tester);
    expect(tester.widget<ChatScreen>(find.byType(ChatScreen)).sessionId, 's1');
  });

  testWidgets('sesión inexistente: se queda la lista', (tester) async {
    final (client, links) = await pumpApp(tester);
    await tester.pump();
    await tester.pump();
    links.emit('therd://session/nope');
    await tester.pump();
    client.emit(HelloMessage(workspaces: const [], sessions: [session('s1')]));
    await settle(tester);
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(SessionsScreen), findsOneWidget);
  });

  testWidgets('sin config emparejada se ignora el enlace', (tester) async {
    final (client, links) = await pumpApp(tester, config: null);
    await tester.pump();
    await tester.pump();
    links.emit('therd://session/s1');
    client.emit(HelloMessage(workspaces: const [], sessions: [session('s1')]));
    await settle(tester);
    expect(find.byType(ChatScreen), findsNothing);
  });

  testWidgets('enlace ajeno no hace nada', (tester) async {
    final (client, links) = await pumpApp(tester);
    await tester.pump();
    await tester.pump();
    client.emit(HelloMessage(workspaces: const [], sessions: [session('s1')]));
    links.emit('https://example.com/session/s1');
    await settle(tester);
    expect(find.byType(ChatScreen), findsNothing);
  });
}
