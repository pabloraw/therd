import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:therd_protocol/protocol.dart';

import '../data/app_state.dart';
import '../data/therd_client.dart';
import '../data/therd_controller.dart';
import 'chat_screen.dart';
import 'connection_chip.dart';
import 'connection_screen.dart';
import 'context_ring.dart';
import 'session_actions.dart';
import 'theme.dart';

/// Último tramo de una ruta, para nombrar sesiones sin título.
String baseName(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Título visible de una sesión.
String sessionTitle(SessionInfo s) =>
    s.title.trim().isNotEmpty ? s.title : baseName(s.cwd);

/// Nodo del árbol de la barra: un workspace de herdr (checkout principal o
/// worktree) con sus sesiones y, si es principal, sus worktrees anidados.
/// [workspace] null agrupa las sesiones que no están en ningún workspace.
class WorkspaceNode {
  WorkspaceNode(this.workspace);
  final WorkspaceInfo? workspace;
  final sessions = <SessionInfo>[];
  final children = <WorkspaceNode>[];

  bool get hasSessions =>
      sessions.isNotEmpty || children.any((c) => c.hasSessions);

  Iterable<SessionInfo> get allSessions sync* {
    yield* sessions;
    for (final c in children) {
      yield* c.allSessions;
    }
  }
}

/// Árbol como la barra de herdr: workspaces en su orden, worktrees bajo su
/// checkout principal y solo los que tienen alguna sesión de Claude.
List<WorkspaceNode> buildTree(
  List<WorkspaceInfo> workspaces,
  List<SessionInfo> sessions,
) {
  final nodes = {for (final w in workspaces) w.workspaceId: WorkspaceNode(w)};
  final loose = WorkspaceNode(null);
  for (final s in sessions) {
    (nodes[s.workspaceId] ?? loose).sessions.add(s);
  }
  final roots = <WorkspaceNode>[];
  final sorted = [...workspaces]..sort((a, b) => a.number.compareTo(b.number));
  for (final w in sorted) {
    final node = nodes[w.workspaceId]!;
    final parent = w.isLinkedWorktree ? nodes[w.parentWorkspaceId] : null;
    (parent?.children ?? roots).add(node);
  }
  for (final r in roots) {
    r.children.removeWhere((c) => !c.hasSessions);
  }
  return [
    for (final r in roots)
      if (r.hasSessions) r,
    if (loose.sessions.isNotEmpty) loose,
  ];
}

enum SessionFilter { all, waiting, unread }

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  SessionFilter _filter = SessionFilter.all;

  /// Sesión pedida desde el móvil que ya corre: en cuanto aparece en la lista
  /// se abre su chat.
  void _onOpening(AppState s) {
    for (final e in s.opening.entries) {
      final pane = e.value;
      if (pane == null) continue;
      final session = successorInPane(s.sessions, pane);
      if (session == null) continue;
      final ctl = ref.read(therdProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ctl.finishOpening(e.key);
        final nav = Navigator.of(context);
        nav.popUntil((r) => r.isFirst);
        nav.push(chatRoute(session.sessionId));
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(therdProvider);
    final link = state.link;
    ref.listen(therdProvider, (_, next) => _onOpening(next));
    // Los errores de abrir o cerrar llegan aquí; con un chat encima, los
    // pinta él.
    ref.listen(therdProvider.select((s) => s.notice), (prev, next) {
      if (next == null || next.id == prev?.id) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(next.message)));
    });

    final views = {
      for (final s in state.sessions) s.sessionId: sessionView(state, s),
    };
    final waiting = views.values.where((v) => v == ViewStatus.blocked).length;
    final unread = views.values.where((v) => v == ViewStatus.unread).length;
    ViewStatus? top;
    for (final v in views.values) {
      if (top == null || viewPriority(v) > viewPriority(top)) top = v;
    }

    final shown = switch (_filter) {
      SessionFilter.all => state.sessions,
      SessionFilter.waiting => [
        for (final s in state.sessions)
          if (views[s.sessionId] == ViewStatus.blocked) s,
      ],
      SessionFilter.unread => [
        for (final s in state.sessions)
          if (views[s.sessionId] == ViewStatus.unread) s,
      ],
    };
    final tree = buildTree(state.workspaces, shown);
    final empty = state.sessions.isEmpty;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(link: link, summary: top),
            ConnectionBanner(status: link),
            VersionBanner(
              daemonOutdated: state.daemonOutdated,
              appOutdated: state.appOutdated,
            ),
            if (state.opening.isNotEmpty) const _OpeningBanner(),
            Expanded(
              child: empty
                  ? _Empty(connected: link.isConnected)
                  : shown.isEmpty
                  ? _NoMatch(filter: _filter)
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        for (final n in tree) ...[
                          SectionHeader(node: n),
                          for (final s in orderedTabs(n.sessions))
                            SessionRow(
                              session: s.session,
                              paneSuffix: s.paneSuffix,
                              state: state,
                              fallbackBranch: n.workspace?.branch,
                            ),
                          for (final child in n.children)
                            for (final s in orderedTabs(child.sessions))
                              SessionRow(
                                session: s.session,
                                paneSuffix: s.paneSuffix,
                                state: state,
                                indent: 30,
                                fallbackBranch: child.workspace?.branch,
                              ),
                        ],
                      ],
                    ),
            ),
            if (!empty)
              _FilterBar(
                filter: _filter,
                waiting: waiting,
                unread: unread,
                onChanged: (f) => setState(() => _filter = f),
              ),
          ],
        ),
      ),
    );
  }
}

