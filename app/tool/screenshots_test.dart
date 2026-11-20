// Capturas del README con los widgets reales y datos de ejemplo.
//
//   cd app && flutter test tool/screenshots_test.dart
//
// Escribe los PNG en docs/img/. No va en test/ para no correr con la suite.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/core/settings_store.dart';
import 'package:therd/src/data/therd_controller.dart';
import 'package:therd/src/ui/chat_screen.dart';
import 'package:therd/src/ui/sessions_screen.dart';
import 'package:therd/src/ui/theme.dart';
import 'package:therd_protocol/protocol.dart';

import '../test/support/fakes.dart';

const cfg = ConnectionConfig(host: '100.64.0.2', port: 24601, token: 'tk');
const _size = Size(412, 892);
const _dpr = 2.625;
final _out = Directory('../docs/img');

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> assets) async {
    final l = FontLoader(name);
    for (final a in assets) {
      l.addFont(rootBundle.load(a));
    }
    await l.load();
  }

  await family('Geist', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'assets/fonts/Geist-$w.ttf',
  ]);
  await family('GeistMono', [
    for (final w in ['Regular', 'Medium', 'SemiBold'])
      'assets/fonts/GeistMono-$w.ttf',
  ]);
  final material = '${Platform.environment['FLUTTER_ROOT']}'
      '/bin/cache/artifacts/material_fonts';
  Future<ByteData> file(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  await (FontLoader('MaterialIcons')
        ..addFont(file('$material/MaterialIcons-Regular.otf')))
      .load();
  await (FontLoader('Roboto')
        ..addFont(file('$material/Roboto-Regular.ttf'))
        ..addFont(file('$material/Roboto-Medium.ttf')))
      .load();
}

Future<void> _pump(WidgetTester tester, FakeClient client, Widget home) async {
  tester.view.physicalSize = _size * _dpr;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('shot'),
      child: ProviderScope(
        overrides: [
          clientProvider.overrideWithValue(client),
          settingsStoreProvider.overrideWithValue(MemorySettingsStore(cfg)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark),
          home: home,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _save(WidgetTester tester, String name) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _dpr);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    _out.createSync(recursive: true);
    File('${_out.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

const _workspaces = [
  WorkspaceInfo(workspaceId: 'w1', number: 1, label: 'api', branch: 'main'),
  WorkspaceInfo(
    workspaceId: 'w2',
    number: 2,
    label: 'web',
    branch: 'feat/checkout',
  ),
  WorkspaceInfo(workspaceId: 'w3', number: 3, label: 'docs', branch: 'main'),
];

const _sessions = [
  SessionInfo(
    sessionId: 's1',
    workspaceId: 'w1',
    title: 'Paginación en /orders',
    cwd: '/home/user/api',
    branch: 'main',
    status: SessionStatus.blocked,
    lastSeq: 12,
    seenSeq: 12,
  ),
  SessionInfo(
    sessionId: 's2',
    workspaceId: 'w1',
    title: 'Tests de integración lentos',
    cwd: '/home/user/api',
    branch: 'main',
    status: SessionStatus.working,
    lastSeq: 40,
    seenSeq: 40,
  ),
  SessionInfo(
    sessionId: 's3',
    workspaceId: 'w2',
    title: 'Formulario de pago',
    cwd: '/home/user/web',
    branch: 'feat/checkout',
    status: SessionStatus.done,
    lastSeq: 30,
    seenSeq: 22,
  ),
  SessionInfo(
    sessionId: 's4',
    workspaceId: 'w3',
    title: 'Guía de despliegue',
    cwd: '/home/user/docs',
    branch: 'main',
    status: SessionStatus.idle,
    lastSeq: 8,
    seenSeq: 8,
  ),
];

List<ChatItem> _chat() => [
  userItem(1, '¿Cómo pagina hoy GET /orders?'),
  ToolCallItem(
    id: 't-2',
    sessionId: 's1',
    seq: 2,
    timestamp: t(2),
    toolName: 'Grep',
    input: const {'pattern': 'findMany', 'path': 'src/routes'},
    status: ToolStatus.ok,
  ),
  asstItem(
    3,
    'No pagina: `findMany()` devuelve todos los pedidos de una vez. Con '
    '40.000 pedidos la respuesta pasa de 8 MB.',
  ),
  userItem(4, 'Añade paginación por cursor a GET /orders, con tests.'),
  ToolCallItem(
    id: 't2',
    sessionId: 's1',
    seq: 5,
    timestamp: t(5),
    toolName: 'Read',
    input: const {'file_path': '/home/user/api/src/routes/orders.ts'},
    status: ToolStatus.ok,
    result: '…',
  ),
  ToolCallItem(
    id: 't3',
    sessionId: 's1',
    seq: 6,
    timestamp: t(6),
    toolName: 'Edit',
    input: const {
      'file_path': '/home/user/api/src/routes/orders.ts',
      'old_string': 'const rows = await db.orders.findMany();',
      'new_string':
          'const rows = await db.orders.findMany({\n'
          '  take: limit + 1,\n'
          '  cursor: after ? { id: after } : undefined,\n'
          '});',
    },
    status: ToolStatus.ok,
  ),
  ToolCallItem(
    id: 't4',
    sessionId: 's1',
    seq: 7,
    timestamp: t(7),
    toolName: 'Bash',
    input: const {'command': 'npm test -- orders'},
    status: ToolStatus.ok,
    result: 'PASS  test/orders.test.ts\n  ✓ pagina con cursor (41 ms)\n'
        'Tests: 6 passed, 6 total',
    durationMs: 4200,
  ),
  asstItem(
    8,
    'Listo. `GET /orders` acepta ahora `limit` (por defecto 50) y `after`, '
    'y devuelve `nextCursor` cuando quedan más resultados.\n\n'
    'Los 6 tests de pedidos pasan. ¿Subo la rama?',
  ),
];

void main() {
  setUpAll(_loadFonts);

  testWidgets('captura: sesiones', (tester) async {
    final client = FakeClient();
    await _pump(tester, client, const SessionsScreen());
    client.emit(
      const HelloMessage(workspaces: _workspaces, sessions: _sessions),
    );
    await _save(tester, 'sesiones');
  });

  testWidgets('captura: chat', (tester) async {
    final client = FakeClient();
    await _pump(tester, client, const ChatScreen(sessionId: 's1'));
    client
      ..emit(
        const HelloMessage(workspaces: _workspaces, sessions: _sessions),
      )
      ..emit(
        BacklogMessage(
          sessionId: 's1',
          items: _chat(),
          cursor: 1,
          pending: [permissionPending()],
        ),
      );
    await _save(tester, 'chat');
  });
}
