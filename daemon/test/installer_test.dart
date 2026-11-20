import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/installer.dart';

import 'support.dart';

const original = '''{
  "env": {
    "A": "1"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/herdr-agent-state.sh"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "moshi-hook claude-hook"
          }
        ]
      }
    ]
  }
}
''';

void main() {
  late Directory tmp;
  late File real;
  late Link link;
  late Installer inst;

  setUp(() {
    tmp = makeTemp('inst');
    // El settings.json real vive en otra carpeta (stow) y el de Claude es un symlink.
    Directory('${tmp.path}/dotfiles').createSync();
    real = File('${tmp.path}/dotfiles/settings.json')
      ..writeAsStringSync(original);
    Directory('${tmp.path}/claude').createSync();
    link = Link('${tmp.path}/claude/settings.json')
      ..createSync('../dotfiles/settings.json');
    inst = Installer(settingsFile: link.path);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  List<FileSystemEntity> backups() => Directory(
    '${tmp.path}/claude',
  ).listSync().where((e) => e.path.contains('therd-backup')).toList();

  Map<String, dynamic> read() =>
      jsonDecode(real.readAsStringSync()) as Map<String, dynamic>;

  test('instala escribiendo a través del symlink, con copia de seguridad', () {
    final r = inst.install();
    expect(r.changed, isTrue);
    expect(
      FileSystemEntity.isLinkSync(link.path),
      isTrue,
      reason: 'el enlace sigue siendo enlace',
    );
    expect(read()['env'], {'A': '1'});
    final hooks = read()['hooks'] as Map;
    for (final e in hookEvents) {
      expect(hooks.containsKey(e), isTrue, reason: e);
    }
    // Los hooks ajenos siguen ahí.
    expect(jsonEncode(hooks['SessionStart']), contains('herdr-agent-state.sh'));
    expect(jsonEncode(hooks['PermissionRequest']), contains('moshi-hook'));
    // Copia de seguridad con el contenido original, junto al enlace.
    expect(r.backupPath, isNotNull);
    expect(File(r.backupPath!).readAsStringSync(), original);
    expect(File(r.backupPath!).parent.path, '${tmp.path}/claude');
    expect(r.warnings.single, contains('Moshi'));
  });

  test('Moshi en ExitPlanMode también avisa, aunque no esté en permisos', () {
    final w = moshiWarnings({
      'hooks': {
        'PreToolUse': [
          {
            'matcher': 'ExitPlanMode',
            'hooks': [
              {'type': 'command', 'command': "'/x/moshi-hook' claude-hook"},
            ],
          },
        ],
        'Stop': [
          {
            'hooks': [
              {'type': 'http', 'url': 'http://127.0.0.1:24600/hook'},
            ],
          },
        ],
      },
    });
    expect(w.single, contains('PreToolUse'));
    expect(w.single, isNot(contains('Stop')));
    expect(moshiWarnings({'hooks': {}}), isEmpty);
  });

  test('formato de los hooks: http, timeouts y token por entorno', () {
    inst.install();
    final hooks = read()['hooks'] as Map;
    final perm = (hooks['PermissionRequest'] as List).last['hooks'][0] as Map;
    expect(perm['type'], 'http');
    expect(perm['url'], 'http://127.0.0.1:24600/hook');
    expect(perm['timeout'], 180);
    expect(perm['headers']['Authorization'], r'Bearer $THERD_TOKEN');
    expect(perm['headers']['X-Herdr-Pane'], r'$HERDR_PANE_ID');
    expect(perm['allowedEnvVars'], ['HERDR_PANE_ID', 'THERD_TOKEN']);
    final stop = (hooks['Stop'] as List).single['hooks'][0] as Map;
    expect(stop['timeout'], 5);
    expect(stop.containsKey('onFailure'), isFalse);
    expect((hooks['PreToolUse'] as List).single['hooks'][0]['timeout'], 180);
  });

  test('token literal opcional', () {
    inst.install(literalToken: 'abc123');
    final h = (read()['hooks']['Stop'] as List).single['hooks'][0] as Map;
    expect(h['headers']['Authorization'], 'Bearer abc123');
    expect(h['allowedEnvVars'], ['HERDR_PANE_ID']);
  });

  test('es idempotente: la segunda vez no cambia nada ni crea otra copia', () {
    inst.install();
    final after1 = real.readAsStringSync();
    final r2 = inst.install();
    expect(r2.changed, isFalse);
    expect(r2.backupPath, isNull);
    expect(backups(), hasLength(1));
    expect(real.readAsStringSync(), after1);
    expect(backups(), hasLength(1), reason: 'sin segunda copia');
    expect(inst.installedEvents(), hookEvents.toSet());
  });

  test('cambiar el puerto reemplaza los hooks propios sin duplicar', () {
    inst.install();
    Installer(settingsFile: link.path, port: 34600).install();
    final hooks = read()['hooks'] as Map;
    expect(hooks['Stop'], hasLength(1));
    expect(jsonEncode(hooks['Stop']), contains(':34600/'));
  });

  test('uninstall quita solo lo nuestro y deja el resto', () {
    inst.install();
    final r = inst.uninstall();
    expect(r.changed, isTrue);
    expect(read(), jsonDecode(original));
    expect(FileSystemEntity.isLinkSync(link.path), isTrue);
    expect(inst.installedEvents(), isEmpty);
    // y de nuevo no cambia nada
    expect(inst.uninstall().changed, isFalse);
  });

  test('uninstall quita hooks si quedan vacíos', () {
    real.writeAsStringSync('{"x":1}');
    inst.install();
    inst.uninstall();
    expect(read(), {'x': 1});
  });

  test('dry-run no escribe y devuelve el diff', () {
    final r = inst.install(dryRun: true);
    expect(r.changed, isTrue);
    expect(real.readAsStringSync(), original);
    expect(r.backupPath, isNull);
    expect(r.diff, contains('+++'));
    expect(r.diff, contains('+            "type": "http",'));
    expect(backups(), isEmpty);
    expect(inst.uninstall(dryRun: true).changed, isFalse);
  });

  test(
    'archivo inexistente: lo crea; uninstall sobre inexistente no lo crea',
    () {
      final missing = Installer(settingsFile: '${tmp.path}/claude/nuevo.json');
      expect(missing.uninstall().changed, isFalse);
      expect(File('${tmp.path}/claude/nuevo.json').existsSync(), isFalse);
      missing.install();
      expect(File('${tmp.path}/claude/nuevo.json').existsSync(), isTrue);
    },
  );

  test(
    'plugin/hooks/hooks.json equivale a los hooks de install por entorno',
    () {
      final plugin =
          jsonDecode(File('../plugin/hooks/hooks.json').readAsStringSync())
              as Map;
      expect(plugin['hooks'], jsonDecode(jsonEncode(buildHooks())));
    },
  );
}
