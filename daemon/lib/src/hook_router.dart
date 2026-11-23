import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:therd_protocol/protocol.dart';

import 'herdr_client.dart';
import 'hook_event.dart';
import 'hook_server.dart';
import 'log.dart';
import 'pending.dart';
import 'session_store.dart';
import 'terminal_dialogs.dart';
import 'transcript_parser.dart';
import 'transcript_tailer.dart';
import 'uploads.dart';

/// Traduce los hooks de Claude Code a operaciones sobre el store y a
/// pendientes retenidos.
class HookRouter implements HookHandler {
  HookRouter({
    required this.store,
    required this.hub,
    required this.pendings,
    required this.projectsDir,
    String? plansDir,
    required bool Function() hasClients,
    this.terminal,
    this.terminalPoll = const Duration(seconds: 1),
    this.keyPause = const Duration(milliseconds: 150),
    this.confirmAttempts = 8,
    this.planFallbackDelay = const Duration(seconds: 2),
    this.hookAnswerGrace = const Duration(seconds: 2),
    this.onTurnEnd,
  }) : plansDir = plansDir ?? p.join(p.dirname(projectsDir), 'plans'),
       _hasClients = hasClients {
    _sub = pendings.events.listen(_onPendingEvent);
  }

  /// Terminal de las sesiones, para vigilar y contestar los diálogos que no
  /// se retienen (sin app conectada) o que se liberan.
  final TerminalIo? terminal;

  /// Cadencia con la que se mira el terminal mientras se espera o hay abierto
  /// un pendiente de terminal.
  final Duration terminalPoll;

  /// Pausa entre teclas cuando hay que dejar que Claude Code repinte.
  final Duration keyPause;

  /// Veces que se mira la pantalla hasta ver el diálogo antes de rendirse.
  final int confirmAttempts;

  /// Lo que se espera al `PermissionRequest` de un plan antes de abrirlo
  /// desde su `PreToolUse` (ver [_planFallback]).
  final Duration planFallbackDelay;

  /// Lo que se deja a Claude Code para aplicar la respuesta de un hook
  /// retenido antes de mirar si su diálogo sigue abierto (ver
  /// [_checkHookAnswer]).
  final Duration hookAnswerGrace;

  /// Llamado con el hook `Stop` (fin de turno), antes de cancelar pendientes.
  final void Function(String sessionId)? onTurnEnd;

  /// Sesiones con un diálogo de terminal vigilado ahora mismo.
  final Set<String> _watching = {};

  /// requestId de los pendientes respaldados por el terminal.
  final Set<String> _terminalBacked = {};

  final SessionStore store;
  final TranscriptHub hub;
  final PendingManager pendings;
  final String projectsDir;

  /// Donde Claude Code escribe los planes (`~/.claude/plans`).
  final String plansDir;
  final bool Function() _hasClients;
  late final StreamSubscription<PendingEvent> _sub;

  /// requestId a id del item que lo representa en el chat.
  final Map<String, String> _itemIds = {};

  @override
  bool get hasClients => _hasClients();

  void dispose() {
    _sub.cancel();
  }

  // -------------------------------------------------------------- común

  void _ensureSession(HookEvent e) {
    final cur = store.info(e.sessionId);
    store.upsertSession(
      e.sessionId,
      paneId: cur?.paneId == null ? e.paneId : null,
      cwd: (cur == null || cur.cwd.isEmpty) ? e.cwd : null,
      mode: e.permissionMode,
      model: e.raw['model'] as String?,
    );
    if (e.isSubagent) return;
    var path = e.transcriptPath;
    path ??= store.transcriptPathOf(e.sessionId);
    path ??= findTranscript(projectsDir, e.sessionId, [e.cwd]);
    if (path != null && path.isNotEmpty) hub.attach(e.sessionId, path);
  }

  // ------------------------------------------------------------- espejo

  @override
  void onEvent(HookEvent e) {
    unawaited(
      _process(e).catchError((Object err, StackTrace st) {
        Log.error('hook ${e.name}', err, st);
      }),
    );
  }

