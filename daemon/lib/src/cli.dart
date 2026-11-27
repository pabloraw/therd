import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'config.dart';
import 'daemon.dart';
import 'doctor.dart';
import 'installer.dart';
import 'log.dart';
import 'notifier.dart';
import 'pair.dart';

const String usage = '''
therd: vista de chat para Claude Code en herdr.

Uso: therd <comando> [opciones]

Comandos:
  serve        Arranca el daemon (hooks en 127.0.0.1, WebSocket en la IP de Tailscale)
  install      Instala los hooks en ~/.claude/settings.json (--dry-run para ver el diff)
  uninstall    Quita los hooks de therd sin tocar los demás
  pair         Imprime el QR y la URL de emparejamiento para la app
  doctor       Diagnóstico: herdr, ntfy, Tailscale, puertos, hooks y Moshi
  notify-test  Manda una notificación de prueba al ntfy configurado
''';

ArgParser _common(ArgParser p) => p
  ..addOption('home', help: 'HOME alternativo (también THERD_HOME)')
  ..addOption(
    'claude-dir',
    help: 'Carpeta de Claude Code (por defecto ~/.claude)',
  )
  ..addOption(
    'config-dir',
    help: 'Carpeta de config de therd (por defecto ~/.config/therd)',
  )
  ..addOption(
    'herdr-socket',
    help: 'Socket de herdr (por defecto \$HERDR_SOCKET_PATH)',
  )
  ..addOption('hook-port', help: 'Puerto HTTP de hooks (por defecto 24600)')
  ..addOption(
    'app-port',
    help: 'Puerto WebSocket de la app (por defecto 24601)',
  )
  ..addOption(
    'bind',
    help: 'IP de escucha del WebSocket (por defecto la de Tailscale)',
  )
  ..addOption(
    'pending-timeout',
    help: 'Segundos que se retiene un permiso (por defecto 120)',
  )
  ..addFlag(
    'verbose',
    abbr: 'v',
    negatable: false,
    help: 'Más detalle en el log',
  );

ArgParser buildParser() {
  final root = ArgParser()..addFlag('help', abbr: 'h', negatable: false);
  _common(root.addCommand('serve'));
  _common(root.addCommand('install'))
    ..addFlag('dry-run', negatable: false, help: 'Solo muestra el diff')
    ..addFlag(
      'literal-token',
      negatable: false,
      help: 'Escribe el token en settings.json (por defecto usa \$THERD_TOKEN)',
    );
  _common(
    root.addCommand('uninstall'),
  ).addFlag('dry-run', negatable: false, help: 'Solo muestra el diff');
  _common(root.addCommand('pair'))
    ..addOption('host', help: 'Host que se incluye en la URL')
    ..addFlag('no-color', negatable: false);
  _common(root.addCommand('doctor'));
  _common(root.addCommand('notify-test'));
  return root;
}

/// Ejecuta la CLI y devuelve el código de salida.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  Completer<void>? stopSignal,
}) async {
  final sink = out ?? stdout;
  final parser = buildParser();
  ArgResults r;
  try {
    r = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$usage');
    return 64;
  }
  final cmd = r.command;
  if (r['help'] == true || cmd == null) {
    sink.writeln(usage);
    return cmd == null && r['help'] != true ? 64 : 0;
  }
  Log.verbose = cmd['verbose'] == true;

  final paths = TherdPaths.resolve(
    home: cmd['home'] as String?,
    claudeDir: cmd['claude-dir'] as String?,
    configDir: cmd['config-dir'] as String?,
    herdrSocket: cmd['herdr-socket'] as String?,
  );

  int? intOpt(String name) {
    final v = cmd[name] as String?;
    if (v == null) return null;
    final n = int.tryParse(v);
    if (n == null) throw FormatException('--$name debe ser un número');
    return n;
  }

  try {
    final dry = cmd.options.contains('dry-run') && cmd['dry-run'] == true;
    final create = cmd.name != 'doctor' && !dry;
    final config = TherdConfig.load(paths, create: create);
    config.hookPort = intOpt('hook-port') ?? config.hookPort;
    config.appPort = intOpt('app-port') ?? config.appPort;
    config.pendingTimeoutSeconds =
        intOpt('pending-timeout') ?? config.pendingTimeoutSeconds;
    final bind = cmd['bind'] as String?;

    switch (cmd.name) {
      case 'serve':
        return await _serveGuarded(paths, config, bind, sink, stopSignal);
      case 'install':
        return _install(paths, config, cmd, sink);
      case 'uninstall':
        return _uninstall(paths, config, cmd, sink);
      case 'pair':
        return await _pair(config, cmd, bind, sink);
      case 'doctor':
        return await _doctor(paths, config, bind, sink);
      case 'notify-test':
        return await _notifyTest(config, sink);
    }
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    return 64;
  } on ConfigException catch (e) {
    stderr.writeln('Error: ${e.message}');
    return 78;
  }
  return 64;
}

