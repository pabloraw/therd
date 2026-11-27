import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/ui/connection_screen.dart';
import 'package:therd/src/ui/theme.dart';

import 'support/fakes.dart';

const cfg = ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'tk');

Future<FakeClient> pump(
  WidgetTester tester, {
  bool firstRun = false,
  ConnectionConfig? config,
  MemorySettingsStore? store,
}) async {
  final client = FakeClient();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientProvider.overrideWithValue(client),
        settingsStoreProvider.overrideWithValue(
          store ?? MemorySettingsStore(config),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        // Con configuración se edita su ordenador (pc1 en el almacén falso).
        home: ConnectionScreen(
          firstRun: firstRun,
          computerId: config == null ? null : 'pc1',
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return client;
}

void main() {
  testWidgets('primera vez: título de bienvenida y datos a mano plegados', (
    tester,
  ) async {
    await pump(tester, firstRun: true);
    expect(find.text('Hola, conecta tu PC'), findsOneWidget);
    expect(find.byTooltip('Volver'), findsNothing);
    expect(find.text('Host'), findsNothing);
    expect(find.text('Olvidar este ordenador'), findsNothing);
  });

  testWidgets('añadir otro ordenador lo guarda con su nombre y pasa a él', (
    tester,
  ) async {
    final store = MemorySettingsStore(cfg);
    final client = await pump(tester, store: store);
    expect(find.text('Añadir ordenador'), findsOneWidget);
    expect(find.text('Olvidar este ordenador'), findsNothing);
    await tester.tap(find.text('Escribir los datos a mano'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).at(0), '100.9.9.9');
    await tester.enterText(find.byType(TextFormField).at(2), 'otro');
    await tester.enterText(find.byType(TextFormField).at(3), 'Trabajo');
    await tester.tap(find.text('Guardar y conectar'));
    await tester.pump();
    final list = store.computers.list;
    expect(list, hasLength(2));
    expect(list.last.name, 'Trabajo');
    expect(store.computers.activeId, list.last.id);
    expect(store.value!.host, '100.9.9.9');
    expect(client.connects, greaterThanOrEqualTo(2));
  });

  testWidgets('guardar con campos vacíos abre el desplegable y marca errores', (
    tester,
  ) async {
    await pump(tester, firstRun: true);
    await tester.tap(find.text('Guardar y conectar'));
    await tester.pump();
    expect(find.text('Escribe la IP del PC'), findsOneWidget);
    expect(find.text('Falta el token'), findsOneWidget);
  });

  testWidgets('ajustes: probar muestra el resultado con host y puerto', (
    tester,
  ) async {
    final client = await pump(tester, config: cfg);
    expect(find.text('Conexión'), findsOneWidget);
    expect(find.byTooltip('Volver'), findsOneWidget);
    expect(find.text('Olvidar este ordenador'), findsOneWidget);
    // La configuración se carga después de montar: se escribe a mano.
    await tester.enterText(find.byType(TextFormField).at(0), '100.1.1.1');
    await tester.enterText(find.byType(TextFormField).at(2), 'tk');
    await tester.tap(find.text('Probar conexión'));
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('Conexión correcta con', findRichText: true),
      findsOneWidget,
    );

    client.probeResult = 'Token rechazado';
    await tester.tap(find.text('Probar conexión'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Token rechazado'), findsOneWidget);
  });
}
