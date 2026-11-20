import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Eventos de Claude Code que therd escucha.
const List<String> hookEvents = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PermissionRequest',
  'PostToolUse',
  'PostToolUseFailure',
  'Notification',
  'Stop',
  'StopFailure',
  'SubagentStart',
  'SubagentStop',
  'PreCompact',
  'PostCompact',
  'SessionEnd',
];

/// Eventos que pueden retenerse esperando a la app (timeout largo).
const Set<String> blockingEvents = {'PermissionRequest', 'PreToolUse'};

const int mirrorTimeoutSeconds = 5;
const int blockingTimeoutSeconds = 180;

/// Cabecera que marca los hooks gestionados por therd (no hay campos propios
/// en el esquema de hooks de Claude Code, así que se marca por cabecera).
const String managedHeader = 'X-Therd-Managed';

/// Construye la sección `hooks` de therd.
///
/// Con [literalToken] null, el token se toma de la variable de entorno
/// THERD_TOKEN (no queda en settings.json, útil si va a un repo de dotfiles).
Map<String, dynamic> buildHooks({int port = 24600, String? literalToken}) {
  final byEnv = literalToken == null;
  final hook = {
    for (final e in hookEvents)
      e: [
        {
          'hooks': [
            {
              'type': 'http',
              'url': 'http://127.0.0.1:$port/hook',
              'timeout': blockingEvents.contains(e)
                  ? blockingTimeoutSeconds
                  : mirrorTimeoutSeconds,
              'headers': {
                'X-Herdr-Pane': r'$HERDR_PANE_ID',
                'Authorization': byEnv
                    ? r'Bearer $THERD_TOKEN'
                    : 'Bearer $literalToken',
                managedHeader: '1',
              },
              'allowedEnvVars': ['HERDR_PANE_ID', if (byEnv) 'THERD_TOKEN'],
            },
          ],
        },
      ],
  };
  return hook;
}

bool _isOurs(Object? h) {
  if (h is! Map || h['type'] != 'http') return false;
  final headers = h['headers'];
  return headers is Map && headers.containsKey(managedHeader);
}

/// Quita de [hooks] los hooks de therd sin tocar los demás. Devuelve cuántos.
int stripManaged(Map<String, dynamic> hooks) {
  var removed = 0;
  for (final event in hooks.keys.toList()) {
    final groups = hooks[event];
    if (groups is! List) continue;
    final keptGroups = <Object?>[];
    for (final g in groups) {
      if (g is Map && g['hooks'] is List) {
        final inner = g['hooks'] as List;
        final kept = inner.where((h) => !_isOurs(h)).toList();
        removed += inner.length - kept.length;
        if (kept.isEmpty && inner.isNotEmpty) continue; // grupo vacío
        if (kept.length != inner.length) {
          keptGroups.add({...g, 'hooks': kept});
          continue;
        }
      }
      keptGroups.add(g);
    }
    if (keptGroups.isEmpty) {
      hooks.remove(event);
    } else {
      hooks[event] = keptGroups;
    }
  }
  return removed;
}

/// Resultado de instalar o desinstalar.
class InstallResult {
  InstallResult({
    required this.changed,
    required this.before,
    required this.after,
    required this.warnings,
    this.backupPath,
  });

  final bool changed;
  final String before;
  final String after;
  final List<String> warnings;
  final String? backupPath;

  /// Diff unificado entre antes y después ('' si no hay cambios).
  String get diff => changed ? unifiedDiff(before, after) : '';
}

String _encode(Map<String, dynamic> m) =>
    '${const JsonEncoder.withIndent('  ').convert(m)}\n';

/// Hooks de Moshi en cualquier evento. En PermissionRequest compiten por la
/// misma decisión; en ExitPlanMode, AskUserQuestion o permission_prompt se
/// quedan con los planes y preguntas antes de que lleguen a therd.
List<String> moshiWarnings(Map<String, dynamic> settings) {
  final hooks = settings['hooks'];
  if (hooks is! Map) return const [];
  final events = <String>[];
  for (final MapEntry(:key, :value) in hooks.entries) {
    if (value is! List) continue;
    final hasMoshi = value.any((g) {
      final inner = g is Map ? g['hooks'] : null;
      return inner is List &&
          inner.any(
            (h) => h is Map && '${h['command']}${h['url']}'.contains('moshi'),
          );
    });
    if (hasMoshi) events.add('$key');
  }
  if (events.isEmpty) return const [];
  return [
    'Hay hooks de Moshi en ${events.join(', ')}. Moshi y therd se pisan: '
        'los planes y las preguntas pueden no llegar a la app de therd. '
        'Quita los de Moshi o usa solo uno.',
  ];
}

/// Instalador de hooks en `~/.claude/settings.json`. Escribe A TRAVÉS de
/// enlaces simbólicos (el archivo suele ser un symlink de stow) y deja una
/// copia de seguridad antes de cualquier cambio real.
class Installer {
  Installer({required this.settingsFile, this.port = 24600});

  final String settingsFile;
  final int port;

