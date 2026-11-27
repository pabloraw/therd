import 'dart:async';
import 'dart:io';

import 'package:therd_protocol/protocol.dart';

import 'app_server.dart';
import 'config.dart';
import 'herdr_client.dart';
import 'hook_router.dart';
import 'hook_server.dart';
import 'images.dart';
import 'log.dart';
import 'notifier.dart';
import 'pending.dart';
import 'push_registry.dart';
import 'seen_sync.dart';
import 'session_store.dart';
import 'transcript_tailer.dart';
import 'uploads.dart';

/// Une todas las piezas: hooks, transcripts, herdr, store y WebSocket.
class Daemon {
  Daemon({
    required this.paths,
    required this.config,
    required this.appHost,
    this.lanHosts = const [],
    this.hookHost = '127.0.0.1',
    this.refreshInterval = const Duration(seconds: 10),
  });

  final TherdPaths paths;
  final TherdConfig config;
  final String appHost;

  /// IPs de la red local donde el WebSocket escucha además de [appHost].
  final List<String> lanHosts;
  final String hookHost;
  final Duration refreshInterval;

  late final SessionStore store = SessionStore();
  late final TranscriptHub hub = TranscriptHub(store, images: images);
  late final PendingManager pendings = PendingManager(
    timeout: config.pendingTimeout,
  );
  late final HerdrClient herdr = HerdrClient(paths.herdrSocket);
  late final HookRouter router = HookRouter(
    store: store,
    hub: hub,
    pendings: pendings,
    projectsDir: paths.projectsDir,
    hasClients: () => appServer.clientCount > 0,
    terminal: herdr,
    onTurnEnd: (sid) => turns.onTurnEnd(sid),
  );
  late final HookServer hookServer = HookServer(
    token: config.token,
    handler: router,
    host: hookHost,
    port: config.hookPort,
  );
  late final AppServer appServer = AppServer(
    token: config.token,
    store: store,
    pendings: pendings,
    herdr: herdr,
    host: appHost,
    lanHosts: lanHosts,
    port: config.appPort,
    push: push,
    seen: seen,
    uploads: uploads,
    images: images,
  );

  late final ImageStore images = ImageStore(paths.imagesDir);

  late final Uploads uploads = Uploads(paths.uploadsDir);

  /// Lo leído en el móvil se marca también visto en el PC.
  late final SeenSync seen = SeenSync(store: store, io: herdr);

  /// Avisos push por ntfy cuando Claude espera y no hay app conectada.
  late final PendingNotifier notifier = PendingNotifier(
    events: pendings.events,
    client: config.ntfy == null ? null : NtfyClient(config.ntfy!),
    hasClients: () => appServer.clientCount > 0,
    sessionInfo: store.info,
    push: push,
  );

  /// Aviso de fin de turno si nadie ha visto la sesión.
  late final TurnNotifier turns = TurnNotifier(
    store: store,
    pendings: pendings,
    client: config.ntfy == null ? null : NtfyClient(config.ntfy!),
    hasClients: () => appServer.clientCount > 0,
    push: push,
  );

  /// Endpoints de UnifiedPush que registran las apps.
  late final PushRegistry push = PushRegistry(file: paths.pushFile);

  StreamSubscription<HerdrEvent>? _herdrSub;
  Timer? _refreshTimer;
  Set<String> _panes = {};
  final Set<String> _branchTried = {};
  bool _herdrWarned = false;
  bool _stopped = false;

  Future<void> start() async {
    // Antes de leer los transcripts: lo que se borre y siga haciendo falta
    // se vuelve a escribir al leerlos.
    await images.prune();
    hub.start();
    seen.start();
    notifier; // engancha la suscripción a los pendientes
    turns.start();
    await hookServer.start();
    await appServer.start();
    unawaited(uploads.prune());

    await refreshAgents();
    _herdrSub = herdr.events.listen(_onHerdrEvent);
    herdr.startEvents(() async => _panes.toList());
    _refreshTimer = Timer.periodic(refreshInterval, (_) => refreshAgents());
  }

  Future<void> stop() async {
    _stopped = true;
    _refreshTimer?.cancel();
    await _herdrSub?.cancel();
    await herdr.stop();
    await seen.dispose();
    await hub.stop();
    await appServer.stop();
    await hookServer.stop();
    router.dispose();
    await notifier.dispose();
    await turns.dispose();
    pendings.dispose();
    await store.dispose();
  }

  // ------------------------------------------------------------- herdr

  void _onHerdrEvent(HerdrEvent e) {
    switch (e.event) {
      case 'pane.agent_status_changed':
        final pane = e.paneId;
        final status = e.status;
        final sid = pane == null ? null : store.sessionIdForPane(pane);
        if (sid == null) {
          unawaited(refreshAgents());
        } else if (status != null) {
          store.setStatus(sid, status);
          _herdrStatus(sid, status);
        }
      case 'pane_focused' || 'pane.focused':
        store.setFocusedPane(e.paneId);
      case 'pane.created' || 'pane.closed' || 'connected':
        unawaited(refreshAgents());
    }
  }

  void _herdrStatus(String sid, SessionStatus status) {
    final before = store.herdrStatusOf(sid);
    store.setHerdrStatus(sid, status);
    if (before != status) seen.onHerdrStatus(sid, status);
    // Sin `before` es la primera vez que se ve la sesión (p. ej. al arrancar
    // el daemon): no es un fin de turno que se haya visto ocurrir.
    if (before != null && before != status && status == SessionStatus.done) {
      turns.onTurnEnd(sid);
    }
  }

