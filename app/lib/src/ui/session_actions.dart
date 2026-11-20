import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:therd_protocol/protocol.dart';

import '../data/therd_controller.dart';
import 'theme.dart';

/// Nombre de un workspace tal como se pinta en la lista.
String workspaceLabel(WorkspaceInfo ws) =>
    ws.label.isNotEmpty ? ws.label : (ws.repoName ?? ws.workspaceId);

/// Nombre de un destino en la hoja de «Nueva sesión»: el worktree por su rama.
String _targetLabel(WorkspaceInfo ws) {
  final b = ws.branch;
  if (ws.isLinkedWorktree && b != null && b.isNotEmpty) return b;
  return workspaceLabel(ws);
}

/// Worktrees abiertos en herdr que cuelgan de [main].
List<WorkspaceInfo> worktreesOf(List<WorkspaceInfo> all, WorkspaceInfo main) =>
    [
      for (final w in all)
        if (w.isLinkedWorktree && w.parentWorkspaceId == main.workspaceId) w,
    ];

WorkspaceInfo? _find(List<WorkspaceInfo> all, String? id) {
  if (id == null) return null;
  for (final w in all) {
    if (w.workspaceId == id) return w;
  }
  return null;
}

class _Action {
  const _Action(this.icon, this.label, this.run, {this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback run;
  final bool danger;
}

/// Hoja con una lista de acciones; ejecuta la elegida al cerrarse.
Future<void> _actionSheet(
  BuildContext context, {
  required String title,
  required List<_Action> actions,
}) async {
  final picked = await showModalBottomSheet<_Action>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final c = ctx.tc;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.muted,
                ),
              ),
            ),
            for (final a in actions)
              ListTile(
                leading: Icon(a.icon, color: a.danger ? c.waitFg : null),
                title: Text(
                  a.label,
                  style: a.danger ? TextStyle(color: c.waitFg) : null,
                ),
                onTap: () => Navigator.pop(ctx, a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  picked?.run();
}

/// Long tap en la cabecera de un repo: nueva sesión (eligiendo el checkout o
/// uno de sus worktrees) o worktree nuevo.
Future<void> showRepoActions(
  BuildContext context,
  WidgetRef ref,
  WorkspaceInfo main,
) {
  final all = ref.read(therdProvider).workspaces;
  final trees = worktreesOf(all, main);
  return _actionSheet(
    context,
    title: workspaceLabel(main),
    actions: [
      _Action(
        Icons.add_comment_outlined,
        'Nueva sesión',
        () => trees.isEmpty
            ? showNewSession(context, ref, main)
            : _pickTarget(context, ref, [main, ...trees]),
      ),
      if (main.repoName != null)
        _Action(
          Icons.call_split,
          'Nuevo worktree',
          () => showNewSession(context, ref, main, worktree: true),
        ),
    ],
  );
}

Future<void> _pickTarget(
  BuildContext context,
  WidgetRef ref,
  List<WorkspaceInfo> targets,
) => _actionSheet(
  context,
  title: 'Nueva sesión en',
  actions: [
    for (final t in targets)
      _Action(
        t.isLinkedWorktree ? Icons.call_split : Icons.folder_outlined,
        _targetLabel(t),
        () => showNewSession(context, ref, t),
      ),
  ],
);

/// Long tap en una sesión: otra sesión en su workspace, cerrarla o quitar
/// su worktree.
Future<void> showSessionActions(
  BuildContext context,
  WidgetRef ref,
  SessionInfo session,
  String title,
) {
  final ws = _find(ref.read(therdProvider).workspaces, session.workspaceId);
  final ctl = ref.read(therdProvider.notifier);
  return _actionSheet(
    context,
    title: title,
    actions: [
      if (ws != null)
        _Action(
          Icons.add_comment_outlined,
          'Nueva sesión aquí',
          () => showNewSession(context, ref, ws),
        ),
      if (session.paneId != null)
        _Action(Icons.close, 'Cerrar sesión', danger: true, () async {
          final ok = await _confirm(
            context,
            title: 'Cerrar sesión',
            body:
                'Se cierra el terminal de «$title» en el PC y Claude con él. '
                'La conversación se puede retomar luego con /resume.',
            action: 'Cerrar',
          );
          if (ok) ctl.closeRemoteSession(session.sessionId);
        }),
      if (ws != null && ws.isLinkedWorktree)
        _Action(
          Icons.delete_outline,
          'Quitar worktree',
          danger: true,
          () async {
            final ok = await _confirm(
              context,
              title: 'Quitar worktree',
              body:
                  'Se cierran las sesiones de «${_targetLabel(ws)}» y se borra '
                  'su checkout del disco. La rama se queda. Si hay cambios sin '
                  'commitear no se quita.',
              action: 'Quitar',
            );
            if (ok) ctl.removeWorktree(ws.workspaceId);
          },
        ),
    ],
  );
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final c = context.tc;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tk.radiusSheet),
      ),
      title: Text(title),
      content: Text(body, style: TextStyle(color: c.muted, height: 1.4)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: c.waitFg),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Formulario de sesión nueva en [ws]; con [worktree], en un worktree nuevo
/// de ese repo (pide la rama y desde dónde sale).
Future<void> showNewSession(
  BuildContext context,
  WidgetRef ref,
  WorkspaceInfo ws, {
  bool worktree = false,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => NewSessionSheet(workspace: ws, worktree: worktree),
);

class NewSessionSheet extends ConsumerStatefulWidget {
  const NewSessionSheet({
    super.key,
    required this.workspace,
    this.worktree = false,
  });

  final WorkspaceInfo workspace;
  final bool worktree;

  @override
  ConsumerState<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends ConsumerState<NewSessionSheet> {
  final _branch = TextEditingController();
  late final _base = TextEditingController(text: widget.workspace.branch);
  final _prompt = TextEditingController();
  String? _branchError;

  @override
  void dispose() {
    _branch.dispose();
    _base.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _submit() {
    final branch = _branch.text.trim();
    if (widget.worktree) {
      final err = branch.isEmpty
          ? 'Pon el nombre de la rama.'
          : branch.contains(RegExp(r'\s'))
          ? 'La rama no puede llevar espacios.'
          : null;
      if (err != null) {
        setState(() => _branchError = err);
        return;
      }
    }
    ref
        .read(therdProvider.notifier)
        .requestSession(
          widget.workspace.workspaceId,
          branch: widget.worktree ? branch : null,
          base: widget.worktree ? _base.text : null,
          prompt: _prompt.text,
        );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final title = widget.worktree
        ? 'Nuevo worktree en ${workspaceLabel(widget.workspace)}'
        : 'Nueva sesión en ${_targetLabel(widget.workspace)}';
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: c.text,
              ),
            ),
            const SizedBox(height: 16),
            if (widget.worktree) ...[
              TextField(
                controller: _branch,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                style: mono(color: c.text, size: 14),
                decoration: InputDecoration(
                  labelText: 'Rama nueva',
                  hintText: 'feat/algo',
                  errorText: _branchError,
                ),
                onChanged: (_) {
                  if (_branchError != null) {
                    setState(() => _branchError = null);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _base,
                autocorrect: false,
                enableSuggestions: false,
                style: mono(color: c.text, size: 14),
                decoration: const InputDecoration(
                  labelText: 'Desde',
                  hintText: 'rama actual',
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _prompt,
              autofocus: !widget.worktree,
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Primer mensaje (opcional)',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submit,
              child: Text(widget.worktree ? 'Crear y abrir' : 'Abrir sesión'),
            ),
          ],
        ),
      ),
    );
  }
}
