import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:therd_protocol/protocol.dart';

import 'log.dart';
import 'session_store.dart';
import 'transcript_parser.dart';
import 'transcript_tailer.dart';

/// Máximo de herramientas por subagente que viajan en el item (las más
/// recientes); el total va aparte en `toolCount`.
const int maxSubagentSteps = 30;

/// Máximo de caracteres por campo del `input` de un paso.
const int maxStepInputChars = 200;

/// Máximo de caracteres del último texto del subagente.
const int maxSubagentTextChars = 4000;

/// Campos del `input` de una herramienta que bastan para pintar su fila.
const _stepKeys = [
  'file_path',
  'notebook_path',
  'command',
  'pattern',
  'path',
  'url',
  'query',
  'description',
  'subagent_type',
];

/// Reduce el `input` de una herramienta a lo que enseña una fila compacta.
Map<String, dynamic> stepInput(Map<String, dynamic> input) => {
  for (final k in _stepKeys)
    if (input[k] is String && (input[k] as String).isNotEmpty)
      k: truncate(input[k] as String, maxStepInputChars),
};

/// Un hecho de una línea del transcript de un subagente.
class AgentEvent {
  const AgentEvent({
    this.timestamp,
    this.toolId,
    this.toolName,
    this.input = const {},
    this.isEnd = false,
    this.isError = false,
    this.text,
  });

  final DateTime? timestamp;

  /// Herramienta que empieza (con [toolName]) o termina ([isEnd]).
  final String? toolId;
  final String? toolName;
  final Map<String, dynamic> input;
  final bool isEnd;
  final bool isError;

  /// Texto del asistente.
  final String? text;
}

/// Lee las líneas de `subagents/agent-*.jsonl`: solo interesan las
/// herramientas (inicio y fin) y el texto del asistente. Es tolerante.
class SubagentParser implements LineParser<AgentEvent> {
  @override
  List<AgentEvent> parseLine(String line) {
    // Las líneas `api-request-*` llevan el prompt de sistema entero: ni se
    // decodifican.
    if (line.isEmpty || line.startsWith('{"type":"api-')) return const [];
    try {
      final j = jsonDecode(line);
      if (j is! Map) return const [];
      final type = j['type'];
      if (type != 'assistant' && type != 'user') return const [];
      final content = asMap(j['message'])['content'];
      final ts = parseTime(j['timestamp']);
      if (content is! List) return [AgentEvent(timestamp: ts)];
      final out = <AgentEvent>[];
      for (final b in content) {
        if (b is! Map) continue;
        switch (b['type']) {
          case 'tool_use' when type == 'assistant':
            final id = b['id'];
            if (id is String) {
              out.add(
                AgentEvent(
                  timestamp: ts,
                  toolId: id,
                  toolName: b['name'] as String? ?? '',
                  input: stepInput(asMap(b['input'])),
                ),
              );
            }
          case 'tool_result' when type == 'user':
            final id = b['tool_use_id'];
            if (id is String) {
              out.add(
                AgentEvent(
                  timestamp: ts,
                  toolId: id,
                  isEnd: true,
                  isError: b['is_error'] == true,
                ),
              );
            }
          case 'text' when type == 'assistant':
            final t = (b['text'] as String? ?? '').trim();
            if (t.isNotEmpty) {
              out.add(
                AgentEvent(
                  timestamp: ts,
                  text: truncate(t, maxSubagentTextChars),
                ),
              );
            }
        }
      }
      if (out.isEmpty) out.add(AgentEvent(timestamp: ts));
      return out;
    } catch (_) {
      return const [];
    }
  }
}

/// Estado acumulado de un subagente a partir de su transcript.
class AgentProgress {
  final List<SubagentStep> steps = [];
  int toolCount = 0;
  String? finalText;
  DateTime? first;
  DateTime? last;

  void apply(AgentEvent e) {
    final ts = e.timestamp;
    if (ts != null && ts.millisecondsSinceEpoch > 0) {
      first ??= ts;
      last = ts;
    }
    final text = e.text;
    if (text != null) finalText = text;
    final id = e.toolId;
    if (id == null) return;
    if (e.isEnd) {
      for (var i = steps.length - 1; i >= 0; i--) {
        if (steps[i].id != id) continue;
        final s = steps[i];
        steps[i] = SubagentStep(
          id: s.id,
          name: s.name,
          input: s.input,
          status: e.isError ? ToolStatus.error : ToolStatus.ok,
        );
        break;
      }
      return;
    }
    toolCount++;
    steps.add(SubagentStep(id: id, name: e.toolName ?? '', input: e.input));
    if (steps.length > maxSubagentSteps) {
      steps.removeRange(0, steps.length - maxSubagentSteps);
    }
  }

