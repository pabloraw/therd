import 'dart:convert';

import 'package:therd_protocol/protocol.dart';

import 'images.dart';
import 'uploads.dart';

/// Resultado de interpretar una línea del transcript.
sealed class TranscriptEvent {
  const TranscriptEvent();
}

/// Item nuevo (seq 0: el store asigna el definitivo).
class ItemEvent extends TranscriptEvent {
  const ItemEvent(this.item);
  final ChatItem item;
}

/// Resultado de una herramienta, para cerrar su tarjeta.
class ToolResultEvent extends TranscriptEvent {
  const ToolResultEvent({
    required this.toolUseId,
    required this.isError,
    required this.result,
    required this.timestamp,
    this.images = const [],
  });
  final String toolUseId;
  final bool isError;
  final String result;
  final DateTime timestamp;
  final List<String> images;
}

/// Metadatos de la sesión vistos en el transcript.
class MetaEvent extends TranscriptEvent {
  const MetaEvent({this.title, this.mode, this.model, this.branch});
  final String? title;
  final String? mode;
  final String? model;
  final String? branch;
}

/// Máximo de caracteres del resultado de una herramienta que se conserva.
const int maxResultChars = 2000;

/// Máximo de caracteres por cadena dentro de `input` de una herramienta.
const int maxInputStringChars = 4000;

String truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// Interpreta una línea de un JSONL en eventos de tipo [T].
abstract interface class LineParser<T> {
  List<T> parseLine(String line);
}

/// Parser puro y tolerante de líneas del transcript JSONL de Claude Code.
/// Los tipos desconocidos y las líneas rotas se ignoran sin lanzar.
class TranscriptParser implements LineParser<TranscriptEvent> {
  TranscriptParser(this.sessionId, {this.images});

  final String sessionId;

  /// Dónde guardar las imágenes; sin él se pintan como «[imagen]».
  final ImageStore? images;

  @override
  List<TranscriptEvent> parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    try {
      return _parse(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const [];
    }
  }

  List<TranscriptEvent> _parse(Map<String, dynamic> j) {
    if (j['isSidechain'] == true) return const [];
    final type = j['type'];
    final out = <TranscriptEvent>[];
    final branch = j['gitBranch'] as String?;
    if (branch != null && branch.isNotEmpty && branch != 'HEAD') {
      out.add(MetaEvent(branch: branch));
    }
    switch (type) {
      case 'ai-title':
        final t = j['aiTitle'];
        if (t is String && t.isNotEmpty) out.add(MetaEvent(title: t));
      case 'permission-mode':
        final m = j['permissionMode'];
        if (m is String && m.isNotEmpty) out.add(MetaEvent(mode: m));
      case 'user':
        out.addAll(_user(j));
      case 'assistant':
        out.addAll(_assistant(j));
      case 'system':
        out.addAll(_system(j));
    }
    return out;
  }

  DateTime _ts(Map<String, dynamic> j) => parseTime(j['timestamp']);

  List<TranscriptEvent> _user(Map<String, dynamic> j) {
    if (j['isMeta'] == true || j['isCompactSummary'] == true) return const [];
    final uuid = j['uuid'] as String? ?? '';
    final ts = _ts(j);
    final msg = asMap(j['message']);
    final content = msg['content'];
    final out = <TranscriptEvent>[];

    if (content is String) {
      final item = _promptFromText(content, uuid, ts);
      if (item != null) out.add(ItemEvent(item));
      return out;
    }
    if (content is List) {
      final texts = <String>[];
      final ids = <String>[];
      for (final b in content) {
        if (b is! Map) continue;
        switch (b['type']) {
          case 'tool_result':
            final id = b['tool_use_id'] as String?;
            if (id != null) {
              out.add(
                ToolResultEvent(
                  toolUseId: id,
                  isError: b['is_error'] == true,
                  result: truncate(
                    _resultText(b['content'], withImages: images == null),
                    maxResultChars,
                  ),
                  timestamp: ts,
                  images: _resultImages(b['content']),
                ),
              );
            }
          case 'text':
            final t = b['text'];
            if (t is String) texts.add(t);
          case 'image':
            final id = images?.putBlock(b);
            if (id != null) {
              ids.add(id);
            } else {
              texts.add('[imagen]');
            }
        }
      }
      if (texts.isNotEmpty || ids.isNotEmpty) {
        final item = _promptFromText(texts.join('\n'), uuid, ts, ids);
        if (item != null) out.add(ItemEvent(item));
      }
    }
    return out;
  }