  Map<String, dynamic> _read() {
    final f = File(settingsFile);
    if (!f.existsSync()) return {};
    final text = f.readAsStringSync();
    if (text.trim().isEmpty) return {};
    final v = jsonDecode(text);
    if (v is! Map) {
      throw const FormatException('settings.json no es un objeto JSON');
    }
    return Map<String, dynamic>.from(v);
  }

  String _readRaw() {
    final f = File(settingsFile);
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  /// Instala (idempotente: reemplaza los hooks propios por los actuales).
  InstallResult install({String? literalToken, bool dryRun = false}) {
    final raw = _readRaw();
    final settings = _read();
    final warnings = moshiWarnings(settings);

    final hooks = settings['hooks'] is Map
        ? Map<String, dynamic>.from(settings['hooks'] as Map)
        : <String, dynamic>{};
    stripManaged(hooks);
    final ours = buildHooks(port: port, literalToken: literalToken);
    for (final e in ours.entries) {
      final existing = hooks[e.key];
      hooks[e.key] = [if (existing is List) ...existing, ...(e.value as List)];
    }
    settings['hooks'] = hooks;
    return _finish(raw, settings, warnings, dryRun);
  }

  /// Quita los hooks de therd sin tocar los demás.
  InstallResult uninstall({bool dryRun = false}) {
    final raw = _readRaw();
    if (raw.trim().isEmpty) {
      return InstallResult(
        changed: false,
        before: raw,
        after: raw,
        warnings: const [],
      );
    }
    final settings = _read();
    final hooks = settings['hooks'];
    if (hooks is Map) {
      final h = Map<String, dynamic>.from(hooks);
      stripManaged(h);
      if (h.isEmpty) {
        settings.remove('hooks');
      } else {
        settings['hooks'] = h;
      }
    }
    return _finish(raw, settings, const [], dryRun);
  }

  /// ¿Están instalados los hooks (todos los eventos)?
  Set<String> installedEvents() {
    final hooks = _read()['hooks'];
    final found = <String>{};
    if (hooks is Map) {
      for (final e in hooks.entries) {
        final groups = e.value;
        if (groups is! List) continue;
        for (final g in groups) {
          final inner = g is Map ? g['hooks'] : null;
          if (inner is List && inner.any(_isOurs)) found.add('${e.key}');
        }
      }
    }
    return found;
  }

  InstallResult _finish(
    String raw,
    Map<String, dynamic> settings,
    List<String> warnings,
    bool dryRun,
  ) {
    final after = _encode(settings);
    // Si el archivo original ya equivale al resultado, no hay cambios
    // (aunque el formato difiera).
    var changed = after != raw;
    if (changed && raw.trim().isNotEmpty) {
      try {
        changed = jsonEncode(jsonDecode(raw)) != jsonEncode(settings);
      } catch (_) {}
    }
    String? backup;
    if (changed && !dryRun) {
      final f = File(settingsFile);
      f.parent.createSync(recursive: true);
      if (f.existsSync()) {
        final stamp = DateTime.now()
            .toUtc()
            .toIso8601String()
            .replaceAll(RegExp(r'[^0-9]'), '')
            .substring(0, 14);
        // La copia va junto al enlace, no dentro del destino del symlink.
        backup = p.join(
          p.dirname(settingsFile),
          '${p.basename(settingsFile)}.therd-backup-$stamp',
        );
        File(backup).writeAsStringSync(raw);
      }
      // writeAsString abre el destino: respeta el symlink de stow.
      f.writeAsStringSync(after);
    }
    return InstallResult(
      changed: changed,
      before: raw,
      after: after,
      warnings: warnings,
      backupPath: backup,
    );
  }
}

/// Diff unificado sencillo por líneas (LCS), con 2 líneas de contexto.
String unifiedDiff(
  String a,
  String b, {
  String from = 'antes',
  String to = 'después',
}) {
  final x = a.isEmpty ? <String>[] : a.trimRight().split('\n');
  final y = b.isEmpty ? <String>[] : b.trimRight().split('\n');
  final n = x.length;
  final m = y.length;
  final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = x[i] == y[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  // Operaciones: ' ' igual, '-' quitada, '+' añadida.
  final ops = <(String, String)>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (x[i] == y[j]) {
      ops.add((' ', x[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      ops.add(('-', x[i++]));
    } else {
      ops.add(('+', y[j++]));
    }
  }
  while (i < n) {
    ops.add(('-', x[i++]));
  }
  while (j < m) {
    ops.add(('+', y[j++]));
  }

  const ctx = 2;
  final keep = List.filled(ops.length, false);
  for (var k = 0; k < ops.length; k++) {
    if (ops[k].$1 == ' ') continue;
    for (var d = -ctx; d <= ctx; d++) {
      final idx = k + d;
      if (idx >= 0 && idx < ops.length) keep[idx] = true;
    }
  }
  final out = StringBuffer('--- $from\n+++ $to\n');
  var skipped = false;
  for (var k = 0; k < ops.length; k++) {
    if (!keep[k]) {
      skipped = true;
      continue;
    }
    if (skipped) out.writeln('...');
    skipped = false;
    out.writeln('${ops[k].$1}${ops[k].$2}');
  }
  return out.toString();
}
