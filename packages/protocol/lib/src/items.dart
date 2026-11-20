import 'enums.dart';
import 'models.dart';

/// Item del chat. `id` es estable: uuid de línea del transcript o tool_use_id.
/// `seq` es monotónico por sesión (cursor de paginación).
sealed class ChatItem {
  const ChatItem({
    required this.id,
    required this.sessionId,
    required this.seq,
    required this.timestamp,
  });

  final String id;
  final String sessionId;
  final int seq;
  final DateTime timestamp;

  /// Valor del campo "type" en JSON.
  String get type;

  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'sessionId': sessionId,
    'seq': seq,
    'timestamp': formatTime(timestamp),
    ...bodyJson(),
  };

  Map<String, dynamic> bodyJson();

  /// Decodifica por "type"; un tipo desconocido da [UnknownItem], nunca lanza.
  factory ChatItem.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String? ?? '';
    final sid = j['sessionId'] as String? ?? '';
    final seq = (j['seq'] as num?)?.toInt() ?? 0;
    final ts = parseTime(j['timestamp']);
    switch (j['type']) {
      case 'user_prompt':
        return UserPromptItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          text: j['text'] as String? ?? '',
          images: _ids(j['images']),
        );
      case 'assistant_text':
        return AssistantTextItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          text: j['text'] as String? ?? '',
        );
      case 'thinking':
        return ThinkingItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          text: j['text'] as String? ?? '',
        );
      case 'tool_call':
        return ToolCallItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          toolName: j['toolName'] as String? ?? '',
          input: asMap(j['input']),
          status: ToolStatus.parse(j['status']),
          result: j['result'] as String?,
          isError: j['isError'] as bool? ?? false,
          durationMs: (j['durationMs'] as num?)?.toInt(),
          images: _ids(j['images']),
          subagent: j['subagent'] is Map
              ? SubagentInfo.fromJson(asMap(j['subagent']))
              : null,
        );
      case 'permission':
        return PermissionItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          requestId: j['requestId'] as String? ?? '',
          toolName: j['toolName'] as String? ?? '',
          toolInput: asMap(j['toolInput']),
          resolution: j['resolution'] as String?,
        );
      case 'question':
        return QuestionItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          requestId: j['requestId'] as String? ?? '',
          questions: asList(j['questions'], QuestionSpec.fromJson),
          answers: j['answers'] is Map
              ? {
                  for (final e in (j['answers'] as Map).entries)
                    '${e.key}': '${e.value}',
                }
              : null,
          resolution: j['resolution'] as String?,
        );
      case 'plan':
        return PlanItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          requestId: j['requestId'] as String? ?? '',
          plan: j['plan'] as String? ?? '',
          resolution: j['resolution'] as String?,
        );
      case 'marker':
        return MarkerItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          kind: MarkerKind.parse(j['kind']),
          text: j['text'] as String? ?? '',
          durationMs: (j['durationMs'] as num?)?.toInt(),
        );
      default:
        return UnknownItem(
          id: id,
          sessionId: sid,
          seq: seq,
          timestamp: ts,
          rawType: '${j['type']}',
          raw: j,
        );
    }
  }
}

/// Prompt del usuario (texto plano).
final class UserPromptItem extends ChatItem {
  const UserPromptItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.text,
    this.images = const [],
  });
  final String text;

  /// Ids de las imágenes adjuntas (ver [imagePath]).
  final List<String> images;
  @override
  String get type => 'user_prompt';
  @override
  Map<String, dynamic> bodyJson() => {
    'text': text,
    if (images.isNotEmpty) 'images': images,
  };
}

/// Texto del asistente (Markdown).
final class AssistantTextItem extends ChatItem {
  const AssistantTextItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.text,
  });
  final String text;
  @override
  String get type => 'assistant_text';
  @override
  Map<String, dynamic> bodyJson() => {'text': text};
}

