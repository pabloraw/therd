import 'enums.dart';

Map<String, dynamic> asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<T> asList<T>(Object? v, T Function(Map<String, dynamic>) f) => v is List
    ? [
        for (final e in v)
          if (e is Map) f(asMap(e)),
      ]
    : <T>[];

/// Sesión de Claude Code asociada a un pane de herdr.
class SessionInfo {
  const SessionInfo({
    required this.sessionId,
    this.paneId,
    this.workspaceId,
    this.title = '',
    this.cwd = '',
    this.branch,
    this.status = SessionStatus.unknown,
    this.model,
    this.mode,
    this.lastSeq = 0,
    this.seenSeq = 0,
    this.tabId,
    this.tabLabel,
    this.tabNumber,
  });

  final String sessionId;
  final String? paneId;
  final String? workspaceId;
  final String title;
  final String cwd;
  final String? branch;
  final SessionStatus status;
  final String? model;
  final String? mode;

  /// Último seq de items de la sesión (0 si no hay).
  final int lastSeq;

  /// Hasta qué seq se ha visto la sesión fuera de este móvil: en el PC (herdr
  /// la da por vista) o en cualquier app conectada.
  final int seenSeq;

  /// Tab de herdr que contiene el pane (orden y nombre como en herdr).
  final String? tabId;
  final String? tabLabel;
  final int? tabNumber;

  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
    sessionId: j['sessionId'] as String? ?? '',
    paneId: j['paneId'] as String?,
    workspaceId: j['workspaceId'] as String?,
    title: j['title'] as String? ?? '',
    cwd: j['cwd'] as String? ?? '',
    branch: j['branch'] as String?,
    status: SessionStatus.parse(j['status']),
    model: j['model'] as String?,
    mode: j['mode'] as String?,
    lastSeq: (j['lastSeq'] as num?)?.toInt() ?? 0,
    seenSeq: (j['seenSeq'] as num?)?.toInt() ?? 0,
    tabId: j['tabId'] as String?,
    tabLabel: j['tabLabel'] as String?,
    tabNumber: (j['tabNumber'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'paneId': paneId,
    'workspaceId': workspaceId,
    'title': title,
    'cwd': cwd,
    'branch': branch,
    'status': status.name,
    'model': model,
    'mode': mode,
    'lastSeq': lastSeq,
    'seenSeq': seenSeq,
    'tabId': tabId,
    'tabLabel': tabLabel,
    'tabNumber': tabNumber,
  };

  SessionInfo copyWith({
    String? paneId,
    String? workspaceId,
    String? title,
    String? cwd,
    String? branch,
    SessionStatus? status,
    String? model,
    String? mode,
    int? lastSeq,
    int? seenSeq,
    String? tabId,
    String? tabLabel,
    int? tabNumber,
  }) => SessionInfo(
    sessionId: sessionId,
    paneId: paneId ?? this.paneId,
    workspaceId: workspaceId ?? this.workspaceId,
    title: title ?? this.title,
    cwd: cwd ?? this.cwd,
    branch: branch ?? this.branch,
    status: status ?? this.status,
    model: model ?? this.model,
    mode: mode ?? this.mode,
    lastSeq: lastSeq ?? this.lastSeq,
    seenSeq: seenSeq ?? this.seenSeq,
    tabId: tabId ?? this.tabId,
    tabLabel: tabLabel ?? this.tabLabel,
    tabNumber: tabNumber ?? this.tabNumber,
  );
}

/// Workspace de herdr. Los worktrees enlazados apuntan a su checkout
/// principal con [parentWorkspaceId] para anidarlos como en la barra de herdr.
class WorkspaceInfo {
  const WorkspaceInfo({
    required this.workspaceId,
    this.number = 0,
    this.label = '',
    this.repoName,
    this.branch,
    this.isLinkedWorktree = false,
    this.parentWorkspaceId,
  });

  final String workspaceId;

  /// Orden en la barra de herdr.
  final int number;
  final String label;
  final String? repoName;
  final String? branch;
  final bool isLinkedWorktree;
  final String? parentWorkspaceId;

