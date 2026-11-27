import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/therd_client.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/push/quick_reply.dart';
import 'package:therd_protocol/protocol.dart';

import 'support/fakes.dart';

/// Daemon falso en 127.0.0.1 que saluda y resuelve cualquier permiso.
Future<HttpServer> fakeDaemon() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final ws = await WebSocketTransformer.upgrade(req);
    ws.add(const HelloMessage().encode());
    ws.listen((data) {
      final m = decodeMessage(data as String);
      if (m is PermissionMessage) {
        ws.add(
          PendingResolvedMessage(
            sessionId: 's1',
            requestId: m.requestId,
            resolution: Resolution.allowed,
          ).encode(),
        );
      }
    });
  });
  return server;
}

/// Espera al primer estado que cumpla [test].
Future<LinkStatus> waitLink(
  TherdClient c,
  bool Function(LinkStatus) test,
) async {
  if (test(c.current)) return c.current;
  return c.link.firstWhere(test).timeout(const Duration(seconds: 8));
}

// 127.0.0.2 también es loopback en Linux, pero ahí no escucha nadie:
// rechaza al momento, como una IP de casa vista desde fuera.
const nobody = '127.0.0.2';

void main() {
  group('ConnectionConfig', () {
    test('el QR trae las IPs de la red local', () {
      final c = ConnectionConfig.tryParse(
        'therd://100.1.1.1:24601?token=x&lan=192.168.1.5,10.0.0.2',
      )!;
      expect(c.lanHosts, ['192.168.1.5', '10.0.0.2']);
      expect(c.hosts, ['192.168.1.5', '10.0.0.2', '100.1.1.1']);
      expect(c.isLan('192.168.1.5'), isTrue);
      expect(c.isLan('100.1.1.1'), isFalse);
    });

    test('sin lan solo queda la dirección principal', () {
      final c = ConnectionConfig.tryParse('therd://100.1.1.1?token=x')!;
      expect(c.lanHosts, isEmpty);
      expect(c.hosts, ['100.1.1.1']);
    });

    test('el almacén guarda las IPs locales', () async {
      final store = MemorySettingsStore();
      const c = ConnectionConfig(
        host: '100.1.1.1',
        port: 1,
        token: 't',
        lanHosts: ['192.168.1.5'],
      );
      await store.save(c);
      expect(await store.load(), c);
    });
  });

  group('WebSocketTherdClient', () {
    late HttpServer server;
    late WebSocketTherdClient client;

    setUp(() async {
      server = await fakeDaemon();
      client = WebSocketTherdClient();
    });

    tearDown(() async {
      client.dispose();
      await server.close(force: true);
    });

    test('entra por la red local si responde', () async {
      client.connect(
        ConnectionConfig(
          host: nobody,
          port: server.port,
          token: 't',
          lanHosts: const ['127.0.0.1'],
        ),
      );
      final s = await waitLink(client, (s) => s.isConnected);
      expect(s.lan, isTrue);
      expect(s.label, 'Conectado (red local)');
    });

    test('si la red local no responde pasa a Tailscale sin esperar', () async {
      final watch = Stopwatch()..start();
      client.connect(
        ConnectionConfig(
          host: '127.0.0.1',
          port: server.port,
          token: 't',
          lanHosts: const [nobody],
        ),
      );
      final s = await waitLink(client, (s) => s.isConnected);
      expect(s.lan, isFalse);
      // Sin pasar por el backoff de reconexión (1 s como mínimo).
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('probe prueba también la red local', () async {
      final ok = await client.probe(
        ConnectionConfig(
          host: nobody,
          port: server.port,
          token: 't',
          lanHosts: const ['127.0.0.1'],
        ),
      );
      expect(ok, isNull);
    });

    test('la respuesta rápida cae a Tailscale si no hay red local', () async {
      final r = await sendQuickReply(
        ConnectionConfig(
          host: '127.0.0.1',
          port: server.port,
          token: 't',
          lanHosts: const [nobody],
        ),
        const PermissionMessage(requestId: 'r1', allow: true),
        'r1',
      );
      expect(r, isNull);
    });
  });

  test('el controlador guarda las IPs locales que anuncia el daemon', () async {
    final client = FakeClient();
    final store = MemorySettingsStore(
      const ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'tk'),
    );
    final container = ProviderContainer(
      overrides: [
        clientProvider.overrideWithValue(client),
        settingsStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    container.read(therdProvider);
    await Future<void>.delayed(Duration.zero);

    client.emit(const HelloMessage(lanHosts: ['192.168.1.5']));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(therdProvider).config!.lanHosts, ['192.168.1.5']);
    expect(client.updated!.lanHosts, ['192.168.1.5']);
    expect(store.value!.lanHosts, ['192.168.1.5']);

    // Un daemon antiguo no manda ninguna: no se borran las aprendidas.
    client.emit(const HelloMessage());
    await Future<void>.delayed(Duration.zero);
    expect(store.value!.lanHosts, ['192.168.1.5']);
  });
}