  /// Sincroniza las sesiones con `agent.list` y reconstruye su histórico.
  ///
  /// Nunca lanza: una respuesta inesperada de herdr se registra y se sigue.
  /// Si ya hay un refresco en curso no se solapa; se repite al terminar.
  Future<void> refreshAgents() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        try {
          await _refreshAgentsOnce();
        } catch (e, st) {
          Log.error('refreshAgents falló', e, st);
        }
      } while (_refreshAgain && !_stopped);
    } finally {
      _refreshing = false;
    }
  }

  bool _refreshing = false;
  bool _refreshAgain = false;

  Future<void> _refreshAgentsOnce() async {
    if (_stopped) return;
    final List<HerdrAgent> agents;
    try {
      agents = await herdr.agentList();
      if (_herdrWarned) Log.info('herdr: conexión recuperada');
      _herdrWarned = false;
    } on HerdrException catch (e) {
      if (!_herdrWarned) {
        Log.warn('herdr no disponible: ${e.message}');
        _herdrWarned = true;
      }
      return;
    }

    // Nombre y orden de cada tab, como en herdr.
    final tabs = <String, Map<String, dynamic>>{};
    try {
      for (final t in await herdr.tabList()) {
        final id = t['tab_id'];
        if (id is String) tabs[id] = t;
      }
    } on HerdrException {
      // Sin tabs se ordena por llegada.
    }

    final live = <String>{};
    for (final a in agents) {
      if (!a.isClaude) continue;
      final sid = a.sessionId!;
      live.add(sid);
      store.upsertSession(
        sid,
        paneId: a.paneId,
        workspaceId: a.workspaceId,
        herdrTitle: a.title,
        cwd: a.cwd,
        status: a.status,
        fromHerdr: true,
        tabId: a.tabId,
        tabLabel: tabs[a.tabId]?['label'] as String?,
        tabNumber: (tabs[a.tabId]?['number'] as num?)?.toInt(),
      );
      _herdrStatus(sid, a.status);
      if (!hub.isAttached(sid)) {
        final path = findTranscript(paths.projectsDir, sid, [
          a.cwd,
          a.foregroundCwd,
        ]);
        if (path != null) hub.attach(sid, path);
      }
      if (store.info(sid)?.branch == null && _branchTried.add(sid)) {
        unawaited(_fillBranch(sid, a.foregroundCwd ?? a.cwd));
      }
    }
    // El pane que se ve en el PC cuenta como visto.
    store.setFocusedPane(
      agents.where((a) => a.focused).map((a) => a.paneId).firstOrNull,
    );
    for (final gone in store.pruneHerdrSessions(live)) {
      hub.detach(gone);
      pendings.cancelSession(gone);
    }

    try {
      await _refreshWorkspaces(agents);
    } catch (e, st) {
      Log.error('No se pudieron actualizar los workspaces', e, st);
    }

    final panes = {for (final a in agents) a.paneId};
    if (panes.length != _panes.length || !panes.containsAll(_panes)) {
      _panes = panes;
      herdr.resubscribe();
    }
  }

  /// Workspaces de herdr con su rama y el checkout principal del que cuelgan.
  Future<void> _refreshWorkspaces(List<HerdrAgent> agents) async {
    final List<Map<String, dynamic>> raw;
    try {
      raw = await herdr.workspaceList();
    } on HerdrException {
      return;
    }
    // repo_key del checkout principal → su workspace.
    final mainByRepo = <String, String>{};
    for (final w in raw) {
      final wt = w['worktree'];
      if (wt is Map && wt['is_linked_worktree'] != true) {
        final key = wt['repo_key'];
        if (key is String) mainByRepo[key] = w['workspace_id'] as String;
      }
    }
    final out = <WorkspaceInfo>[];
    for (final w in raw) {
      final id = w['workspace_id'] as String? ?? '';
      final wt = w['worktree'] is Map
          ? Map<String, dynamic>.from(w['worktree'] as Map)
          : null;
      final linked = wt?['is_linked_worktree'] == true;
      // Sin info de git en herdr: la rama sale del cwd de su agente.
      final checkout =
          wt?['checkout_path'] as String? ??
          agents
              .where((a) => a.workspaceId == id)
              .map((a) => a.foregroundCwd ?? a.cwd)
              .firstOrNull;
      out.add(
        WorkspaceInfo(
          workspaceId: id,
          number: (w['number'] as num?)?.toInt() ?? 0,
          label: w['label'] as String? ?? '',
          repoName: wt?['repo_name'] as String?,
          branch: checkout == null ? null : await _gitBranch(checkout),
          isLinkedWorktree: linked,
          parentWorkspaceId: linked ? mainByRepo[wt?['repo_key']] : null,
        ),
      );
    }
    out.sort((a, b) => a.number.compareTo(b.number));
    store.setWorkspaces(out);
  }

  Future<String?> _gitBranch(String dir) async {
    try {
      final r = await Process.run('git', [
        '-C',
        dir,
        'branch',
        '--show-current',
      ]);
      final b = '${r.stdout}'.trim();
      return r.exitCode == 0 && b.isNotEmpty ? b : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _fillBranch(String sid, String? cwd) async {
    if (cwd == null || cwd.isEmpty) return;
    try {
      final r = await Process.run('git', [
        '-C',
        cwd,
        'branch',
        '--show-current',
      ]);
      final b = '${r.stdout}'.trim();
      if (r.exitCode == 0 && b.isNotEmpty) {
        store.updateMeta(sid, branch: b);
      }
    } catch (_) {}
  }
}