  factory WorkspaceInfo.fromJson(Map<String, dynamic> j) => WorkspaceInfo(
    workspaceId: j['workspaceId'] as String? ?? '',
    number: (j['number'] as num?)?.toInt() ?? 0,
    label: j['label'] as String? ?? '',
    repoName: j['repoName'] as String?,
    branch: j['branch'] as String?,
    isLinkedWorktree: j['isLinkedWorktree'] as bool? ?? false,
    parentWorkspaceId: j['parentWorkspaceId'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'workspaceId': workspaceId,
    'number': number,
    'label': label,
    'repoName': repoName,
    'branch': branch,
    'isLinkedWorktree': isLinkedWorktree,
    'parentWorkspaceId': parentWorkspaceId,
  };

  @override
  bool operator ==(Object other) =>
      other is WorkspaceInfo &&
      other.workspaceId == workspaceId &&
      other.number == number &&
      other.label == label &&
      other.repoName == repoName &&
      other.branch == branch &&
      other.isLinkedWorktree == isLinkedWorktree &&
      other.parentWorkspaceId == parentWorkspaceId;

  @override
  int get hashCode => Object.hash(
    workspaceId,
    number,
    label,
    repoName,
    branch,
    isLinkedWorktree,
    parentWorkspaceId,
  );
}

/// Opción de una pregunta de AskUserQuestion.
class QuestionOption {
  const QuestionOption({required this.label, this.description = ''});

  final String label;
  final String description;

  factory QuestionOption.fromJson(Map<String, dynamic> j) => QuestionOption(
    label: j['label'] as String? ?? '',
    description: j['description'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'label': label, 'description': description};
}

/// Una pregunta de AskUserQuestion. La respuesta se indexa por [question].
class QuestionSpec {
  const QuestionSpec({
    required this.question,
    this.header = '',
    this.options = const [],
    this.multiSelect = false,
  });

  final String question;
  final String header;
  final List<QuestionOption> options;
  final bool multiSelect;

  factory QuestionSpec.fromJson(Map<String, dynamic> j) => QuestionSpec(
    question: j['question'] as String? ?? '',
    header: j['header'] as String? ?? '',
    options: asList(j['options'], QuestionOption.fromJson),
    multiSelect: j['multiSelect'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'question': question,
    'header': header,
    'options': [for (final o in options) o.toJson()],
    'multiSelect': multiSelect,
  };
}

/// Permiso, pregunta o plan que espera respuesta de la app.
class Pending {
  const Pending({
    required this.requestId,
    required this.sessionId,
    required this.kind,
    this.toolName = '',
    this.toolInput = const {},
    this.suggestions = const [],
    this.questions = const [],
    this.plan,
    required this.createdAt,
  });

  final String requestId;
  final String sessionId;
  final PendingKind kind;
  final String toolName;
  final Map<String, dynamic> toolInput;

  /// `permission_suggestions` tal cual los manda Claude Code (para "permitir siempre").
  final List<Map<String, dynamic>> suggestions;
  final List<QuestionSpec> questions;
  final String? plan;
  final DateTime createdAt;

  factory Pending.fromJson(Map<String, dynamic> j) => Pending(
    requestId: j['requestId'] as String? ?? '',
    sessionId: j['sessionId'] as String? ?? '',
    kind: PendingKind.parse(j['kind']),
    toolName: j['toolName'] as String? ?? '',
    toolInput: asMap(j['toolInput']),
    suggestions: asList(j['suggestions'], (m) => m),
    questions: asList(j['questions'], QuestionSpec.fromJson),
    plan: j['plan'] as String?,
    createdAt: parseTime(j['createdAt']),
  );

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'sessionId': sessionId,
    'kind': kind.name,
    'toolName': toolName,
    'toolInput': toolInput,
    'suggestions': suggestions,
    'questions': [for (final q in questions) q.toJson()],
    'plan': plan,
    'createdAt': formatTime(createdAt),
  };
}

/// Fecha ISO 8601 en UTC.
String formatTime(DateTime t) => t.toUtc().toIso8601String();

/// Lee una fecha ISO 8601; si falla devuelve la época (no lanza).
DateTime parseTime(Object? v) =>
    (v is String ? DateTime.tryParse(v) : null)?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
