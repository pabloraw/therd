import 'package:flutter/foundation.dart';

import 'connection_config.dart';

/// Un ordenador emparejado: su conexión y cómo se llama en la app.
@immutable
class Computer {
  const Computer({
    required this.id,
    required this.config,
    this.name,
    this.machine,
    this.daemonId,
  });

  /// Id local en el móvil (no cambia aunque cambie la conexión).
  final String id;
  final ConnectionConfig config;

  /// Nombre que le pone el usuario («Trabajo», «Personal»); null = sin poner.
  final String? name;

  /// Hostname que anuncia el daemon en el hello.
  final String? machine;

  /// Id del daemon según su hello; con él se reconoce de quién es un aviso.
  final String? daemonId;

  String get displayName {
    final n = name?.trim() ?? '';
    if (n.isNotEmpty) return n;
    final m = machine?.trim() ?? '';
    return m.isNotEmpty ? m : config.host;
  }

  Computer copyWith({
    ConnectionConfig? config,
    String? name,
    bool clearName = false,
    String? machine,
    String? daemonId,
  }) => Computer(
    id: id,
    config: config ?? this.config,
    name: clearName ? null : (name ?? this.name),
    machine: machine ?? this.machine,
    daemonId: daemonId ?? this.daemonId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'host': config.host,
    'port': config.port,
    'token': config.token,
    if (config.lanHosts.isNotEmpty) 'lanHosts': config.lanHosts,
    if (name != null) 'name': name,
    if (machine != null) 'machine': machine,
    if (daemonId != null) 'daemonId': daemonId,
  };

  static Computer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final host = raw['host'];
    final token = raw['token'];
    if (id is! String || host is! String || token is! String) return null;
    if (host.isEmpty || token.isEmpty) return null;
    return Computer(
      id: id,
      config: ConnectionConfig(
        host: host,
        port: (raw['port'] as num?)?.toInt() ?? ConnectionConfig.defaultPort,
        token: token,
        lanHosts: [
          if (raw['lanHosts'] case final List<dynamic> l)
            for (final h in l)
              if (h is String && h.isNotEmpty) h,
        ],
      ),
      name: raw['name'] as String?,
      machine: raw['machine'] as String?,
      daemonId: raw['daemonId'] as String?,
    );
  }

  /// Id local nuevo, único en la práctica dentro del móvil.
  static String newId() =>
      'pc${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  @override
  bool operator ==(Object other) =>
      other is Computer &&
      other.id == id &&
      other.config == config &&
      other.name == name &&
      other.machine == machine &&
      other.daemonId == daemonId;

  @override
  int get hashCode => Object.hash(id, config, name, machine, daemonId);
}

/// Los ordenadores guardados y cuál está en uso.
@immutable
class SavedComputers {
  const SavedComputers([this.list = const [], this.activeId]);

  final List<Computer> list;
  final String? activeId;

  Computer? get active => byId(activeId);

  Computer? byId(String? id) {
    if (id == null) return null;
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }

  Computer? byDaemon(String? daemonId) {
    if (daemonId == null) return null;
    for (final c in list) {
      if (c.daemonId == daemonId) return c;
    }
    return null;
  }

  /// El del aviso si se reconoce; si no (daemon antiguo), el que está en uso.
  Computer? forDaemon(String? daemonId) => byDaemon(daemonId) ?? active;
}