/// Cabecera propia: logo con punto resumen, título, estado de conexión y
/// ajustes.
class _Header extends StatelessWidget {
  const _Header({required this.link, required this.summary});
  final LinkStatus link;
  final ViewStatus? summary;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Positioned.fill(child: TherdLogo(size: 40)),
                if (summary != null)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Semantics(
                      label: viewLabel(summary!),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: c.bg,
                          shape: BoxShape.circle,
                        ),
                        child: StatusDot(summary!, size: 10),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sesiones',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: c.text,
                  ),
                ),
                ConnectionChip(status: link),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Conexión',
            icon: const Icon(Icons.tune, size: 20),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
          ),
        ],
      ),
    );
  }
}

/// Barra inferior de filtros, fija sobre `surface`.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.waiting,
    required this.unread,
    required this.onChanged,
  });
  final SessionFilter filter;
  final int waiting;
  final int unread;
  final ValueChanged<SessionFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + bottom),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          _Seg(
            label: 'Todas',
            on: filter == SessionFilter.all,
            onTap: () => onChanged(SessionFilter.all),
          ),
          const SizedBox(width: 4),
          _Seg(
            label: 'Te esperan $waiting',
            dot: ViewStatus.blocked,
            on: filter == SessionFilter.waiting,
            onTap: () => onChanged(SessionFilter.waiting),
          ),
          const SizedBox(width: 4),
          _Seg(
            label: 'Sin leer $unread',
            dot: ViewStatus.unread,
            on: filter == SessionFilter.unread,
            onTap: () => onChanged(SessionFilter.unread),
          ),
        ],
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  const _Seg({
    required this.label,
    required this.on,
    required this.onTap,
    this.dot,
  });
  final String label;
  final bool on;
  final VoidCallback onTap;
  final ViewStatus? dot;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Expanded(
      child: Semantics(
        button: true,
        selected: on,
        child: Material(
          color: on ? c.cont : Colors.transparent,
          borderRadius: Tk.br,
          child: InkWell(
            borderRadius: Tk.br,
            onTap: onTap,
            child: SizedBox(
              height: Tk.control,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (dot != null) ...[
                    StatusDot(dot!, size: 9),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: on ? c.text : c.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Franja mientras herdr arranca una sesión pedida desde el móvil.
class _OpeningBanner extends StatelessWidget {
  const _OpeningBanner();

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: c.workSoft, borderRadius: Tk.br),
      child: Row(
        children: [
          Spinner(size: 14, stroke: 2, color: c.workFg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Abriendo sesión en el PC…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: c.workFg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.filter});
  final SessionFilter filter;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        filter == SessionFilter.waiting
            ? 'Ninguna sesión te espera.'
            : 'No hay sesiones sin leer.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, color: context.tc.muted),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final title = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      height: 1.35,
      letterSpacing: -0.22,
      color: c.text,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: connected
            ? [
                const TherdLogo(size: 48),
                const SizedBox(height: 12),
                Text('No hay sesiones de Claude Code en herdr.', style: title),
                const SizedBox(height: 12),
                Text(
                  'Abre una en tu PC y aparecerá aquí.',
                  style: TextStyle(fontSize: 15, color: c.muted),
                ),
              ]
            : [
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: 'Esperando la conexión con el daemon ',
                      ),
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Spinner(size: 18, stroke: 2.2, color: c.muted),
                      ),
                    ],
                  ),
                  style: title,
                ),
              ],
      ),
    );
  }
}