/// Bloque de thinking (plegado en la app).
final class ThinkingItem extends ChatItem {
  const ThinkingItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.text,
  });
  final String text;
  @override
  String get type => 'thinking';
  @override
  Map<String, dynamic> bodyJson() => {'text': text};
}

/// Llamada a herramienta; `id` = tool_use_id.
final class ToolCallItem extends ChatItem {
  const ToolCallItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.toolName,
    this.input = const {},
    this.status = ToolStatus.running,
    this.result,
    this.isError = false,
    this.durationMs,
    this.images = const [],
    this.subagent,
  });
  final String toolName;

  /// Actividad del subagente que lanzó esta llamada (`Task` o `Agent`); null
  /// en el resto de herramientas y en subagentes sin transcript propio.
  final SubagentInfo? subagent;

  /// Imágenes del resultado (capturas, Read de una imagen...).
  final List<String> images;
  final Map<String, dynamic> input;
  final ToolStatus status;

  /// Resultado resumido (el daemon lo trunca).
  final String? result;
  final bool isError;
  final int? durationMs;
  @override
  String get type => 'tool_call';
  @override
  Map<String, dynamic> bodyJson() => {
    'toolName': toolName,
    'input': input,
    'status': status.name,
    'result': result,
    'isError': isError,
    'durationMs': durationMs,
    if (images.isNotEmpty) 'images': images,
    if (subagent != null) 'subagent': subagent!.toJson(),
  };

  ToolCallItem copyWith({
    int? seq,
    DateTime? timestamp,
    Map<String, dynamic>? input,
    ToolStatus? status,
    String? result,
    bool? isError,
    int? durationMs,
    List<String>? images,
    SubagentInfo? subagent,
  }) => ToolCallItem(
    id: id,
    sessionId: sessionId,
    seq: seq ?? this.seq,
    timestamp: timestamp ?? this.timestamp,
    toolName: toolName,
    input: input ?? this.input,
    status: status ?? this.status,
    result: result ?? this.result,
    isError: isError ?? this.isError,
    durationMs: durationMs ?? this.durationMs,
    images: images ?? this.images,
    subagent: subagent ?? this.subagent,
  );
}

/// Una herramienta que ha usado un subagente, resumida: sin salida, y con el
/// `input` reducido a lo que se enseña en una fila.
final class SubagentStep {
  const SubagentStep({
    required this.id,
    required this.name,
    this.input = const {},
    this.status = ToolStatus.running,
  });

  factory SubagentStep.fromJson(Map<String, dynamic> j) => SubagentStep(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    input: asMap(j['input']),
    status: ToolStatus.parse(j['status']),
  );

  final String id;
  final String name;
  final Map<String, dynamic> input;
  final ToolStatus status;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'input': input,
    'status': status.name,
  };

  @override
  bool operator ==(Object other) =>
      other is SubagentStep &&
      other.id == id &&
      other.name == name &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, name, status);
}

/// Lo que hace un subagente, leído de su propio transcript. Va dentro del
/// [ToolCallItem] que lo lanzó, así que no cuenta como item nuevo.
final class SubagentInfo {
  const SubagentInfo({
    required this.agentId,
    this.steps = const [],
    this.toolCount = 0,
    this.finished = false,
    this.durationMs,
    this.finalText,
  });

  factory SubagentInfo.fromJson(Map<String, dynamic> j) => SubagentInfo(
    agentId: j['agentId'] as String? ?? '',
    steps: asList(j['steps'], SubagentStep.fromJson),
    toolCount: (j['toolCount'] as num?)?.toInt() ?? 0,
    finished: j['finished'] as bool? ?? false,
    durationMs: (j['durationMs'] as num?)?.toInt(),
    finalText: j['finalText'] as String?,
  );

  final String agentId;

  /// Las últimas herramientas (el daemon recorta las más antiguas).
  final List<SubagentStep> steps;

  /// Herramientas usadas en total, también las recortadas de [steps].
  final int toolCount;

