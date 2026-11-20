import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:therd_protocol/protocol.dart';

/// Cambios del store que el AppServer reenvía a las apps.
sealed class StoreEvent {
  const StoreEvent();
}

/// Cambió la lista de sesiones o sus metadatos (no el estado ni los items).
class SessionsChanged extends StoreEvent {
  const SessionsChanged();
}

/// Una sesión desapareció del store (su seq se reiniciará si vuelve).
class SessionRemoved extends StoreEvent {
  const SessionRemoved(this.sessionId);
  final String sessionId;
}

class StatusChanged extends StoreEvent {
  const StatusChanged(this.sessionId, this.status);
  final String sessionId;
  final SessionStatus status;
}

/// La sesión se ha visto hasta [seq] (en el PC o en una app).
class SeenChanged extends StoreEvent {
  const SeenChanged(this.sessionId, this.seq);
  final String sessionId;
  final int seq;
}

class ItemAppended extends StoreEvent {
  const ItemAppended(this.item);
  final ChatItem item;
}

class ItemUpdated extends StoreEvent {
  const ItemUpdated(this.item);
  final ChatItem item;
}

/// Página de items para un backlog.
class BacklogPage {
  const BacklogPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });
  final List<ChatItem> items;
  final int cursor;
  final bool hasMore;
}

/// Copia de [i] con otro seq (los items del parser salen con seq 0).
ChatItem withSeq(ChatItem i, int seq) => switch (i) {
  UserPromptItem() => UserPromptItem(
    id: i.id,
    sessionId: i.sessionId,
    seq: seq,
    timestamp: i.timestamp,
    text: i.text,
    images: i.images,
  ),
  AssistantTextItem() => AssistantTextItem(
    id: i.id,
    sessionId: i.sessionId,
    seq: seq,
    timestamp: i.timestamp,
    text: i.text,
  ),
  ThinkingItem() => ThinkingItem(
    id: i.id,
    sessionId: i.sessionId,
    seq: seq,
    timestamp: i.timestamp,
    text: i.text,
  ),
  ToolCallItem() => i.copyWith(seq: seq),
  PermissionItem() => PermissionItem(
    id: i.id,
    sessionId: i.sessionId,
    seq: seq,
    timestamp: i.timestamp,
    requestId: i.requestId,
    toolName: i.toolName,
    toolInput: i.toolInput,
    resolution: i.resolution,
  ),
  QuestionItem() => QuestionItem(
    id: i.id,
    sessionId: i.sessionId,
    seq: seq,
    timestamp: i.timestamp,
    requestId: i.requestId,
    questions: i.questions,
    answers: i.answers,
    resolution: i.resolution,
  ),
  PlanItem() => PlanItem(
    id: i.id,
    sessionId: i.sessionId,
    seq: seq,
    timestamp: i.timestamp,
    requestId: i.requestId,
    plan: i.plan,
    resolution: i.resolution,
  ),
  MarkerItem() => MarkerItem(
    id: i.id,
    sessionId: i.sessionId,
    seq: seq,
    timestamp: i.timestamp,
    kind: i.kind,
    text: i.text,
    durationMs: i.durationMs,
  ),
  UnknownItem() => i,
};

class _Completion {
  _Completion(
    this.isError,
    this.result,
    this.durationMs,
    this.timestamp,
    this.images,
  );
  final bool isError;
  final List<String> images;
  final String result;
  final int? durationMs;
  final DateTime? timestamp;
}

class _State {
  _State(this.info);

  SessionInfo info;
  String? herdrTitle;
  String? aiTitle;
  bool inHerdr = false;
  String? transcriptPath;
  final List<ChatItem> items = [];
  final Map<String, ChatItem> byId = {};
  final Map<String, String> alias = {};
  final Map<String, _Completion> early = {};
  int seq = 0;

  /// Visto hasta este seq en el PC o en una app.
  int seen = 0;

  /// Estado tal como lo da herdr (los hooks no lo tocan): `idle` es terminado
  /// y ya visto en el PC; `done`, terminado sin ver.
  SessionStatus? herdrStatus;
}

/// Sesiones y sus items en memoria, con seq monotónico por sesión.
class SessionStore {
  SessionStore({this.maxItemsPerSession = 3000});

