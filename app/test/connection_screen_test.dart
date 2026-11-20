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
}) async {
  final client = FakeClient();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientProvider.overrideWithValue(client),
        settingsStoreProvider.overrideWithValue(MemorySettingsStore(config)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: ConnectionScreen(firstRun: firstRun),
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
    expect(find.text('Olvidar este emparejamiento'), findsNothing);
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
    expect(find.text('Olvidar este emparejamiento'), findsOneWidget);
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