  Future<void> _process(HookEvent e) async {
    if (e.sessionId.isEmpty) return;
    _ensureSession(e);
    // Un evento retenible que llega aquí no se retuvo (no hay app): el
    // diálogo va a salir en el terminal.
    if (e.isHoldable && terminal != null) {
      unawaited(
        _surfaceFromHook(e).catchError((Object err, StackTrace st) {
          Log.error('pendiente de terminal', err, st);
        }),
      );
    }
    if (e.name == 'PreToolUse' &&
        e.toolName == 'ExitPlanMode' &&
        !e.isSubagent &&
        terminal != null) {
      unawaited(
        _planFallback(e).catchError((Object err, StackTrace st) {
          Log.error('plan sin PermissionRequest', err, st);
        }),
      );
    }
    if (e.isSubagent) {
      // Sus herramientas no son items del chat: salen en la tarjeta del Task
      // que lo lanzó, leídas de su transcript. El hook solo adelanta el sondeo.
      unawaited(hub.pollNow(e.sessionId));
      return;
    }
    final sid = e.sessionId;

    switch (e.name) {
      case 'SessionStart':
        final title = e.raw['session_title'];
        if (title is String && title.isNotEmpty) {
          store.updateMeta(sid, title: title);
        }
      case 'UserPromptSubmit':
        pendings.cancelSession(sid);
        store.setStatus(sid, SessionStatus.working);
        await hub.pollNow(sid);
        final prompt = (e.raw['prompt'] as String? ?? '').trim();
        if (prompt.isNotEmpty) _addHookPrompt(sid, prompt);
      case 'PreToolUse':
        store.setStatus(sid, SessionStatus.working);
        final name = e.toolName ?? '';
        final id = e.toolUseId;
        if (id != null && name != 'AskUserQuestion' && name != 'ExitPlanMode') {
          await hub.pollNow(sid);
          store.ingest(
            sid,
            ToolCallItem(
              id: id,
              sessionId: sid,
              seq: 0,
              timestamp: DateTime.now().toUtc(),
              toolName: name,
              input: trimInput(e.toolInput),
            ),
          );
        }
      case 'PostToolUse':
        final id = e.toolUseId;
        if (id != null) {
          store.completeTool(
            sid,
            id,
            isError: false,
            result: responseText(e.raw['tool_response']),
            durationMs: (e.raw['duration_ms'] as num?)?.toInt(),
          );
        }
      case 'PostToolUseFailure':
        final id = e.toolUseId;
        if (id != null) {
          store.completeTool(
            sid,
            id,
            isError: true,
            result: responseText(e.raw['error']),
            durationMs: (e.raw['duration_ms'] as num?)?.toInt(),
          );
        }
      case 'Notification':
        final t = e.raw['notification_type'];
        if (t == 'permission_prompt') {
          store.setStatus(sid, SessionStatus.blocked);
        } else if (t == 'idle_prompt') {
          store.setStatus(sid, SessionStatus.idle);
        }
      case 'Stop':
        onTurnEnd?.call(sid);
        pendings.cancelSession(sid);
        store.setStatus(sid, SessionStatus.idle);
      case 'StopFailure':
        pendings.cancelSession(sid);
        store.setStatus(sid, SessionStatus.idle);
        final err = e.raw['error'];
        store.ingest(
          sid,
          MarkerItem(
            id: 'hook:error:${DateTime.now().microsecondsSinceEpoch}',
            sessionId: sid,
            seq: 0,
            timestamp: DateTime.now().toUtc(),
            kind: MarkerKind.error,
            text: err is String && err.isNotEmpty
                ? truncate(err, 500)
                : 'Error de la API',
          ),
        );
      case 'SessionEnd':
        pendings.cancelSession(sid);
        hub.detach(sid);
        store.removeSession(sid);
        return;
    }
    unawaited(hub.pollNow(sid));
  }

