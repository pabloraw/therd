import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'herdr_client.dart';
import 'installer.dart';
import 'notifier.dart';

enum CheckLevel { ok, warn, fail }

class CheckResult {
  const CheckResult(this.level, this.title, [this.detail = '']);
  final CheckLevel level;
  final String title;
  final String detail;
}

Future<bool> _portFree(String host, int port) async {
  try {
    final s = await ServerSocket.bind(host, port);
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// Diagnóstico de la instalación. No modifica nada.
Future<List<CheckResult>> runDoctor({
  required TherdPaths paths,
  required TherdConfig config,
  String? bindOverride,
}) async {
  final out = <CheckResult>[];

  // Config
  out.add(
    File(paths.configFile).existsSync()
        ? CheckResult(CheckLevel.ok, 'Configuración', paths.configFile)
        : CheckResult(
            CheckLevel.warn,
            'Sin configuración todavía',
            'Se creará con token aleatorio en ${paths.configFile} al ejecutar '
                'therd install o therd serve.',
          ),
  );

  if (!Platform.isWindows && File(paths.configFile).existsSync()) {
    try {
      final mode = File(paths.configFile).statSync().mode & 0x1ff;
      if (mode != 0x180) {
        out.add(
          CheckResult(
            CheckLevel.warn,
            'Permisos de la configuración',
            'config.json tiene modo ${mode.toRadixString(8)} y guarda el token; '
                'debería ser 600 (chmod 600 ${paths.configFile}).',
          ),
        );
      }
    } catch (_) {}
  }

  // herdr
  final herdr = HerdrClient(paths.herdrSocket);
  if (!File(paths.herdrSocket).existsSync()) {
    out.add(
      CheckResult(
        CheckLevel.fail,
        'Socket de herdr no encontrado',
        '${paths.herdrSocket} (¿herdr está en marcha? Prueba con HERDR_SOCKET_PATH)',
      ),
    );
  } else {
    try {
      final agents = await herdr.agentList();
      final claude = agents.where((a) => a.isClaude).length;
      out.add(
        CheckResult(
          CheckLevel.ok,
          'herdr responde a agent.list',
          '$claude sesiones de Claude Code, ${agents.length} agentes en total',
        ),
      );
    } on HerdrException catch (e) {
      out.add(CheckResult(CheckLevel.fail, 'herdr no responde', e.message));
    }
  }

  // Notificaciones ntfy
  final ntfy = config.ntfy;
  if (ntfy == null) {
    out.add(
      const CheckResult(
        CheckLevel.ok,
        'Notificaciones push desactivadas',
        'Añade "ntfy" (url, topic y token opcional) al config.json para activarlas.',
      ),
    );
  } else {
    final problem = await NtfyClient(ntfy).health();
    out.add(
      problem == null
          ? CheckResult(
              CheckLevel.ok,
              'ntfy responde',
              '${ntfy.url}, tema ${ntfy.topic}',
            )
          : CheckResult(
              CheckLevel.warn,
              'ntfy no responde',
              '${ntfy.url} ($problem)',
            ),
    );
  }

  // Tailscale
  final ts = await detectTailscaleIp();
  final host = bindOverride ?? config.bindHost ?? ts;
  if (ts != null) {
    out.add(CheckResult(CheckLevel.ok, 'IP de Tailscale', ts));
  } else {
    out.add(
      CheckResult(
        CheckLevel.warn,
        'No se detectó IP de Tailscale',
        'Sin ella el WebSocket solo escucharía en 127.0.0.1. '
            'Usa --bind o bindHost en la configuración.',
      ),
    );
  }

  // Puertos
  for (final (label, h, port) in [
    ('Puerto de hooks', '127.0.0.1', config.hookPort),
    ('Puerto de la app', host ?? '127.0.0.1', config.appPort),
  ]) {
    out.add(
      await _portFree(h, port)
          ? CheckResult(CheckLevel.ok, '$label libre', '$h:$port')
          : CheckResult(
              CheckLevel.warn,
              '$label ocupado',
              '$h:$port (¿therd ya está en marcha?)',
            ),
    );
  }

  // Hooks instalados
  final inst = Installer(
    settingsFile: paths.settingsFile,
    port: config.hookPort,
  );
  try {
    final found = inst.installedEvents();
    if (found.length == hookEvents.length) {
      out.add(
        CheckResult(
          CheckLevel.ok,
          'Hooks de therd instalados',
          '${found.length} eventos en ${paths.settingsFile}',
        ),
      );
    } else if (found.isEmpty) {
      out.add(
        CheckResult(
          CheckLevel.warn,
          'Hooks de therd sin instalar',
          'Ejecuta therd install (o instala el plugin de plugin/).',
        ),
      );
    } else {
      final missing = hookEvents.where((e) => !found.contains(e)).join(', ');
      out.add(
        CheckResult(
          CheckLevel.warn,
          'Hooks de therd incompletos',
          'Faltan: $missing. Ejecuta therd install.',
        ),
      );
    }
    final settings = File(paths.settingsFile).existsSync()
        ? File(paths.settingsFile).readAsStringSync()
        : '';
    if (settings.contains(r'$THERD_TOKEN') &&
        (Platform.environment['THERD_TOKEN'] ?? '').isEmpty) {
      out.add(
        const CheckResult(
          CheckLevel.warn,
          'THERD_TOKEN no está definida en este entorno',
          'Los hooks usan la variable THERD_TOKEN. Sin ella siguen '
              'funcionando (el daemon acepta hooks sin token en 127.0.0.1), '
              'pero con ella se rechazan los de un token ajeno.',
        ),
      );
    }
    // Moshi
    if (File(paths.settingsFile).existsSync() && settings.trim().isNotEmpty) {
      final w = moshiWarnings(
        Map<String, dynamic>.from(jsonDecode(settings) as Map),
      );
      out.add(
        w.isEmpty
            ? const CheckResult(CheckLevel.ok, 'Sin hooks de Moshi')
            : CheckResult(CheckLevel.warn, 'Convivencia con Moshi', w.first),
      );
    }
  } on FormatException catch (e) {
    out.add(
      CheckResult(
        CheckLevel.fail,
        'No se pudo leer ${paths.settingsFile}',
        e.message,
      ),
    );
  }
  return out;
}
