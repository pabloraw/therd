import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/app_state.dart';
import 'package:therd/src/data/therd_client.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/push/push_service.dart';
import 'package:therd_protocol/protocol.dart';

import 'support/fakes.dart';

const cfg = ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'tk');

Future<(ProviderContainer, FakeClient)> setup({bool paired = true}) async {
  final client = FakeClient();
  final container = ProviderContainer(
    overrides: [
      clientProvider.overrideWithValue(client),
      settingsStoreProvider.overrideWithValue(
        MemorySettingsStore(paired ? cfg : null),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(therdProvider);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return (container, client);
}

void main() {
  test('el endpoint de avisos llega al daemon en cada hello', () async {
    final (c, client) = await setup();
    final ctl = c.read(therdProvider.notifier);
    ctl.registerPush('http://h/up2', previous: 'http://h/up1');
    final first = client.sentOf<PushRegisterMessage>().single;
    expect(first.endpoint, 'http://h/up2');
    expect(first.previous, 'http://h/up1');

    client.emit(const HelloMessage());
    await Future<void>.delayed(Duration.zero);
    final again = client.sentOf<PushRegisterMessage>();
    expect(again, hasLength(2));
    expect(again.last.previous, isNull);

    ctl.unregisterPush('http://h/up2');
    expect(
      client.sentOf<PushUnregisterMessage>().single.endpoint,
      'http://h/up2',
    );
    client.emit(const HelloMessage());
    await Future<void>.delayed(Duration.zero);
    expect(client.sentOf<PushRegisterMessage>(), hasLength(2));
  });

  test('id de notificación estable y positivo', () {
    expect(
      notificationId('a1b2c3d4e5f60718'),
      notificationId('a1b2c3d4e5f60718'),
    );
    expect(notificationId('a1b2c3d4e5f60718'), isNot(notificationId('r2')));
    expect(notificationId('ffffffffffffffff'), greaterThanOrEqualTo(0));
  });

  test('conecta al arrancar si hay configuración guardada', () async {
    final (c, client) = await setup();
    expect(client.connects, 1);
    expect(c.read(therdProvider).link.isConnected, isTrue);
    expect(c.read(therdProvider).config, cfg);
  });

  test('sin configuración no conecta', () async {
    final (c, client) = await setup(paired: false);
    expect(client.connects, 0);
    expect(c.read(therdProvider).configLoaded, isTrue);
  });

  test('abrir una sesión envía subscribe y reconectar lo reenvía', () async {
    final (c, client) = await setup();
    final ctl = c.read(therdProvider.notifier);
    ctl.openSession('s1');
    expect(client.sentOf<SubscribeMessage>().single.sessionId, 's1');

    client.setLink(const LinkStatus(LinkState.reconnecting, attempt: 1));
    await Future<void>.delayed(Duration.zero);
    client.setLink(const LinkStatus(LinkState.connected));
    await Future<void>.delayed(Duration.zero);
    expect(client.sentOf<SubscribeMessage>(), hasLength(2));
    expect(client.sentOf<SubscribeMessage>().last.before, isNull);
  });

  test(
    'loadOlder pide before con el cursor y no repite mientras carga',
    () async {
      final (c, client) = await setup();
      final ctl = c.read(therdProvider.notifier);
      ctl.openSession('s1');
      client.emit(
        BacklogMessage(
          sessionId: 's1',
          items: [userItem(10, 'a')],
          cursor: 10,
          hasMore: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      ctl.loadOlder('s1');
      ctl.loadOlder('s1');
      final subs = client.sentOf<SubscribeMessage>();
      expect(subs, hasLength(2));
      expect(subs.last.before, 10);
    },
  );

  test('con el chat abierto se avisa al daemon de lo visto', () async {
    final (c, client) = await setup();
    final ctl = c.read(therdProvider.notifier);
    client.emit(
      const HelloMessage(
        sessions: [SessionInfo(sessionId: 's1', lastSeq: 4, seenSeq: 2)],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.sentOf<MarkSeenMessage>(), isEmpty);

    ctl.openSession('s1');
    final first = client.sentOf<MarkSeenMessage>().single;
    expect((first.sessionId, first.seq), ('s1', 4));

    // Llega algo nuevo con el chat abierto: se avisa una vez.
    client.emit(ItemAppendMessage(item: userItem(5, 'x')));
    client.emit(const SeenMessage(sessionId: 's2', seq: 1));
    await Future<void>.delayed(Duration.zero);
    expect(client.sentOf<MarkSeenMessage>().map((m) => m.seq), [4, 5]);

    // Si el daemon ya lo da por visto (el PC lo vio), no se avisa.
    client.emit(const SeenMessage(sessionId: 's1', seq: 6));
    client.emit(
      const StatusMessage(
        sessionId: 's1',
        status: SessionStatus.idle,
        lastSeq: 6,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.sentOf<MarkSeenMessage>().map((m) => m.seq), [4, 5]);
  });

  test('las acciones generan los mensajes del protocolo', () async {
    final (c, client) = await setup();
    final ctl = c.read(therdProvider.notifier);
    ctl.sendPrompt('s1', 'hola');
    ctl.interrupt('s1');
    ctl.respondPermission('r1', allow: false, message: '  no  ');
    ctl.answer('r2', {'P': 'R'});
    ctl.release('r3');
    expect(client.sentOf<PromptMessage>().single.text, 'hola');
    expect(client.sentOf<InterruptMessage>(), hasLength(1));
    expect(client.sentOf<PermissionMessage>().single.message, 'no');
    expect(client.sentOf<AnswerMessage>().single.answers, {'P': 'R'});
    expect(client.sentOf<ReleaseMessage>().single.requestId, 'r3');
  });

  test(
    'prompt con imágenes: van al daemon y se pintan desde el móvil',
    () async {
      final (c, client) = await setup();
      final ctl = c.read(therdProvider.notifier);
      const img = PromptImage(mime: 'image/jpeg', data: '/9j/');
      ctl.sendPrompt('s1', 'mira', images: const [img, img]);
      ctl.sendPrompt('s1', '', images: const [img]);
      final sent = client.sentOf<PromptMessage>();
      expect(sent.first.images, hasLength(2));
      expect(sent.last.text, '');
      final out = c.read(therdProvider).chat('s1').outgoing;
      expect(out.map((o) => o.text), ['mira', '']);
      expect(out.first.images, hasLength(2));
      expect(localImages[out.last.images.single], [0xff, 0xd8, 0xff]);
    },
  );

  test('pause cierra el socket y resume reconecta', () async {
    final (c, client) = await setup();
    final ctl = c.read(therdProvider.notifier);
    ctl.pause();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(therdProvider).link.state, LinkState.disconnected);
    ctl.resume();
    await Future<void>.delayed(Duration.zero);
    expect(client.connects, 2);
    expect(c.read(therdProvider).link.isConnected, isTrue);
  });
}