  void _addHookPrompt(String sid, String raw) {
    // Las rutas de imágenes enviadas desde la app no se pintan: la imagen
    // llega luego con el transcript.
    final text = cleanPromptText(raw);
    if (text.isEmpty || isSyntheticPrompt(text)) return;
    final now = DateTime.now().toUtc();
    // Si el transcript ya trajo este prompt, no se duplica.
    for (final it in store.itemsOf(sid).reversed.take(8)) {
      if (it is UserPromptItem &&
          it.text == text &&
          now.difference(it.timestamp).inSeconds.abs() < 5) {
        return;
      }
    }
    store.ingest(
      sid,
      UserPromptItem(
        id: 'hook:prompt:${now.microsecondsSinceEpoch}',
        sessionId: sid,
        seq: 0,
        timestamp: now,
        text: text,
      ),
    );
  }

  /// Texto del plan de un ExitPlanMode. Claude Code suele mandar `tool_input`
  /// vacío (inyecta el plan después), así que se lee del último archivo que la
  /// sesión escribió o editó en [plansDir].
  Future<String> _planText(String sid, Map<String, dynamic> input) async {
    final inline = input['plan'];
    if (inline is String && inline.trim().isNotEmpty) return inline;
    for (final it in store.itemsOf(sid).reversed) {
      if (it is! ToolCallItem) continue;
      final path = it.input['file_path'];
      if (path is! String || !p.isWithin(plansDir, path)) continue;
      try {
        return await File(path).readAsString();
      } on FileSystemException catch (err) {
        Log.warn('No se pudo leer el plan $path: ${err.message}');
      }
    }
    return '';
  }

  // ------------------------------------------- pendientes de terminal

  // Con el móvil bloqueado no hay app conectada: el hook vuelve 204 y Claude
  // Code pregunta en su terminal. Para poder contestar desde la app al volver,
  // se vigila la pantalla del pane; al ver el diálogo se abre un pendiente
  // «de terminal» con el mismo contenido que tendría el retenido. Se contesta
  // pulsando teclas (ver `terminal_dialogs.dart`) y se cierra si el diálogo
  // desaparece (se contestó en el PC).
  //
  // Este disparo sustituye al antiguo, que miraba el transcript buscando un
  // ExitPlanMode: Claude Code escribe el plan en el transcript solo después
  // de contestarlo, así que nunca llegaba a tiempo. El hook sí llega antes de
  // que salga el diálogo, y sirve igual para permisos y preguntas.

  static DialogKind _kindOfEvent(HookEvent e) {
    if (e.toolName == 'ExitPlanMode') return DialogKind.plan;
    if (e.name == 'PreToolUse') return DialogKind.question;
    return DialogKind.permission;
  }

  /// Plan sin `PermissionRequest`. El pendiente de un plan sale de ese hook,
  /// pero Claude Code a veces no lo manda (pasaba con otros hooks en
  /// `PreToolUse ExitPlanMode`). El `PreToolUse` sí llega siempre: se espera
  /// un poco al `PermissionRequest` y, si no ha abierto nada, se vigila el
  /// terminal como con cualquier pendiente de terminal. Si el plan llega por
  /// su hook, ya hay pendiente o vigilancia y esto no hace nada.
  Future<void> _planFallback(HookEvent e) async {
    await Future<void>.delayed(planFallbackDelay);
    final sid = e.sessionId;
    if (pendings.forSession(sid).isNotEmpty || _watching.contains(sid)) return;
    Log.info(
      'plan sin PermissionRequest en '
      '${sid.length > 8 ? sid.substring(0, 8) : sid}: vigilo el terminal',
    );
    await _surfaceFromHook(e);
  }

  static DialogKind _kindOfPending(Pending p) => switch (p.kind) {
    PendingKind.question => DialogKind.question,
    PendingKind.plan => DialogKind.plan,
    _ => DialogKind.permission,
  };

  /// Mira la pantalla hasta ver el diálogo. False si no sale (en modo auto,
  /// por ejemplo, el hook llega pero un clasificador decide sin preguntar).
  Future<bool> _confirmDialog(String pane, DialogKind kind, String sid) async {
    for (var i = 0; i < confirmAttempts; i++) {
      if (i > 0) await Future<void>.delayed(terminalPoll);
      // Si otro pendiente (la app) tomó el relevo, no hay nada que vigilar.
      if (pendings.forSession(sid).isNotEmpty) return false;
      try {
        if (dialogShown(kind, await terminal!.readVisible(pane))) return true;
      } on HerdrException catch (err) {
        Log.warn('No se pudo leer el terminal de $pane: ${err.message}');
        return false;
      }
    }
    return false;
  }