  List<String> _resultImages(Object? content) {
    final store = images;
    if (store == null || content is! List) return const [];
    return [for (final b in content) ?store.putBlock(b)];
  }

  ChatItem? _promptFromText(
    String raw,
    String uuid,
    DateTime ts, [
    List<String> ids = const [],
  ]) {
    // «[Image #3]» es la marca de Claude Code de una imagen adjunta, que ya
    // va en [ids].
    final text = cleanPromptText(raw);
    if (text.isEmpty && ids.isEmpty) return null;
    if (text.startsWith('[Request interrupted by user')) {
      return MarkerItem(
        id: uuid,
        sessionId: sessionId,
        seq: 0,
        timestamp: ts,
        kind: MarkerKind.other,
        text: 'Interrumpido por el usuario',
      );
    }
    final cmd = RegExp(
      r'<command-name>(.*?)</command-name>',
      dotAll: true,
    ).firstMatch(text);
    if (cmd != null) {
      final args = RegExp(
        r'<command-args>(.*?)</command-args>',
        dotAll: true,
      ).firstMatch(text)?.group(1)?.trim();
      final full = [cmd.group(1)!.trim(), ?args].where((e) => e.isNotEmpty);
      return UserPromptItem(
        id: uuid,
        sessionId: sessionId,
        seq: 0,
        timestamp: ts,
        text: full.join(' '),
      );
    }
    if (RegExp(
      r'^<(system-reminder|local-command-[a-z]+|task-notification|bash-[a-z]+)>',
    ).hasMatch(text)) {
      return null;
    }
    return UserPromptItem(
      id: uuid,
      sessionId: sessionId,
      seq: 0,
      timestamp: ts,
      text: text,
      images: ids,
    );
  }

  List<TranscriptEvent> _assistant(Map<String, dynamic> j) {
    final uuid = j['uuid'] as String? ?? '';
    final ts = _ts(j);
    final msg = asMap(j['message']);
    final out = <TranscriptEvent>[];
    final model = msg['model'];
    if (model is String && model.isNotEmpty && !model.startsWith('<')) {
      out.add(MetaEvent(model: model));
    }
    final content = msg['content'];
    if (content is! List) return out;

    final apiError = j['isApiErrorMessage'] == true;
    var idx = 0;
    final multiple = content.length > 1;
    for (final b in content) {
      final i = idx++;
      if (b is! Map) continue;
      final id = multiple ? '$uuid:$i' : uuid;
      switch (b['type']) {
        case 'text':
          final t = (b['text'] as String? ?? '').trim();
          if (t.isEmpty) continue;
          out.add(
            ItemEvent(
              apiError
                  ? MarkerItem(
                      id: id,
                      sessionId: sessionId,
                      seq: 0,
                      timestamp: ts,
                      kind: MarkerKind.error,
                      text: t,
                    )
                  : AssistantTextItem(
                      id: id,
                      sessionId: sessionId,
                      seq: 0,
                      timestamp: ts,
                      text: t,
                    ),
            ),
          );
        case 'thinking':
          final t = (b['thinking'] as String? ?? '').trim();
          if (t.isEmpty) continue;
          out.add(
            ItemEvent(
              ThinkingItem(
                id: id,
                sessionId: sessionId,
                seq: 0,
                timestamp: ts,
                text: t,
              ),
            ),
          );
        case 'tool_use':
          final toolId = b['id'] as String?;
          if (toolId == null) continue;
          out.add(ItemEvent(_toolItem(toolId, b, ts)));
      }
    }
    return out;
  }

