import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Rutas inyectables (HOME de Claude, config de therd, socket de herdr).
class TherdPaths {
  TherdPaths({
    required this.home,
    String? claudeDir,
    String? configDir,
    String? herdrSocket,
    String? uploadsDir,
    String? imagesDir,
  }) : claudeDir = claudeDir ?? p.join(home, '.claude'),
       configDir = configDir ?? p.join(home, '.config', 'therd'),
       herdrSocket =
           herdrSocket ?? p.join(home, '.config', 'herdr', 'herdr.sock'),
       uploadsDir = uploadsDir ?? p.join(home, '.cache', 'therd', 'uploads'),
       imagesDir = imagesDir ?? p.join(home, '.cache', 'therd', 'images');

  /// Resuelve por orden: flags, variables de entorno THERD_*, HOME.
  factory TherdPaths.resolve({
    String? home,
    String? claudeDir,
    String? configDir,
    String? herdrSocket,
    Map<String, String>? env,
  }) {
    final e = env ?? Platform.environment;
    final h = home ?? e['THERD_HOME'] ?? e['HOME'] ?? '.';
    return TherdPaths(
      home: h,
      claudeDir: claudeDir ?? e['THERD_CLAUDE_DIR'],
      configDir: configDir ?? e['THERD_CONFIG_DIR'],
      herdrSocket: herdrSocket ?? e['HERDR_SOCKET_PATH'],
      uploadsDir: e['THERD_UPLOADS_DIR'],
      imagesDir: e['THERD_IMAGES_DIR'],
    );
  }

  final String home;
  final String claudeDir;
  final String configDir;
  final String herdrSocket;

  /// Imágenes enviadas desde la app (las lee Claude Code por su ruta).
  final String uploadsDir;

  /// Imágenes de los transcripts que se sirven a la app. Es independiente de
  /// [uploadsDir]: se poda, así que no puede compartir carpeta con nada ajeno.
  final String imagesDir;

  String get settingsFile => p.join(claudeDir, 'settings.json');
  String get projectsDir => p.join(claudeDir, 'projects');
  String get configFile => p.join(configDir, 'config.json');
  String get pushFile => p.join(configDir, 'push.json');
}

/// Servidor ntfy autoalojado al que se avisa cuando Claude espera y no hay app.
class NtfyConfig {
  NtfyConfig({required this.url, required this.topic, this.token});

  /// URL base del servidor, p. ej. `http://100.x.y.z:24602`.
  final String url;
  final String topic;

  /// Token Bearer para servidores con autenticación (opcional).
  final String? token;

  /// null si falta la URL o el tema (notificaciones desactivadas).
  static NtfyConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    final url = (j['url'] as String? ?? '').trim();
    final topic = (j['topic'] as String? ?? '').trim();
    if (url.isEmpty || topic.isEmpty) return null;
    final t = (j['token'] as String?)?.trim();
    return NtfyConfig(
      url: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
      topic: topic,
      token: t == null || t.isEmpty ? null : t,
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'topic': topic,
    if (token != null) 'token': token,
  };
}

/// Configuración persistida en config.json.
class TherdConfig {
  TherdConfig({
    required this.token,
    this.hookPort = 24600,
    this.appPort = 24601,
    this.bindHost,
    this.lanHosts,
    this.pendingTimeoutSeconds = 120,
    this.ntfy,
  });

  /// IPs de la red local donde el WebSocket escucha además de [bindHost].
  /// null = autodetectar; vacío = solo Tailscale.
  List<String>? lanHosts;

  /// Notificaciones push por ntfy; null = desactivadas.
  NtfyConfig? ntfy;

  String token;
  int hookPort;
  int appPort;

  /// Host de escucha del WebSocket; null = autodetectar IP de Tailscale.
  String? bindHost;
  int pendingTimeoutSeconds;

  Duration get pendingTimeout => Duration(seconds: pendingTimeoutSeconds);

  factory TherdConfig.fromJson(Map<String, dynamic> j) => TherdConfig(
    token: j['token'] as String? ?? '',
    hookPort: (j['hookPort'] as num?)?.toInt() ?? 24600,
    appPort: (j['appPort'] as num?)?.toInt() ?? 24601,
    bindHost: j['bindHost'] as String?,
    lanHosts: j['lanHosts'] is List
        ? [for (final h in j['lanHosts'] as List) '$h']
        : null,
    pendingTimeoutSeconds: (j['pendingTimeoutSeconds'] as num?)?.toInt() ?? 120,
    ntfy: NtfyConfig.fromJson(j['ntfy']),
  );

