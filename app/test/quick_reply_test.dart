import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/push/quick_reply.dart';
import 'package:therd_protocol/protocol.dart';

/// Daemon falso: saluda y contesta a cada mensaje con [onMessage].
Future<(HttpServer, List<Message>)> fakeDaemon(
  List<ServerMessage> Function(Message m) onMessage,
) async {
  final got = <Message>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final ws = await WebSocketTransformer.upgrade(req);
    ws.add(const HelloMessage(sessions: [], workspaces: []).encode());
    ws.listen((data) {
      final m = decodeMessage(data as String);
      got.add(m);
      for (final r in onMessage(m)) {
        ws.add(r.encode());
      }
    });
  });
  return (server, got);
}

ConnectionConfig configFor(HttpServer s) =>
    ConnectionConfig(host: '127.0.0.1', port: s.port, token: 't');

void main() {
  group('NotificationPayload', () {
    test('ida y vuelta', () {
      final p = NotificationPayload.decode(
        const NotificationPayload(sessionId: 's1', requestId: 'r1').encode(),
      )!;
      expect(p.sessionId, 's1');
      expect(p.requestId, 'r1');
    });

    test('el formato antiguo es solo el sessionId', () {
      final p = NotificationPayload.decode('s1')!;
      expect(p.sessionId, 's1');
      expect(p.requestId, isNull);
    });
  });

  test('botones por tipo', () {
    expect(QuickAction.forKind(PendingKind.permission).map((a) => a.$2), [
      'Permitir',
      'Denegar',
    ]);
    expect(QuickAction.forKind(PendingKind.plan).map((a) => a.$2), [
      'Aprobar',
      'Rechazar',
    ]);
    expect(QuickAction.forKind(PendingKind.question), isEmpty);
    expect(quickMessage('deny', 'r1')!.allow, isFalse);
    expect(quickMessage('otro', 'r1'), isNull);
  });

  group('sendQuickReply', () {
    test('manda la respuesta y espera a que se cierre', () async {
      final (server, got) = await fakeDaemon(
        (m) => [
          if (m is PermissionMessage)
            PendingResolvedMessage(
              requestId: m.requestId,
              sessionId: 's1',
              resolution: Resolution.allowed,
            ),
        ],
      );
      addTearDown(() => server.close(force: true));
      final err = await sendQuickReply(
        configFor(server),
        quickMessage(QuickAction.allow, 'r1')!,
        'r1',
      );
      expect(err, isNull);
      final sent = got.whereType<PermissionMessage>().single;
      expect(sent.requestId, 'r1');
      expect(sent.allow, isTrue);
    });

    test('si ya no estaba pendiente, lo dice', () async {
      final (server, _) = await fakeDaemon(
        (m) => [
          if (m is PermissionMessage)
            ErrorMessage(
              code: ErrorCode.unknownRequest,
              message: 'x',
              requestId: m.requestId,
            ),
        ],
      );
      addTearDown(() => server.close(force: true));
      final err = await sendQuickReply(
        configFor(server),
        quickMessage(QuickAction.deny, 'r1')!,
        'r1',
      );
      expect(err, 'Ya no estaba pendiente');
    });

    test('sin respuesta, vence el plazo', () async {
      final (server, _) = await fakeDaemon((_) => []);
      addTearDown(() => server.close(force: true));
      final err = await sendQuickReply(
        configFor(server),
        quickMessage(QuickAction.allow, 'r1')!,
        'r1',
        timeout: const Duration(milliseconds: 200),
      );
      expect(err, contains('Sin respuesta'));
    });
  });
}