  final int maxItemsPerSession;
  final Map<String, _State> _sessions = {};
  final StreamController<StoreEvent> _events = StreamController.broadcast(
    sync: true,
  );

  Stream<StoreEvent> get events => _events.stream;

  // ----------------------------------------------------------- sesiones

  bool has(String sessionId) => _sessions.containsKey(sessionId);

  SessionInfo? info(String sessionId) {
    final s = _sessions[sessionId];
    return s == null ? null : _snapshot(s);
  }

  SessionInfo _snapshot(_State s) =>
      s.info.copyWith(lastSeq: s.seq, seenSeq: s.seen);

  List<SessionInfo> get sessions => [
    for (final s in _sessions.values) _snapshot(s),
  ];

  // --------------------------------------------------------- workspaces

  List<WorkspaceInfo> _workspaces = const [];
  List<WorkspaceInfo> get workspaces => _workspaces;

  /// Sustituye los workspaces de herdr; avisa solo si cambian.
  void setWorkspaces(List<WorkspaceInfo> ws) {
    if (ws.length == _workspaces.length &&
        Iterable.generate(ws.length).every((i) => ws[i] == _workspaces[i])) {
      return;
    }
    _workspaces = List.unmodifiable(ws);
    _events.add(const SessionsChanged());
  }

  String? transcriptPathOf(String sessionId) =>
      _sessions[sessionId]?.transcriptPath;

  String? sessionIdForPane(String paneId) {
    for (final s in _sessions.values) {
      if (s.info.paneId == paneId) return s.info.sessionId;
    }
    return null;
  }

  String _title(_State s) {
    final h = s.herdrTitle;
    if (h != null && h.isNotEmpty && h != 'Claude Code') return h;
    if (s.aiTitle != null && s.aiTitle!.isNotEmpty) return s.aiTitle!;
    final base = s.info.cwd.isEmpty ? '' : p.basename(s.info.cwd);
    return base.isEmpty ? 'Claude Code' : base;
  }

  /// Crea o actualiza una sesión. Los campos null no pisan lo que ya hay.
  void upsertSession(
    String sessionId, {
    String? paneId,
    String? workspaceId,
    String? herdrTitle,
    String? cwd,
    SessionStatus? status,
    String? model,
    String? mode,
    String? branch,
    String? transcriptPath,
    bool? fromHerdr,
    String? tabId,
    String? tabLabel,
    int? tabNumber,
  }) {
    var created = false;
    var s = _sessions[sessionId];
    if (s == null) {
      s = _State(SessionInfo(sessionId: sessionId));
      _sessions[sessionId] = s;
      created = true;
    }
    final before = s.info;
    if (herdrTitle != null) s.herdrTitle = herdrTitle;
    if (fromHerdr == true) s.inHerdr = true;
    if (transcriptPath != null) s.transcriptPath = transcriptPath;
    var info = s.info.copyWith(
      paneId: paneId,
      workspaceId: workspaceId,
      cwd: cwd,
      model: model,
      mode: mode,
      branch: branch,
      tabId: tabId,
      tabLabel: tabLabel,
      tabNumber: tabNumber,
    );
    s.info = info;
    info = info.copyWith(title: _title(s));
    s.info = info;

    final structural =
        created ||
        before.paneId != info.paneId ||
        before.workspaceId != info.workspaceId ||
        before.title != info.title ||
        before.cwd != info.cwd ||
        before.branch != info.branch ||
        before.model != info.model ||
        before.mode != info.mode ||
        before.tabId != info.tabId ||
        before.tabLabel != info.tabLabel ||
        before.tabNumber != info.tabNumber;
    if (status != null && status != s.info.status) {
      s.info = s.info.copyWith(status: status);
      if (!created) _events.add(StatusChanged(sessionId, status));
    }
    if (structural) _events.add(const SessionsChanged());
  }

  void setStatus(String sessionId, SessionStatus status) {
    final s = _sessions[sessionId];
    if (s == null || s.info.status == status) return;
    s.info = s.info.copyWith(status: status);
    _events.add(StatusChanged(sessionId, status));
  }

  // ------------------------------------------------------------- visto

  /// Pane enfocado ahora en el PC (null si no es de una sesión o no se sabe).
  String? get focusedPane => _focusedPane;
  String? _focusedPane;