/// Ejecuta el servidor en una zona que registra los errores no capturados
/// (un timer o un future suelto) en vez de dejar que maten el proceso.
Future<int> _serveGuarded(
  TherdPaths paths,
  TherdConfig config,
  String? bind,
  StringSink sink,
  Completer<void>? stopSignal,
) {
  final result = Completer<int>();
  runZonedGuarded(() async {
    try {
      result.complete(await _serve(paths, config, bind, sink, stopSignal));
    } catch (e, st) {
      // Un fallo del propio arranque sí debe terminar con error.
      if (!result.isCompleted) result.completeError(e, st);
    }
  }, (e, st) => Log.error('Error no capturado', e, st));
  return result.future;
}

Future<int> _serve(
  TherdPaths paths,
  TherdConfig config,
  String? bind,
  StringSink sink,
  Completer<void>? stopSignal,
) async {
  var host = bind ?? config.bindHost;
  if (host == null) {
    host = await detectTailscaleIp();
    if (host == null) {
      host = '127.0.0.1';
      Log.warn(
        'No se detectó IP de Tailscale: el WebSocket escucha solo en 127.0.0.1. '
        'Usa --bind <ip> para elegir otra.',
      );
    }
  }
  final lan = await _lanHosts(config, host);
  final daemon = Daemon(
    paths: paths,
    config: config,
    appHost: host,
    lanHosts: lan,
  );
  try {
    await daemon.start();
  } on SocketException catch (e) {
    stderr.writeln(
      'No se pudo abrir el puerto (${e.osError?.message ?? e.message}). '
      '¿Hay otro therd en marcha? Prueba con therd doctor.',
    );
    await daemon.stop();
    return 1;
  }
  Log.info('therd en marcha');
  Log.info('  hooks:     http://127.0.0.1:${daemon.hookServer.port}/hook');
  Log.info('  app (ws):  ws://$host:${daemon.appServer.port}/');
  for (final h in daemon.appServer.lanBound) {
    Log.info('  red local: ws://$h:${daemon.appServer.port}/');
  }
  Log.info('  sesiones:  ${daemon.store.sessions.length}');
  for (final s in daemon.store.sessions) {
    Log.info(
      '    ${s.sessionId.substring(0, s.sessionId.length < 8 ? s.sessionId.length : 8)} '
      '${s.status.name.padRight(8)} ${s.title} (${s.cwd})',
    );
  }

  final done = stopSignal ?? Completer<void>();
  final subs = [
    ProcessSignal.sigint.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    }),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) {
        if (!done.isCompleted) done.complete();
      }),
  ];
  await done.future;
  for (final s in subs) {
    await s.cancel();
  }
  Log.info('Deteniendo therd');
  await daemon.stop();
  return 0;
}

int _install(
  TherdPaths paths,
  TherdConfig config,
  ArgResults cmd,
  StringSink sink,
) {
  final dry = cmd['dry-run'] == true;
  final literal = cmd['literal-token'] == true;
  final inst = Installer(
    settingsFile: paths.settingsFile,
    port: config.hookPort,
  );
  final res = inst.install(
    literalToken: literal ? (dry ? '<token>' : config.token) : null,
    dryRun: dry,
  );
  for (final w in res.warnings) {
    sink.writeln('AVISO: $w');
  }
  if (!res.changed) {
    sink.writeln(
      'Los hooks ya estaban instalados en ${paths.settingsFile}, sin cambios.',
    );
    return 0;
  }
  if (dry) {
    sink.writeln(
      'Simulación (no se escribió nada). Cambios en ${paths.settingsFile}:',
    );
    sink.writeln(res.diff);
    return 0;
  }
  sink.writeln('Hooks instalados en ${paths.settingsFile}.');
  if (res.backupPath != null) {
    sink.writeln('Copia de seguridad: ${res.backupPath}');
  }
  if (!literal) {
    sink.writeln(
      'Los hooks leen el token de la variable THERD_TOKEN. Expórtala antes de '
      'lanzar Claude Code, por ejemplo:\n'
      '  export THERD_TOKEN=\$(jq -r .token ${paths.configFile})',
    );
  }
  sink.writeln(
    'Reinicia las sesiones de Claude Code abiertas para que lean los hooks.',
  );
  return 0;
}