  int? get durationMs => first == null || last == null
      ? null
      : last!.difference(first!).inMilliseconds;
}

class _Agent {
  _Agent(this.agentId, this.path, this.metaPath)
    : tailer = TranscriptTailer<AgentEvent>(path, SubagentParser());

  final String agentId;
  final String path;
  final String metaPath;
  final TranscriptTailer<AgentEvent> tailer;
  final AgentProgress progress = AgentProgress();

  /// Lo que dice el `.meta.json` (lo escribe Claude Code al terminar).
  bool metaFinished = false;

  Future<void> poll() async {
    for (final e in await tailer.poll()) {
      progress.apply(e);
    }
    try {
      final m = jsonDecode(await File(metaPath).readAsString());
      metaFinished = m is Map && m['finished'] == true;
    } catch (_) {
      // sin meta o a medio escribir
    }
  }

  /// Última modificación del transcript del subagente.
  DateTime? get modified {
    try {
      return File(path).lastModifiedSync();
    } on FileSystemException {
      return null;
    }
  }
}

/// Enlaza las llamadas `Task`/`Agent` de una sesión con los transcripts de
/// sus subagentes y vuelca su actividad en el item de la llamada.
///
/// Claude Code escribe cada subagente en
/// `<sessionId>/subagents/agent-<agentId>.jsonl`, con un `.meta.json` al lado
/// que trae el `toolUseId` de la llamada que lo lanzó. Los hooks de subagente
/// (`agent_id`) solo sirven para sondear antes; el transcript es la fuente.
class SubagentWatcher {
  SubagentWatcher(this.store, this.sessionId, String transcriptPath)
    : dir = p.join(
        p.dirname(transcriptPath),
        p.basenameWithoutExtension(transcriptPath),
        'subagents',
      );

  final SessionStore store;
  final String sessionId;
  final String dir;

  /// Cuánto sin escribir se da un subagente por muerto.
  static const stale = Duration(minutes: 15);

  /// Cuánto se espera el transcript de un `Task` ya cerrado antes de rendirse.
  static const giveUp = Duration(seconds: 30);

  final Map<String, _Agent> _agents = {};
  final Set<String> _done = {};

  Future<void> sync() async {
    final tasks = store.subagentTasks(sessionId);
    if (tasks.every((t) => _done.contains(t.id))) return;
    var scanned = false;
    for (final t in tasks) {
      if (_done.contains(t.id)) continue;
      var agent = _agents[t.id];
      if (agent == null && !scanned) {
        scanned = true;
        _scan();
        agent = _agents[t.id];
      }
      if (agent == null) {
        if (t.status != ToolStatus.running &&
            DateTime.now().toUtc().difference(t.timestamp) > giveUp) {
          _done.add(t.id);
        }
        continue;
      }
      try {
        await agent.poll();
      } catch (e, st) {
        Log.error('subagente ${agent.agentId}', e, st);
        continue;
      }
      final finished = _isFinished(t, agent);
      final info = SubagentInfo(
        agentId: agent.agentId,
        steps: List.of(agent.progress.steps),
        toolCount: agent.progress.toolCount,
        finished: finished,
        durationMs: agent.progress.durationMs,
        finalText: agent.progress.finalText,
      );
      if (t.subagent != info) {
        store.updateItem(
          sessionId,
          t.id,
          (cur) => cur is ToolCallItem ? cur.copyWith(subagent: info) : null,
        );
      }
      if (finished) _done.add(t.id);
    }
  }

  bool _isFinished(ToolCallItem t, _Agent a) {
    if (a.metaFinished) return true;
    final r = t.result ?? '';
    final background =
        t.input['run_in_background'] == true ||
        r.startsWith('Async agent launched') ||
        r.startsWith('Running in the background');
    if (t.status != ToolStatus.running && !background) return true;
    final m = a.modified;
    return m != null && DateTime.now().difference(m) > stale;
  }

  /// Mapea los `.meta.json` del directorio a su agente por `toolUseId`.
  void _scan() {
    final List<FileSystemEntity> files;
    try {
      files = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final f in files) {
      final name = p.basename(f.path);
      if (f is! File || !name.endsWith('.meta.json')) continue;
      final base = name.substring(0, name.length - '.meta.json'.length);
      try {
        final m = jsonDecode(f.readAsStringSync());
        final id = m is Map ? m['toolUseId'] : null;
        if (id is! String || _agents.containsKey(id)) continue;
        _agents[id] = _Agent(
          base.startsWith('agent-') ? base.substring(6) : base,
          p.join(dir, '$base.jsonl'),
          f.path,
        );
      } catch (_) {
        // meta a medio escribir: se verá en el siguiente sondeo
      }
    }
  }
}