ViewStatus sessionView(AppState state, SessionInfo s) => viewStatus(
  s.status,
  unread: state.isUnread(s),
  hasPending: state.pendingOf(s.sessionId).isNotEmpty,
);

void _open(BuildContext context, SessionInfo s) =>
    Navigator.of(context).push(chatRoute(s.sessionId));

/// Tab ordenada como en herdr; [paneSuffix] distingue varios Claude en una
/// misma tab.
typedef TabEntry = ({SessionInfo session, String? paneSuffix});

List<TabEntry> orderedTabs(List<SessionInfo> sessions) {
  final sorted = [...sessions]
    ..sort((a, b) {
      final c = (a.tabNumber ?? 1 << 30).compareTo(b.tabNumber ?? 1 << 30);
      return c != 0 ? c : (a.paneId ?? '').compareTo(b.paneId ?? '');
    });
  final perTab = <String, int>{};
  final out = <TabEntry>[];
  for (final s in sorted) {
    final tab = s.tabId;
    final n = tab == null ? 1 : (perTab[tab] = (perTab[tab] ?? 0) + 1);
    out.add((session: s, paneSuffix: n > 1 ? '(pane $n)' : null));
  }
  return out;
}

/// Cabecera de un workspace: solo el nombre, 13 px, `muted`. Sin rama ni punto.
/// Con pulsación larga, nueva sesión o worktree en ese repo.
class SectionHeader extends ConsumerWidget {
  const SectionHeader({super.key, required this.node});

  final WorkspaceNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = node.workspace;
    final label = ws == null ? 'Fuera de herdr' : workspaceLabel(ws);
    final text = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.tc.muted,
        ),
      ),
    );
    if (ws == null) return text;
    return InkWell(
      onLongPress: () => showRepoActions(context, ref, ws),
      child: text,
    );
  }
}

/// Una tab (sesión de Claude). Todas del mismo tamaño, estén en el checkout
/// principal o en un worktree ([indent] > 0, con línea vertical de árbol).
class SessionRow extends ConsumerWidget {
  const SessionRow({
    super.key,
    required this.session,
    required this.state,
    this.paneSuffix,
    this.indent = 0,
    this.fallbackBranch,
  });

  final SessionInfo session;
  final AppState state;
  final String? paneSuffix;
  final double indent;

  /// Rama del workspace si la sesión no trae la suya.
  final String? fallbackBranch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.tc;
    final view = sessionView(state, session);
    final title = paneSuffix == null
        ? sessionTitle(session)
        : '${sessionTitle(session)} $paneSuffix';
    final b = session.branch;
    final branch = (b != null && b.isNotEmpty) ? b : fallbackBranch;
    final row = Material(
      color: Colors.transparent,
      borderRadius: Tk.br,
      child: InkWell(
        borderRadius: Tk.br,
        onTap: () => _open(context, session),
        onLongPress: () => showSessionActions(context, ref, session, title),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 54),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Semantics(label: viewLabel(view), child: StatusDot(view)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          color: c.text,
                        ),
                      ),
                      if (branch != null && branch.isNotEmpty)
                        Row(
                          children: [
                            Icon(Icons.call_split, size: 12, color: c.muted),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                branch,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: mono(color: c.muted),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                if (session.contextUsed case final used?) ...[
                  const SizedBox(width: 12),
                  ContextRing(used: used, size: 18, showLabel: false),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: indent == 0
          ? row
          : Stack(
              children: [
                Positioned(
                  left: indent - 12,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 1, color: c.line),
                ),
                Padding(
                  padding: EdgeInsets.only(left: indent),
                  child: row,
                ),
              ],
            ),
    );
  }
}
