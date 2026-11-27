import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:therd/src/core/computer.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/deep_link.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/push/quick_reply.dart';
import 'package:therd_protocol/protocol.dart';

import 'support/fakes.dart';

const casa = ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'a');
const curro = ConnectionConfig(host: '100.2.2.2', port: 24601, token: 'b');

Future<(ProviderContainer, FakeClient, MemorySettingsStore)> setup() async {
  final client = FakeClient();
  final store = MemorySettingsStore(casa);
  final container = ProviderContainer(
    overrides: [
      clientProvider.overrideWithValue(client),
      settingsStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  container.read(therdProvider);
  await Future<void>.delayed(Duration.zero);
  return (container, client, store);
}

void main() {
  test('el hello pone id y hostname al ordenador en uso', () async {
    final (c, client, store) = await setup();
    client.emit(const HelloMessage(daemonId: 'd1', machine: 'sobremesa'));
    await Future<void>.delayed(Duration.zero);
    final pc = c.read(therdProvider).computer!;
    expect(pc.daemonId, 'd1');
    expect(pc.displayName, 'sobremesa');
    expect(store.computers.active!.daemonId, 'd1');
  });

  test('añadir otro, cambiar entre ellos y olvidar', () async {
    final (c, client, store) = await setup();
    final ctl = c.read(therdProvider.notifier);
    client.emit(HelloMessage(sessions: const [SessionInfo(sessionId: 's1')]));
    await Future<void>.delayed(Duration.zero);
    ctl.openSession('s1');
    expect(c.read(therdProvider).sessions, hasLength(1));

    await ctl.addComputer(curro, name: 'Trabajo');
    var s = c.read(therdProvider);
    expect(s.computers.list, hasLength(2));
    expect(s.computer!.name, 'Trabajo');
    expect(s.config, curro);
    // Las sesiones del otro ordenador no se mezclan.
    expect(s.sessions, isEmpty);
    expect(s.chats, isEmpty);

    // Al volver no se reenvía el subscribe del ordenador anterior.
    client.sent.clear();
    await ctl.switchTo('pc1');
    expect(c.read(therdProvider).config, casa);
    client.emit(const HelloMessage());
    await Future<void>.delayed(Duration.zero);
    expect(client.sentOf<SubscribeMessage>(), isEmpty);

    // Mismo host y puerto: se actualiza, no se duplica.
    await ctl.addComputer(curro.withLanHosts(['192.168.1.9']));
    expect(c.read(therdProvider).computers.list, hasLength(2));
    expect(c.read(therdProvider).computer!.name, isNull);

    await ctl.forget();
    s = c.read(therdProvider);
    expect(s.computers.list.single.id, 'pc1');
    expect(s.config, casa);
    expect(store.computers.list, hasLength(1));

    await ctl.forget();
    expect(c.read(therdProvider).config, isNull);
  });

  test('el emparejamiento antiguo pasa a ser el primer ordenador', () async {
    SharedPreferences.setMockInitialValues({
      'host': '100.1.1.1',
      'port': 24601,
      'token': 'a',
      'lanHosts': ['192.168.1.5'],
    });
    final store = PrefsSettingsStore();
    final saved = await store.loadComputers();
    expect(saved.active!.config, casa.withLanHosts(['192.168.1.5']));

    final pc2 = Computer(id: 'pc2', config: curro, name: 'Trabajo');
    await store.saveComputers(SavedComputers([...saved.list, pc2], 'pc2'));
    final again = await store.loadComputers();
    expect(again.list, hasLength(2));
    expect(again.active, pc2);
    final p = await SharedPreferences.getInstance();
    expect(p.getString('host'), isNull);
  });

  test('el aviso lleva su ordenador hasta el enlace y la respuesta', () {
    const p = NotificationPayload(
      sessionId: 's1',
      requestId: 'r',
      daemonId: 'd2',
    );
    final back = NotificationPayload.decode(p.encode())!;
    expect(back.daemonId, 'd2');
    expect(parseSessionLink(back.link), 's1');
    expect(parseLinkDaemon(back.link), 'd2');
    expect(parseLinkDaemon(Uri.parse('therd://session/s1')), isNull);

    const saved = SavedComputers([
      Computer(id: 'pc1', config: casa, daemonId: 'd1'),
      Computer(id: 'pc2', config: curro, daemonId: 'd2'),
    ], 'pc1');
    expect(saved.forDaemon('d2')!.config, curro);
    // Daemon antiguo o desconocido: el que está en uso.
    expect(saved.forDaemon(null)!.config, casa);
    expect(saved.forDaemon('zz')!.config, casa);
  });
}
