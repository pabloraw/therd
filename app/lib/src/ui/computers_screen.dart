import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/computer.dart';
import '../data/therd_controller.dart';
import 'connection_screen.dart';
import 'theme.dart';

/// Ordenadores emparejados: cuál está en uso, cambiar, editar y añadir.
class ComputersScreen extends ConsumerWidget {
  const ComputersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.tc;
    final computers = ref.watch(therdProvider.select((s) => s.computers));
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: IconButton(
                    tooltip: 'Volver',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Ordenadores',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.56,
                    height: 1.2,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final pc in computers.list)
                    ComputerTile(
                      computer: pc,
                      active: pc.id == computers.activeId,
                      onTap: () {
                        ref.read(therdProvider.notifier).switchTo(pc.id);
                        Navigator.of(context).maybePop();
                      },
                      trailing: IconButton(
                        tooltip: 'Editar ${pc.displayName}',
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ConnectionScreen(computerId: pc.id),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConnectionScreen()),
                ),
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Añadir ordenador'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fila de un ordenador: marca si está en uso, nombre y dirección.
class ComputerTile extends StatelessWidget {
  const ComputerTile({
    super.key,
    required this.computer,
    required this.active,
    required this.onTap,
    this.trailing,
  });

  final Computer computer;
  final bool active;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Semantics(
      selected: active,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 8, trailing == null ? 20 : 8, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: active
                      ? Icon(Icons.check, size: 20, color: c.okFg)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        computer.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: c.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        computer.config.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(size: 13, color: c.muted),
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hoja para cambiar de ordenador desde la cabecera de sesiones.
Future<void> showComputerSwitcher(BuildContext context, WidgetRef ref) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final computers = ref.read(therdProvider).computers;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final pc in computers.list)
                ComputerTile(
                  computer: pc,
                  active: pc.id == computers.activeId,
                  onTap: () {
                    ref.read(therdProvider.notifier).switchTo(pc.id);
                    Navigator.of(sheet).pop();
                  },
                ),
              const Divider(height: 1),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: const SizedBox(width: 24, child: Icon(Icons.computer_outlined)),
                title: const Text('Gestionar ordenadores'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ComputersScreen()),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