  /// Hook retenible que no se retuvo: se confirma el diálogo y se abre.
  Future<void> _surfaceFromHook(HookEvent e) async {
    final sid = e.sessionId;
    final pane = store.info(sid)?.paneId;
    if (pane == null || !_watching.add(sid)) return;
    try {
      final kind = _kindOfEvent(e);
      if (!await _confirmDialog(pane, kind, sid)) return;
      final (pending, item) = await _build(e, newRequestId());
      final stored = store.upsertPendingItem(sid, item);
      _itemIds[pending.requestId] = stored?.id ?? item.id;
      store.setStatus(sid, SessionStatus.blocked);
      Log.info(
        'pendiente de terminal ${kind.name} en '
        '${sid.length > 8 ? sid.substring(0, 8) : sid}',
      );
      await _runTerminalPending(pending, pane, kind);
    } finally {
      _watching.remove(sid);
    }
  }

  /// Un retenido se liberó o expiró: el diálogo sale en el terminal. Devuelve
  /// false si no se puede vigilar y entonces se cierra como siempre.
  bool _startReopen(Pending p0) {
    final sid = p0.sessionId;
    final pane = store.info(sid)?.paneId;
    if (pane == null || !_watching.add(sid)) return false;
    unawaited(() async {
      try {
        final kind = _kindOfPending(p0);
        if (!await _confirmDialog(pane, kind, sid)) {
          // No salió (ya se contestó o no hay diálogo): se cierra la tarjeta.
          _closeItem(p0, Resolution.released, null);
          return;
        }
        store.setStatus(sid, SessionStatus.blocked);
        await _runTerminalPending(p0, pane, kind);
      } catch (err, st) {
        Log.error('pendiente de terminal', err, st);
        _closeItem(p0, Resolution.released, null);
      } finally {
        _watching.remove(sid);
      }
    }());
    return true;
  }

  /// Abre [pending] respaldado por el terminal y lo contesta con teclas.
  Future<void> _runTerminalPending(
    Pending pending,
    String pane,
    DialogKind kind,
  ) async {
    final io = terminal!;
    final id = pending.requestId;
    _terminalBacked.add(id);
    final handle = pendings.open(
      pending,
      // El diálogo espera lo que haga falta; se cierra al desaparecer.
      expireAfter: const Duration(hours: 12),
      onTerminal: true,
    );

    // Si se contesta en el PC, el diálogo desaparece y se cancela. Dos
    // lecturas seguidas sin diálogo, para no cancelar por un repintado.
    unawaited(() async {
      var misses = 0;
      while (pendings.byId(id) != null) {
        await Future<void>.delayed(terminalPoll);
        if (pendings.byId(id) == null) break;
        try {
          final shown = dialogShown(kind, await io.readVisible(pane));
          misses = shown ? 0 : misses + 1;
        } on HerdrException {
          misses = 2;
        }
        if (misses >= 2) handle.cancel();
      }
    }());

    await _answerByKeys(pending, pane, kind, await handle.result);
  }

