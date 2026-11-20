import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'connection_config.dart';

/// Guarda y recupera la conexión emparejada y lo leído por sesión.
abstract class SettingsStore {
  Future<ConnectionConfig?> load();
  Future<void> save(ConnectionConfig config);
  Future<void> clear();

  /// Último seq visto en el móvil por sessionId.
  Future<Map<String, int>> loadSeen();
  Future<void> saveSeen(Map<String, int> seen);
}

class PrefsSettingsStore implements SettingsStore {
  static const _kHost = 'host';
  static const _kPort = 'port';
  static const _kToken = 'token';
  static const _kSeen = 'seen';

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
  Future<ConnectionConfig?> load() async {
    final p = await SharedPreferences.getInstance();
    final host = p.getString(_kHost);
    final token = p.getString(_kToken);
    if (host == null || host.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return ConnectionConfig(
      host: host,
      port: p.getInt(_kPort) ?? ConnectionConfig.defaultPort,
      token: token,
    );
  }

  @override
  Future<void> save(ConnectionConfig c) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kHost, c.host);
    await p.setInt(_kPort, c.port);
    await p.setString(_kToken, c.token);
  }

  @override
  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kHost);
    await p.remove(_kPort);
    await p.remove(_kToken);
  }
}

/// Almacén en memoria (tests).
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.value]);
  ConnectionConfig? value;
  Map<String, int> seen = {};

  @override
  Future<Map<String, int>> loadSeen() async => Map.of(seen);

  @override
  Future<void> saveSeen(Map<String, int> s) async => seen = Map.of(s);

  @override
  Future<ConnectionConfig?> load() async => value;

  @override
  Future<void> save(ConnectionConfig config) async => value = config;

  @override
  Future<void> clear() async => value = null;
}