  ChatItem _toolItem(String toolId, Map b, DateTime ts) {
    final name = b['name'] as String? ?? '';
    final input = asMap(b['input']);
    if (name == 'AskUserQuestion') {
      return QuestionItem(
        id: toolId,
        sessionId: sessionId,
        seq: 0,
        timestamp: ts,
        requestId: '',
        questions: asList(input['questions'], QuestionSpec.fromJson),
      );
    }
    if (name == 'ExitPlanMode') {
      return PlanItem(
        id: toolId,
        sessionId: sessionId,
        seq: 0,
        timestamp: ts,
        requestId: '',
        plan: input['plan'] as String? ?? '',
      );
    }
    return ToolCallItem(
      id: toolId,
      sessionId: sessionId,
      seq: 0,
      timestamp: ts,
      toolName: name,
      input: trimInput(input),
    );
  }

  List<TranscriptEvent> _system(Map<String, dynamic> j) {
    final uuid = j['uuid'] as String? ?? '';
    final ts = _ts(j);
    switch (j['subtype']) {
      case 'compact_boundary':
        return [
          ItemEvent(
            MarkerItem(
              id: uuid,
              sessionId: sessionId,
              seq: 0,
              timestamp: ts,
              kind: MarkerKind.compact,
              text: 'Conversación compactada',
            ),
          ),
        ];
      case 'turn_duration':
        return [
          ItemEvent(
            MarkerItem(
              id: uuid,
              sessionId: sessionId,
              seq: 0,
              timestamp: ts,
              kind: MarkerKind.turnEnd,
              durationMs: (j['durationMs'] as num?)?.toInt(),
            ),
          ),
        ];
      case final String s when s.contains('error'):
        final c = j['content'];
        return [
          ItemEvent(
            MarkerItem(
              id: uuid,
              sessionId: sessionId,
              seq: 0,
              timestamp: ts,
              kind: MarkerKind.error,
              text: c is String && c.isNotEmpty ? truncate(c, 500) : 'Error',
            ),
          ),
        ];
    }
    return const [];
  }
}

/// Texto plano de un `content` de tool_result (cadena o lista de bloques).
String _resultText(Object? c, {bool withImages = true}) {
  if (c is String) return c;
  if (c is List) {
    return c
        .map((e) {
          if (e is Map && e['type'] == 'text') return '${e['text']}';
          if (withImages && e is Map && e['type'] == 'image') return '[imagen]';
          return '';
        })
        .where((s) => s.isNotEmpty)
        .join('\n');
  }
  return c == null ? '' : '$c';
}

/// Recorta cadenas largas dentro del input de una herramienta.
Map<String, dynamic> trimInput(Map<String, dynamic> input) =>
    Map<String, dynamic>.from(_trimValue(input) as Map);

Object? _trimValue(Object? v) {
  if (v is String) return truncate(v, maxInputStringChars);
  if (v is Map) {
    return {for (final e in v.entries) '${e.key}': _trimValue(e.value)};
  }
  if (v is List) return [for (final e in v) _trimValue(e)];
  return v;
}

/// Texto plano de un resultado de hook (`tool_response`, cadena u objeto).
String responseText(Object? r) {
  if (r == null) return '';
  if (r is String) return truncate(r, maxResultChars);
  if (r is Map) {
    for (final k in ['stdout', 'output', 'content', 'text', 'result']) {
      final v = r[k];
      if (v is String && v.isNotEmpty) {
        final err = r['stderr'];
        final both = k == 'stdout' && err is String && err.isNotEmpty
            ? '$v\n$err'
            : v;
        return truncate(both, maxResultChars);
      }
    }
  }
  try {
    return truncate(jsonEncode(r), maxResultChars);
  } catch (_) {
    return '';
  }
}