  Map<String, dynamic> toJson() => {
    'token': token,
    'hookPort': hookPort,
    'appPort': appPort,
    'bindHost': bindHost,
    if (lanHosts != null) 'lanHosts': lanHosts,
    'pendingTimeoutSeconds': pendingTimeoutSeconds,
    if (ntfy != null) 'ntfy': ntfy!.toJson(),
  };

  static String generateToken() {
    final r = Random.secure();
    return [
      for (var i = 0; i < 32; i++)
        r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Carga config.json; si no existe lo crea con token aleatorio (si [create]).
  static TherdConfig load(TherdPaths paths, {bool create = true}) {
    final f = File(paths.configFile);
    TherdConfig cfg;
    var dirty = false;
    if (f.existsSync()) {
      try {
        cfg = TherdConfig.fromJson(
          Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map),
        );
      } catch (e) {
        // No se sobrescribe: sería perder el token y el resto de la config.
        throw ConfigException(
          'No se puede leer la configuración en ${f.path} ($e). '
          'Corrígela o bórrala a mano; therd no la sobrescribe.',
        );
      }
      _fixMode(f);
    } else {
      cfg = TherdConfig(token: '');
      dirty = true;
    }
    if (cfg.token.isEmpty) {
      cfg.token = generateToken();
      dirty = true;
    }
    if (dirty && create) cfg.save(paths);
    return cfg;
  }

  /// Corrige el modo del archivo a 600 si es otro.
  static void _fixMode(File f) {
    if (Platform.isWindows) return;
    try {
      if (f.statSync().mode & 0x1ff != 0x180) {
        Process.runSync('chmod', ['600', f.path]);
      }
    } catch (_) {}
  }

  /// Escritura atómica: temporal 600 en el mismo directorio y rename.
  void save(TherdPaths paths) {
    writePrivateFile(
      File(paths.configFile),
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
    );
  }
}

/// Error de configuración que la CLI muestra tal cual.
class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Escribe [content] en [f] con modo 600 desde el primer byte (directorio
/// nuevo con 700) y lo coloca con un rename atómico.
void writePrivateFile(File f, String content) {
  final dir = f.parent;
  final existed = dir.existsSync();
  dir.createSync(recursive: true);
  if (!existed && !Platform.isWindows) {
    try {
      Process.runSync('chmod', ['700', dir.path]);
    } catch (_) {}
  }
  final tmp = File('${f.path}.tmp');
  tmp.createSync();
  if (!Platform.isWindows) Process.runSync('chmod', ['600', tmp.path]);
  tmp.writeAsStringSync(content, flush: true);
  tmp.renameSync(f.path);
}

/// ¿Es una IP del rango CGNAT de Tailscale (100.64.0.0/10)?
bool isTailscaleAddress(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

/// ¿Es una IPv4 privada de red local (10/8, 172.16/12, 192.168/16)?
bool isPrivateLanAddress(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((n) => n == null)) return false;
  final (a, b) = (p[0]!, p[1]!);
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// Interfaces que no son la red de casa: contenedores, VMs, VPNs.
final _virtualIface = RegExp(
  r'^(lo|docker|br-|veth|virbr|vmnet|vboxnet|tailscale|tun|tap|wg|zt|podman|cni|flannel|lxc|lxd)',
);

/// IPv4 privadas de las interfaces físicas (Ethernet y Wi-Fi).
Future<List<String>> detectLanIps() async {
  try {
    return [
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
        if (!_virtualIface.hasMatch(i.name))
          for (final a in i.addresses)
            if (isPrivateLanAddress(a.address)) a.address,
    ];
  } catch (_) {
    return const [];
  }
}

/// Detecta la IPv4 de Tailscale con `tailscale ip -4` o por interfaces.
Future<String?> detectTailscaleIp() async {
  try {
    final r = await Process.run('tailscale', ['ip', '-4']);
    if (r.exitCode == 0) {
      for (final l in '${r.stdout}'.split('\n')) {
        final ip = l.trim();
        if (isTailscaleAddress(ip)) return ip;
      }
    }
  } catch (_) {}
  try {
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        if (isTailscaleAddress(a.address)) return a.address;
      }
    }
  } catch (_) {}
  return null;
}