  SessionStatus? herdrStatusOf(String sessionId) =>
      _sessions[sessionId]?.herdrStatus;

  /// Apunta el estado de herdr. `idle` quiere decir que el PC ya la vio.
  void setHerdrStatus(String sessionId, SessionStatus status) {
    final s = _sessions[sessionId];
    if (s == null) return;
    s.herdrStatus = status;
    if (status == SessionStatus.idle) _advanceSeen(s, s.seq);
  }

  /// El PC enfoca [paneId]: lo que tenga su sesión queda visto.
  void setFocusedPane(String? paneId) {
    _focusedPane = paneId;
    final sid = paneId == null ? null : sessionIdForPane(paneId);
    final s = sid == null ? null : _sessions[sid];
    if (s != null) _advanceSeen(s, s.seq);
  }

  /// Visto hasta [seq] (no pasa del último seq). Devuelve si avanzó.
  bool markSeen(String sessionId, int seq) {
    final s = _sessions[sessionId];
    return s != null && _advanceSeen(s, seq);
  }

  bool _advanceSeen(_State s, int seq) {
    final v = seq > s.seq ? s.seq : seq;
    if (v <= s.seen) return false;
    s.seen = v;
    _events.add(SeenChanged(s.info.sessionId, v));
    return true;
  }

  /// Metadatos vistos en el transcript (título, modo, modelo, rama).
  void updateMeta(
    String sessionId, {
    String? title,
    String? mode,
    String? model,
    String? branch,
  }) {
    final s = _sessions[sessionId];
    if (s == null) return;
    if (title != null) s.aiTitle = title;
    upsertSession(sessionId, mode: mode, model: model, branch: branch);
  }

  void removeSession(String sessionId) {
    if (_sessions.remove(sessionId) != null) {
      _events.add(SessionRemoved(sessionId));
      _events.add(const SessionsChanged());
    }
  }

  /// Quita las sesiones que herdr conocía y ya no lista (ni tienen actividad
  /// por hooks fuera de herdr). Devuelve los ids quitados.
  List<String> pruneHerdrSessions(Set<String> liveIds) {
    final gone = [
      for (final s in _sessions.values)
        if (s.inHerdr && !liveIds.contains(s.info.sessionId)) s.info.sessionId,
    ];
    for (final id in gone) {
      _sessions.remove(id);
      _events.add(SessionRemoved(id));
    }
    if (gone.isNotEmpty) _events.add(const SessionsChanged());
    return gone;
  }

  // -------------------------------------------------------------- items

  ChatItem? itemById(String sessionId, String id) {
    final s = _sessions[sessionId];
    if (s == null) return null;
    return s.byId[s.alias[id] ?? id];
  }

  List<ChatItem> itemsOf(String sessionId) =>
      List.unmodifiable(_sessions[sessionId]?.items ?? const <ChatItem>[]);

  /// Las últimas [limit] llamadas a `Task`/`Agent` de la sesión, de la más
  /// reciente a la más antigua (las que lanzan un subagente).
  List<ToolCallItem> subagentTasks(String sessionId, {int limit = 12}) {
    final s = _sessions[sessionId];
    if (s == null) return const [];
    final out = <ToolCallItem>[];
    for (var i = s.items.length - 1; i >= 0 && out.length < limit; i--) {
      final it = s.items[i];
      if (it is ToolCallItem &&
          (it.toolName == 'Task' || it.toolName == 'Agent')) {
        out.add(it);
      }
    }
    return out;
  }

