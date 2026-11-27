import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'computer.dart';
import 'connection_config.dart';

/// Guarda y recupera los ordenadores emparejados y lo leído por sesión.
abstract class SettingsStore {
  Future<SavedComputers> loadComputers();
  Future<void> saveComputers(SavedComputers computers);

  /// Último seq visto en el móvil por sessionId.
  Future<Map<String, int>> loadSeen();
  Future<void> saveSeen(Map<String, int> seen);
}

class PrefsSettingsStore implements SettingsStore {
  static const _kComputers = 'computers';
  static const _kSeen = 'seen';

  // Formato antiguo: un solo emparejamiento suelto.
  static const _kHost = 'host';
  static const _kPort = 'port';
  static const _kToken = 'token';
  static const _kLan = 'lanHosts';

  @override
  Future<Map<String, int>> loadSeen() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kSeen);
    if (raw == null) return {};
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return {};
      return {
        for (final e in j.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> saveSeen(Map<String, int> seen) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSeen, jsonEncode(seen));
  }

  @override
  Future<SavedComputers> loadComputers() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kComputers);
    if (raw != null) {
      try {
        final j = jsonDecode(raw);
        if (j is Map) {
          final list = [
            if (j['list'] case final List<dynamic> l)
              for (final e in l) ?Computer.fromJson(e),
          ];
          final active = j['active'] as String?;
          return SavedComputers(
            list,
            list.any((c) => c.id == active) ? active : list.firstOrNull?.id,
          );
        }
      } catch (_) {
        // Se intenta el formato antiguo.
      }
    }
    return _legacy(p);
  }

  /// El emparejamiento de antes de poder guardar varios pasa a ser el
  /// primero de la lista; al guardar se escribe ya en el formato nuevo.
  SavedComputers _legacy(SharedPreferences p) {
    final host = p.getString(_kHost);
    final token = p.getString(_kToken);
    if (host == null || host.isEmpty || token == null || token.isEmpty) {
      return const SavedComputers();
    }
    final pc = Computer(
      id: 'pc1',
      config: ConnectionConfig(
        host: host,
        port: p.getInt(_kPort) ?? ConnectionConfig.defaultPort,
        token: token,
        lanHosts: p.getStringList(_kLan) ?? const [],
      ),
    );
    return SavedComputers([pc], pc.id);
  }

  @override
  Future<void> saveComputers(SavedComputers c) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kComputers,
      jsonEncode({
        'active': c.activeId,
        'list': [for (final pc in c.list) pc.toJson()],
      }),
    );
    for (final k in [_kHost, _kPort, _kToken, _kLan]) {
      await p.remove(k);
    }
  }
}

/// Almacén en memoria (tests). Con [config] empieza con un ordenador `pc1`.
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([ConnectionConfig? config])
    : computers = config == null
          ? const SavedComputers()
          : SavedComputers([Computer(id: 'pc1', config: config)], 'pc1');

  SavedComputers computers;
  Map<String, int> seen = {};

  /// Conexión del ordenador en uso.
  ConnectionConfig? get value => computers.active?.config;

  @override
  Future<Map<String, int>> loadSeen() async => Map.of(seen);

  @override
  Future<void> saveSeen(Map<String, int> s) async => seen = Map.of(s);

  @override
  Future<SavedComputers> loadComputers() async => computers;

  @override
  Future<void> saveComputers(SavedComputers c) async => computers = c;
}