int _uninstall(
  TherdPaths paths,
  TherdConfig config,
  ArgResults cmd,
  StringSink sink,
) {
  final dry = cmd['dry-run'] == true;
  final inst = Installer(
    settingsFile: paths.settingsFile,
    port: config.hookPort,
  );
  final res = inst.uninstall(dryRun: dry);
  if (!res.changed) {
    sink.writeln('No había hooks de therd en ${paths.settingsFile}.');
    return 0;
  }
  if (dry) {
    sink.writeln('Simulación (no se escribió nada):');
    sink.writeln(res.diff);
    return 0;
  }
  sink.writeln('Hooks de therd quitados de ${paths.settingsFile}.');
  if (res.backupPath != null) {
    sink.writeln('Copia de seguridad: ${res.backupPath}');
  }
  return 0;
}

Future<int> _pair(
  TherdConfig config,
  ArgResults cmd,
  String? bind,
  StringSink sink,
) async {
  final host =
      (cmd['host'] as String?) ??
      bind ??
      config.bindHost ??
      await detectTailscaleIp();
  if (host == null) {
    stderr.writeln(
      'No se detectó IP de Tailscale. Usa --host <ip> para indicar la dirección.',
    );
    return 1;
  }
  final url = pairingUrl(
    host,
    config.appPort,
    config.token,
    lan: await _lanHosts(config, host),
  );
  sink.writeln('Escanea este código con la app de therd:\n');
  sink.write(renderQr(url, color: cmd['no-color'] != true));
  sink.writeln('\nO escribe la URL a mano:\n  $url');
  return 0;
}

/// IPs de la red local para el WebSocket: las de la config o las detectadas,
/// sin repetir [host]. Escuchando en todas (0.0.0.0) no hacen falta.
Future<List<String>> _lanHosts(TherdConfig config, String host) async {
  if (host == '0.0.0.0') return const [];
  final ips = config.lanHosts ?? await detectLanIps();
  return [
    for (final ip in ips.toSet())
      if (ip != host) ip,
  ];
}

Future<int> _notifyTest(TherdConfig config, StringSink sink) async {
  final ntfy = config.ntfy;
  if (ntfy == null) {
    stderr.writeln(
      'No hay "ntfy" en la configuración. Añade url y topic al config.json.',
    );
    return 1;
  }
  final ok = await NtfyClient(ntfy).publish(
    title: 'Prueba de therd',
    message: 'Si lees esto, las notificaciones funcionan.',
    tags: const ['white_check_mark'],
  );
  if (ok) {
    sink.writeln('Notificación enviada a ${ntfy.url}, tema ${ntfy.topic}.');
    return 0;
  }
  stderr.writeln(
    'No se pudo publicar en ${ntfy.url}. Revisa la URL, el tema y el token '
    '(therd doctor comprueba el servidor).',
  );
  return 1;
}

Future<int> _doctor(
  TherdPaths paths,
  TherdConfig config,
  String? bind,
  StringSink sink,
) async {
  final results = await runDoctor(
    paths: paths,
    config: config,
    bindOverride: bind,
  );
  var failed = false;
  for (final c in results) {
    final tag = switch (c.level) {
      CheckLevel.ok => '[ok]    ',
      CheckLevel.warn => '[aviso] ',
      CheckLevel.fail => '[fallo] ',
    };
    if (c.level == CheckLevel.fail) failed = true;
    sink.writeln('$tag${c.title}${c.detail.isEmpty ? '' : ': ${c.detail}'}');
  }
  return failed ? 1 : 0;
}
