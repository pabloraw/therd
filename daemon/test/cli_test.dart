import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/cli.dart';
import 'package:therd_daemon/src/config.dart';
import 'package:therd_daemon/src/pair.dart';

import 'support.dart';

void main() {
  late Directory tmp;
  late List<String> base;

  setUp(() {
    tmp = makeTemp('cli');
    Directory('${tmp.path}/claude').createSync();
    base = [
      '--home',
      tmp.path,
      '--claude-dir',
      '${tmp.path}/claude',
      '--config-dir',
      '${tmp.path}/cfg',
      '--herdr-socket',
      '${tmp.path}/no.sock',
    ];
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('pair: URL therd:// con host, puerto y token, y QR no vacío', () async {
    final out = StringBuffer();
    expect(
      await runCli([
        'pair',
        ...base,
        '--host',
        '100.1.2.3',
        '--app-port',
        '34601',
        '--no-color',
      ], out: out),
      0,
    );
    final cfg = TherdConfig.load(
      TherdPaths(home: tmp.path, configDir: '${tmp.path}/cfg'),
    );
    expect(
      out.toString(),
      contains('therd://100.1.2.3:34601?token=${cfg.token}'),
    );
    expect(out.toString(), contains('█'));
    expect(renderQr('hola').split('\n').length, greaterThan(10));
    expect(cfg.token, hasLength(64));
  });

  test(
    'pair: las IPs de lanHosts van en la URL para probarlas primero',
    () async {
      final paths = TherdPaths(home: tmp.path, configDir: '${tmp.path}/cfg');
      TherdConfig.load(paths)
        ..lanHosts = ['192.168.1.5', '100.1.2.3']
        ..save(paths);
      final out = StringBuffer();
      await runCli([
        'pair',
        ...base,
        '--host',
        '100.1.2.3',
        '--no-color',
      ], out: out);
      expect(out.toString(), contains('&lan=192.168.1.5\n'));
      expect(TherdConfig.load(paths).lanHosts, ['192.168.1.5', '100.1.2.3']);
    },
  );

  test('IPs privadas de red local', () {
    for (final ip in ['192.168.1.5', '10.0.0.2', '172.16.0.1', '172.31.9.9']) {
      expect(isPrivateLanAddress(ip), isTrue, reason: ip);
    }
    for (final ip in ['100.66.1.1', '172.32.0.1', '8.8.8.8', 'basura']) {
      expect(isPrivateLanAddress(ip), isFalse, reason: ip);
    }
  });

  test(
    'install --dry-run no escribe ni crea config; install real y uninstall',
    () async {
      final out = StringBuffer();
      expect(await runCli(['install', ...base, '--dry-run'], out: out), 0);
      expect(File('${tmp.path}/claude/settings.json').existsSync(), isFalse);
      expect(File('${tmp.path}/cfg/config.json').existsSync(), isFalse);
      expect(out.toString(), contains('Simulación'));

      out.clear();
      expect(await runCli(['install', ...base], out: out), 0);
      expect(
        File('${tmp.path}/claude/settings.json').readAsStringSync(),
        contains('X-Therd-Managed'),
      );
      expect(out.toString(), contains('THERD_TOKEN'));

      out.clear();
      expect(await runCli(['install', ...base], out: out), 0);
      expect(out.toString(), contains('sin cambios'));

      out.clear();
      expect(await runCli(['uninstall', ...base], out: out), 0);
      expect(
        File('${tmp.path}/claude/settings.json').readAsStringSync(),
        isNot(contains('X-Therd-Managed')),
      );
    },
  );

  test('doctor: sin herdr falla con mensaje, con herdr falso pasa', () async {
    var out = StringBuffer();
    expect(
      await runCli([
        'doctor',
        ...base,
        '--bind',
        '127.0.0.1',
        '--hook-port',
        '0',
        '--app-port',
        '0',
      ], out: out),
      1,
    );
    expect(out.toString(), contains('[fallo] Socket de herdr no encontrado'));

    final fake = FakeHerdr('${tmp.path}/h.sock');
    await fake.start();
    fake.handlers['agent.list'] = (_) => {
      'result': {
        'agents': [agentJson(paneId: 'w:p1', sessionId: 's')],
      },
    };
    out = StringBuffer();
    final code = await runCli(
      [
          ...base.take(base.length - 2),
          '--herdr-socket',
          '${tmp.path}/h.sock',
        ].toList()
        ..insert(0, 'doctor')
        ..addAll([
          '--bind',
          '127.0.0.1',
          '--hook-port',
          '0',
          '--app-port',
          '0',
        ]),
      out: out,
    );
    await fake.stop();
    expect(code, 0, reason: out.toString());
    expect(
      out.toString(),
      contains('[ok]    herdr responde a agent.list: 1 sesiones'),
    );
    expect(out.toString(), contains('Hooks de therd sin instalar'));
  });

  test('una config corrupta no se sobrescribe y da error claro', () async {
    Directory('${tmp.path}/cfg').createSync();
    final f = File('${tmp.path}/cfg/config.json')..writeAsStringSync('{roto');
    final paths = TherdPaths(home: tmp.path, configDir: '${tmp.path}/cfg');
    expect(
      () => TherdConfig.load(paths),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'mensaje',
          contains(f.path),
        ),
      ),
    );
    expect(f.readAsStringSync(), '{roto');
    expect(await runCli(['doctor', ...base], out: StringBuffer()), 78);
    expect(f.readAsStringSync(), '{roto');
  });

  test(
    'la config se guarda con modo 600 y load corrige otro modo',
    () {
      final paths = TherdPaths(home: tmp.path, configDir: '${tmp.path}/cfg');
      TherdConfig.load(paths);
      int mode() => File(paths.configFile).statSync().mode & 0x1ff;
      expect(mode(), 0x180);
      Process.runSync('chmod', ['644', paths.configFile]);
      TherdConfig.load(paths);
      expect(mode(), 0x180);
    },
    testOn: 'linux || mac-os',
  );

  test('imagesDir no depende de uploadsDir', () {
    final p = TherdPaths.resolve(
      home: '/h',
      env: {'THERD_UPLOADS_DIR': '/x/uploads'},
    );
    expect(p.imagesDir, '/h/.cache/therd/images');
    expect(
      TherdPaths.resolve(home: '/h', env: {'THERD_IMAGES_DIR': '/i'}).imagesDir,
      '/i',
    );
  });
}