  /// El subagente ya terminó (en segundo plano la tarjeta de `Task` se cierra
  /// al lanzarlo, así que no vale su estado).
  final bool finished;
  final int? durationMs;

  /// Último texto del subagente (Markdown).
  final String? finalText;

  Map<String, dynamic> toJson() => {
    'agentId': agentId,
    'steps': [for (final s in steps) s.toJson()],
    'toolCount': toolCount,
    'finished': finished,
    if (durationMs != null) 'durationMs': durationMs,
    if (finalText != null) 'finalText': finalText,
  };

  @override
  bool operator ==(Object other) =>
      other is SubagentInfo &&
      other.agentId == agentId &&
      other.toolCount == toolCount &&
      other.finished == finished &&
      other.durationMs == durationMs &&
      other.finalText == finalText &&
      other.steps.length == steps.length &&
      Iterable.generate(steps.length).every((i) => steps[i] == other.steps[i]);

  @override
  int get hashCode =>
      Object.hash(agentId, toolCount, finished, durationMs, finalText);
}

/// Permiso solicitado; `resolution` null mientras está pendiente (ver [Resolution]).
final class PermissionItem extends ChatItem {
  const PermissionItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.requestId,
    required this.toolName,
    this.toolInput = const {},
    this.resolution,
  });
  final String requestId;
  final String toolName;
  final Map<String, dynamic> toolInput;
  final String? resolution;
  @override
  String get type => 'permission';
  @override
  Map<String, dynamic> bodyJson() => {
    'requestId': requestId,
    'toolName': toolName,
    'toolInput': toolInput,
    'resolution': resolution,
  };
}

/// Pregunta de AskUserQuestion con su lista de preguntas.
final class QuestionItem extends ChatItem {
  const QuestionItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.requestId,
    this.questions = const [],
    this.answers,
    this.resolution,
  });
  final String requestId;
  final List<QuestionSpec> questions;

  /// Respuestas por texto de pregunta, una vez contestada.
  final Map<String, String>? answers;
  final String? resolution;
  @override
  String get type => 'question';
  @override
  Map<String, dynamic> bodyJson() => {
    'requestId': requestId,
    'questions': [for (final q in questions) q.toJson()],
    'answers': answers,
    'resolution': resolution,
  };
}

/// Plan de ExitPlanMode (Markdown).
final class PlanItem extends ChatItem {
  const PlanItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.requestId,
    required this.plan,
    this.resolution,
  });
  final String requestId;
  final String plan;
  final String? resolution;
  @override
  String get type => 'plan';
  @override
  Map<String, dynamic> bodyJson() => {
    'requestId': requestId,
    'plan': plan,
    'resolution': resolution,
  };
}

/// Marcador: compactación, fin de turno (con duración) o error.
final class MarkerItem extends ChatItem {
  const MarkerItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.kind,
    this.text = '',
    this.durationMs,
  });
  final MarkerKind kind;
  final String text;
  final int? durationMs;
  @override
  String get type => 'marker';
  @override
  Map<String, dynamic> bodyJson() => {
    'kind': kind.wire,
    'text': text,
    'durationMs': durationMs,
  };
}

/// Item de un tipo que esta versión no conoce; se conserva el JSON original.
final class UnknownItem extends ChatItem {
  const UnknownItem({
    required super.id,
    required super.sessionId,
    required super.seq,
    required super.timestamp,
    required this.rawType,
    required this.raw,
  });
  final String rawType;
  final Map<String, dynamic> raw;
  @override
  String get type => rawType;
  @override
  Map<String, dynamic> toJson() => raw;
  @override
  Map<String, dynamic> bodyJson() => const {};
}

List<String> _ids(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is String) e,
      ]
    : const [];

/// Ruta HTTP del servidor de la app que sirve la imagen [id]. Pide el token
/// como en el WebSocket (cabecera `Authorization: Bearer` o `?token=`).
String imagePath(String id) => '/images/$id';
