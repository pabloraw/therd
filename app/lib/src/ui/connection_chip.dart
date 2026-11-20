import 'package:flutter/material.dart';

import '../data/therd_client.dart';
import 'connection_screen.dart';
import 'theme.dart';

/// Línea de estado de conexión de la cabecera, 12 px: punto verde
/// «Conectado», spinner ámbar «Reconectando (intento N)», «Token rechazado»
/// en rojo.
class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key, required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final (Widget lead, Color color) = switch (status.state) {
      LinkState.connected => (
        Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: kDotDone,
          ),
        ),
        c.muted,
      ),
      LinkState.connecting || LinkState.reconnecting => (
        Spinner(size: 11, color: c.workFg, stroke: 1.8),
        c.workFg,
      ),
      LinkState.unauthorized => (const SizedBox.shrink(), c.waitFg),
      LinkState.disconnected => (
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: kDotUnknown, width: 1.5),
          ),
        ),
        c.muted,
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status.state != LinkState.unauthorized) ...[
          lead,
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            status.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: color, height: 1.3),
          ),
        ),
      ],
    );
  }
}

/// Franja persistente cuando las versiones de protocolo de la app y el daemon
/// no casan. No bloquea: solo avisa de que parte de la app puede no funcionar.
class VersionBanner extends StatelessWidget {
  const VersionBanner({
    super.key,
    required this.daemonOutdated,
    required this.appOutdated,
  });

  final bool daemonOutdated;
  final bool appOutdated;

  @override
  Widget build(BuildContext context) {
    if (!daemonOutdated && !appOutdated) return const SizedBox.shrink();
    final c = context.tc;
    final text = appOutdated
        ? 'La app es de una versión anterior al daemon: actualízala.'
        : 'El daemon del PC es de una versión anterior: actualízalo para usar todo.';
    return Semantics(
      liveRegion: true,
      child: Material(
        color: c.waitSoft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline, size: 16, color: c.waitFg),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(fontSize: 13, height: 1.45, color: c.waitFg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Franja a sangre bajo la cabecera cuando no hay conexión, 13 px.
/// Reconectando: ámbar tenue con spinner. Token rechazado: rojo tenue con
/// candado, tocable para abrir Conexión.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    if (status.isConnected) return const SizedBox.shrink();
    final c = context.tc;
    final bad = status.state == LinkState.unauthorized;
    final fg = bad ? c.waitFg : c.workFg;
    final style = TextStyle(fontSize: 13, height: 1.45, color: fg);

    if (bad) {
      return Semantics(
        liveRegion: true,
        child: Material(
          color: c.waitSoft,
          child: InkWell(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Tk.control),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: fg),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Token rechazado. Toca para volver a emparejar.',
                        style: style,
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 18, color: fg),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final error = status.error;
    final text = error == null || error.isEmpty
        ? status.label
        : '${status.label}. $error';
    return Semantics(
      liveRegion: true,
      child: Material(
        color: c.workSoft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Spinner(size: 16, color: fg, stroke: 2.2),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: style)),
            ],
          ),
        ),
      ),
    );
  }
}