  /// Pulsa en el terminal la respuesta [r] de la app. Contestar en el PC,
  /// cancelado o expirado no pulsan nada.
  Future<void> _answerByKeys(
    Pending pending,
    String pane,
    DialogKind kind,
    PendingResult r,
  ) async {
    final io = terminal!;
    final body = r.body;
    try {
      switch (r.resolution) {
        case Resolution.allowed || Resolution.denied:
          final decision =
              (body?['hookSpecificOutput'] as Map?)?['decision'] as Map?;
          final allow = r.resolution == Resolution.allowed;
          final always = decision?.containsKey('updatedPermissions') ?? false;
          final message = decision?['message'] as String?;
          final ok = kind == DialogKind.plan
              ? await answerPlanDialog(
                  io,
                  pane,
                  allow: allow,
                  always: always,
                  message: message,
                  pause: keyPause,
                )
              : await answerPermissionDialog(
                  io,
                  pane,
                  allow: allow,
                  always: always,
                  message: message,
                  pause: keyPause,
                );
          if (!ok) Log.warn('El diálogo de $pane ya no estaba en pantalla');
        case Resolution.answered:
          final input = (body?['hookSpecificOutput'] as Map?)?['updatedInput'];
          final raw = (input as Map?)?['answers'];
          final answers = {
            for (final e in (raw as Map? ?? const {}).entries)
              '${e.key}': '${e.value}',
          };
          final ok = await answerQuestionDialog(
            io,
            pane,
            pending.questions,
            answers,
            pause: keyPause,
          );
          if (!ok) {
            Log.warn(
              'La pregunta de $pane no se pudo contestar por teclas '
              '(respuesta vacía o diálogo ya cerrado): '
              'queda en el terminal',
            );
          }
        default:
          // Contestar en el PC, cancelado o expirado: no se pulsa nada.
          break;
      }
    } on HerdrException catch (err) {
      Log.warn('No se pudo contestar en el terminal: ${err.message}');
    }
  }

  // ---------------------------------------------------------- retención

  @override
  Future<PendingHandle?> hold(HookEvent e) async {
    _ensureSession(e);
    final sid = e.sessionId;
    final (pending, item) = await _build(e, newRequestId());
    final stored = store.upsertPendingItem(sid, item);
    _itemIds[pending.requestId] = stored?.id ?? item.id;
    store.setStatus(sid, SessionStatus.blocked);
    final handle = pendings.open(pending);
    if (terminal != null && pending.kind != PendingKind.question) {
      unawaited(
        handle.result.then((r) => _checkHookAnswer(pending, r)).catchError((
          Object err,
          StackTrace st,
        ) {
          Log.error('comprobar la respuesta del hook', err, st);
        }),
      );
    }
    return handle;
  }

  /// Claude Code abre su diálogo en el terminal mientras espera al hook y,
  /// cuando el permiso exige a una persona, descarta el `allow` del hook y
  /// el diálogo sigue esperando (pasa en 2.1.330 con una regla `ask` de
  /// settings en modo auto: «Rule … overrides auto mode»). La app enseñaba
  /// «Permitido» y la sesión se quedaba parada. Así que, contestado el
  /// retenido, si el mismo diálogo sigue en pantalla se contesta con teclas.
  Future<void> _checkHookAnswer(Pending p0, PendingResult r) async {
    if (r.resolution != Resolution.allowed &&
        r.resolution != Resolution.denied) {
      return;
    }
    final sid = p0.sessionId;
    final pane = store.info(sid)?.paneId;
    if (pane == null) return;
    await Future<void>.delayed(hookAnswerGrace);
    final kind = _kindOfPending(p0);
    final String screen;
    try {
      screen = await terminal!.readVisible(pane);
    } on HerdrException catch (err) {
      Log.warn('No se pudo leer el terminal de $pane: ${err.message}');
      return;
    }
    if (!dialogShown(kind, screen) || !dialogIsFor(p0, screen)) return;
    Log.info(
      'Claude Code no aceptó la respuesta del hook ${p0.toolName} en '
      '${sid.length > 8 ? sid.substring(0, 8) : sid}: la pulso en el terminal',
    );
    await _answerByKeys(p0, pane, kind, r);
  }

