import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:therd_protocol/protocol.dart';

import '../data/therd_controller.dart';
import 'context_ring.dart';
import 'theme.dart';

/// Número con puntos de miles: 423000 pasa a «423.000».
String formatTokens(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

/// Hoja del rosco de contexto: el dato en claro y las acciones para liberarlo.
/// [onSend] manda el texto a la sesión como si se escribiera en el composer.
Future<void> showContextSheet(
  BuildContext context, {
  required String sessionId,
  required void Function(String text) onSend,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (_) => ContextSheet(sessionId: sessionId, onSend: onSend),
);

class ContextSheet extends ConsumerWidget {
  const ContextSheet({
    super.key,
    required this.sessionId,
    required this.onSend,
  });

  final String sessionId;
  final void Function(String text) onSend;

  Future<void> _clear(BuildContext context) async {
    final c = context.tc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tk.radiusSheet),
        ),
        title: const Text('Empezar de cero'),
        content: Text(
          'Se borra la conversación de Claude y empieza una nueva en el mismo '
          'terminal. El historial de esta se puede retomar luego con /resume.',
          style: TextStyle(color: c.muted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: c.waitFg),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    Navigator.pop(context);
    onSend('/clear');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.tc;
    final session = ref.watch(
      therdProvider.select((s) => s.session(sessionId)),
    );
    final link = ref.watch(therdProvider.select((s) => s.link));
    final working = session?.status == SessionStatus.working;
    final tokens = session?.contextTokens;
    final window = session?.contextWindow;
    final used = session?.contextUsed;
    final enabled = link.isConnected && !working;
    final why = !link.isConnected
        ? 'Sin conexión.'
        : working
        ? 'Claude está trabajando: espera a que termine para usarlo.'
        : null;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Row(
              children: [
                if (used != null) ...[
                  ContextRing(used: used, size: 44),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Contexto usado',
                        style: TextStyle(fontSize: 13, color: c.muted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tokens != null && window != null
                            ? '${formatTokens(tokens)} de '
                                  '${formatTokens(window)} tokens'
                            : 'Sin datos todavía',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            enabled: enabled,
            leading: const Icon(Icons.compress),
            title: const Text('Compactar'),
            subtitle: const Text(
              'Resume la conversación para liberar contexto',
            ),
            onTap: () {
              Navigator.pop(context);
              onSend('/compact');
            },
          ),
          ListTile(
            enabled: enabled,
            leading: Icon(Icons.restart_alt, color: enabled ? c.waitFg : null),
            title: Text(
              'Empezar de cero',
              style: enabled ? TextStyle(color: c.waitFg) : null,
            ),
            subtitle: const Text(
              'Borra la conversación y deja el contexto vacío',
            ),
            onTap: () => _clear(context),
          ),
          if (why != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Text(why, style: TextStyle(fontSize: 13, color: c.muted)),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