  /// Añade un item deduplicando por id, alias y reconciliación con items
  /// creados por hooks. Devuelve el item guardado o null si no hizo falta.
  ChatItem? ingest(String sessionId, ChatItem draft) {
    final s = _sessions[sessionId];
    if (s == null) return null;

    final existingId = s.alias[draft.id] ?? draft.id;
    final existing = s.byId[existingId];
    if (existing != null) {
      _mergeDuplicate(s, existing, draft);
      return null;
    }

    // Prompt creado antes por hook (id 'hook:...'): se reconcilia por texto.
    if (draft is UserPromptItem) {
      final prov = _provisionalPrompt(s, draft.text);
      if (prov != null) {
        s.alias[draft.id] = prov.id;
        // El hook no trae las imágenes; el transcript sí.
        if (draft.images.isNotEmpty && prov is UserPromptItem) {
          _replace(
            s,
            UserPromptItem(
              id: prov.id,
              sessionId: prov.sessionId,
              seq: prov.seq,
              timestamp: prov.timestamp,
              text: prov.text,
              images: draft.images,
            ),
          );
        }
        return null;
      }
    }
    // Plan o pregunta ya creados por hook con el mismo contenido.
    if (draft is PlanItem && draft.requestId.isEmpty) {
      for (final it in s.items.reversed.take(30)) {
        if (it is PlanItem &&
            it.requestId.isNotEmpty &&
            it.plan == draft.plan) {
          s.alias[draft.id] = it.id;
          return null;
        }
      }
    }

    final stored = withSeq(draft, ++s.seq);
    _put(s, stored);
    _events.add(ItemAppended(stored));
    // Lo que llega a una sesión que se está mirando en el PC ya está visto.
    if (s.herdrStatus == SessionStatus.idle &&
        s.info.paneId != null &&
        s.info.paneId == _focusedPane) {
      _advanceSeen(s, s.seq);
    }

    final early = s.early.remove(stored.id);
    if (early != null) {
      completeTool(
        sessionId,
        stored.id,
        isError: early.isError,
        result: early.result,
        durationMs: early.durationMs,
        timestamp: early.timestamp,
        images: early.images,
      );
    }
    return itemById(sessionId, stored.id);
  }

  void _mergeDuplicate(_State s, ChatItem existing, ChatItem draft) {
    // Solo las tarjetas de herramienta ganan información (input) al repetirse.
    if (existing is ToolCallItem &&
        draft is ToolCallItem &&
        existing.input.isEmpty &&
        draft.input.isNotEmpty) {
      _replace(s, existing.copyWith(input: draft.input));
    }
    // Pregunta ya creada por hook: no se pisa; la del transcript solo aporta
    // el hueco si estaba vacía.
    if (existing is QuestionItem &&
        draft is QuestionItem &&
        existing.questions.isEmpty &&
        draft.questions.isNotEmpty) {
      _replace(
        s,
        QuestionItem(
          id: existing.id,
          sessionId: existing.sessionId,
          seq: existing.seq,
          timestamp: existing.timestamp,
          requestId: existing.requestId,
          questions: draft.questions,
          answers: existing.answers,
          resolution: existing.resolution,
        ),
      );
    }
  }

  ChatItem? _provisionalPrompt(_State s, String text) {
    for (final it in s.items.reversed.take(20)) {
      if (it is UserPromptItem &&
          it.id.startsWith('hook:') &&
          it.text == text) {
        final claimed = s.alias.values.contains(it.id);
        if (!claimed) return it;
      }
    }
    return null;
  }

  void _put(_State s, ChatItem item) {
    s.items.add(item);
    s.byId[item.id] = item;
    if (s.items.length > maxItemsPerSession) {
      final drop = s.items.length - maxItemsPerSession + 200;
      for (final old in s.items.take(drop)) {
        s.byId.remove(old.id);
      }
      s.items.removeRange(0, drop.clamp(0, s.items.length));
    }
  }

  /// Sustituye un item (mismo id y seq) y emite item.update.
  void _replace(_State s, ChatItem updated) {
    final idx = s.items.indexWhere((e) => e.id == updated.id);
    if (idx >= 0) s.items[idx] = updated;
    s.byId[updated.id] = updated;
    _events.add(ItemUpdated(updated));
  }

  /// Reemplaza un item por id con el resultado de [f]; null no cambia nada.
  ChatItem? updateItem(
    String sessionId,
    String id,
    ChatItem? Function(ChatItem current) f,
  ) {
    final s = _sessions[sessionId];
    if (s == null) return null;
    final cur = s.byId[s.alias[id] ?? id];
    if (cur == null) return null;
    final next = f(cur);
    if (next == null) return null;
    _replace(s, next);
    return next;
  }