  /// Pendiente y tarjeta de chat de un evento retenible. Es lo mismo se
  /// retenga el hook o se abra respaldado por el terminal.
  Future<(Pending, ChatItem)> _build(HookEvent e, String requestId) async {
    final sid = e.sessionId;
    // El transcript puede traer ya el texto previo: se lee antes para que el
    // pendiente quede después en el orden del chat.
    try {
      await hub.pollNow(sid).timeout(const Duration(milliseconds: 800));
    } catch (_) {}

    final now = DateTime.now().toUtc();
    final input = e.toolInput;
    final Pending pending;
    final ChatItem item;

    if (e.name == 'PreToolUse' && e.toolName != 'ExitPlanMode') {
      final questions = asList(input['questions'], QuestionSpec.fromJson);
      pending = Pending(
        requestId: requestId,
        sessionId: sid,
        kind: PendingKind.question,
        toolName: e.toolName ?? 'AskUserQuestion',
        toolInput: input,
        questions: questions,
        createdAt: now,
      );
      item = QuestionItem(
        id: e.toolUseId ?? 'question:$requestId',
        sessionId: sid,
        seq: 0,
        timestamp: now,
        requestId: requestId,
        questions: questions,
      );
    } else if (e.toolName == 'ExitPlanMode') {
      final plan = await _planText(sid, input);
      if (plan.isEmpty) {
        Log.warn(
          'ExitPlanMode sin texto de plan; claves: ${e.raw.keys.join(', ')}',
        );
      }
      pending = Pending(
        requestId: requestId,
        sessionId: sid,
        kind: PendingKind.plan,
        toolName: 'ExitPlanMode',
        toolInput: input,
        suggestions: asList(e.raw['permission_suggestions'], (m) => m),
        plan: plan,
        createdAt: now,
      );
      item = PlanItem(
        id: 'plan:$requestId',
        sessionId: sid,
        seq: 0,
        timestamp: now,
        requestId: requestId,
        plan: plan,
      );
    } else {
      pending = Pending(
        requestId: requestId,
        sessionId: sid,
        kind: PendingKind.permission,
        toolName: e.toolName ?? '',
        toolInput: input,
        suggestions: asList(e.raw['permission_suggestions'], (m) => m),
        createdAt: now,
      );
      item = PermissionItem(
        id: 'perm:$requestId',
        sessionId: sid,
        seq: 0,
        timestamp: now,
        requestId: requestId,
        toolName: e.toolName ?? '',
        toolInput: trimInput(input),
      );
    }

    return (pending, item);
  }

  void _onPendingEvent(PendingEvent ev) {
    if (ev is! PendingClosed) return;
    final p0 = ev.pending;
    // Un retenido que se libera (se fue la última app) o expira deja el
    // diálogo en el terminal: se reabre respaldado por él, con la misma
    // tarjeta y el mismo requestId.
    if (ev.toTerminal &&
        terminal != null &&
        !_terminalBacked.contains(p0.requestId) &&
        _itemIds.containsKey(p0.requestId) &&
        _startReopen(p0)) {
      return;
    }
    _terminalBacked.remove(p0.requestId);
    _closeItem(p0, ev.resolution, ev.answers);
  }

  void _closeItem(Pending p0, String resolution, Map<String, String>? answers) {
    final itemId = _itemIds.remove(p0.requestId);
    if (itemId != null) {
      final ev = (resolution: resolution, answers: answers);
      store.updateItem(p0.sessionId, itemId, (cur) {
        switch (cur) {
          case PermissionItem():
            return PermissionItem(
              id: cur.id,
              sessionId: cur.sessionId,
              seq: cur.seq,
              timestamp: cur.timestamp,
              requestId: cur.requestId,
              toolName: cur.toolName,
              toolInput: cur.toolInput,
              resolution: ev.resolution,
            );
          case PlanItem():
            return PlanItem(
              id: cur.id,
              sessionId: cur.sessionId,
              seq: cur.seq,
              timestamp: cur.timestamp,
              requestId: cur.requestId,
              plan: cur.plan,
              resolution: ev.resolution,
            );
          case QuestionItem():
            return QuestionItem(
              id: cur.id,
              sessionId: cur.sessionId,
              seq: cur.seq,
              timestamp: cur.timestamp,
              requestId: cur.requestId,
              questions: cur.questions,
              answers: ev.answers,
              resolution: ev.resolution,
            );
          default:
            return null;
        }
      });
    }
    // Resuelto el pendiente, el estado vuelve a trabajando (si no hay más).
    if (pendings.forSession(p0.sessionId).isEmpty &&
        store.info(p0.sessionId)?.status == SessionStatus.blocked) {
      store.setStatus(p0.sessionId, SessionStatus.working);
    }
  }
}