  /// Inserta o fusiona el item de un pendiente creado por hook. Si el
  /// transcript ya había creado el mismo plan o pregunta, lo adopta.
  ChatItem? upsertPendingItem(String sessionId, ChatItem item) {
    final s = _sessions[sessionId];
    if (s == null) return null;
    final byId = s.byId[item.id];
    if (byId != null) {
      final merged = withSeq(item, byId.seq);
      _replace(s, merged);
      return merged;
    }
    if (item is PlanItem) {
      for (final it in s.items.reversed.take(30)) {
        if (it is PlanItem &&
            it.requestId.isEmpty &&
            it.resolution == null &&
            it.plan == item.plan) {
          // El transcript ya tiene la tarjeta: se le asigna el requestId.
          final merged = PlanItem(
            id: it.id,
            sessionId: it.sessionId,
            seq: it.seq,
            timestamp: it.timestamp,
            requestId: item.requestId,
            plan: it.plan,
          );
          _replace(s, merged);
          return merged;
        }
      }
    }
    return ingest(sessionId, item) ?? s.byId[item.id];
  }

  /// Cierra la tarjeta de una herramienta (o pregunta/plan) con su resultado.
  void completeTool(
    String sessionId,
    String toolUseId, {
    required bool isError,
    String result = '',
    int? durationMs,
    DateTime? timestamp,
    List<String> images = const [],
  }) {
    final s = _sessions[sessionId];
    if (s == null) return;
    final item = s.byId[s.alias[toolUseId] ?? toolUseId];
    if (item == null) {
      s.early[toolUseId] = _Completion(
        isError,
        result,
        durationMs,
        timestamp,
        images,
      );
      if (s.early.length > 200) s.early.remove(s.early.keys.first);
      return;
    }
    switch (item) {
      case ToolCallItem():
        final status = isError ? ToolStatus.error : ToolStatus.ok;
        final newResult = result.isNotEmpty ? result : item.result;
        final newImages = images.isNotEmpty ? images : item.images;
        var dur = durationMs ?? item.durationMs;
        if (dur == null && timestamp != null) {
          final d = timestamp.difference(item.timestamp).inMilliseconds;
          if (d >= 0) dur = d;
        }
        if (item.status == status &&
            item.isError == isError &&
            (item.result ?? '') == (newResult ?? '') &&
            item.durationMs == dur &&
            item.images.join(',') == newImages.join(',')) {
          return;
        }
        _replace(
          s,
          item.copyWith(
            status: status,
            isError: isError,
            result: newResult,
            durationMs: dur,
            images: newImages,
          ),
        );
      case QuestionItem():
        if (item.resolution != null) return;
        _replace(
          s,
          QuestionItem(
            id: item.id,
            sessionId: item.sessionId,
            seq: item.seq,
            timestamp: item.timestamp,
            requestId: item.requestId,
            questions: item.questions,
            answers: isError ? null : parseAnswers(result),
            resolution: isError ? Resolution.cancelled : Resolution.answered,
          ),
        );
      case PlanItem():
        if (item.resolution != null) return;
        _replace(
          s,
          PlanItem(
            id: item.id,
            sessionId: item.sessionId,
            seq: item.seq,
            timestamp: item.timestamp,
            requestId: item.requestId,
            plan: item.plan,
            resolution: isError ? Resolution.denied : Resolution.allowed,
          ),
        );
      default:
        return;
    }
  }

  // ------------------------------------------------------------ backlog

  /// Últimos [limit] items con seq < [before] (todos si es null), ascendente.
  BacklogPage backlog(String sessionId, {int? before, int limit = 100}) {
    final s = _sessions[sessionId];
    if (s == null) {
      return const BacklogPage(items: [], cursor: 0, hasMore: false);
    }
    var end = s.items.length;
    if (before != null) {
      end = s.items.indexWhere((e) => e.seq >= before);
      if (end < 0) end = s.items.length;
    }
    final lim = limit <= 0 ? 100 : limit;
    final start = end - lim < 0 ? 0 : end - lim;
    final page = s.items.sublist(start, end);
    return BacklogPage(
      items: page,
      cursor: page.isEmpty ? 0 : page.first.seq,
      hasMore: start > 0,
    );
  }

  Future<void> dispose() => _events.close();
}

/// Extrae `"pregunta"="respuesta"` del resultado de AskUserQuestion.
Map<String, String>? parseAnswers(String result) {
  final m = RegExp(r'"([^"]+)"="([^"]*)"').allMatches(result);
  if (m.isEmpty) return null;
  return {for (final x in m) x.group(1)!: x.group(2)!};
}
