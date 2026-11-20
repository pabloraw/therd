import 'images.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart';
import 'session_store.dart';
import 'subagent.dart';
import 'transcript_parser.dart';

/// Lee un transcript JSONL por offset, de forma incremental y tolerante a
/// líneas parciales (se guardan hasta que llega el salto de línea).
class TranscriptTailer<T> {
  TranscriptTailer(
    this.path,
    this.parser, {
    this.maxInitialBytes = 16 * 1024 * 1024,
  });

  final String path;
  final LineParser<T> parser;

  /// Si el archivo es mayor, la primera lectura solo toma el final.
  final int maxInitialBytes;

  int _offset = 0;
  List<int> _partial = [];
  bool _first = true;

  int get offset => _offset;

  /// Lee lo nuevo y devuelve los eventos interpretados.
  Future<List<T>> poll() async {
    final file = File(path);
    final int len;
    try {
      len = await file.length();
    } on FileSystemException {
      return const [];
    }
    if (len < _offset) {
      // El archivo se truncó o se reescribió: se relee desde el principio.
      _offset = 0;
      _partial = [];
      _first = true;
    }
    if (len == _offset) return const [];

    var start = _offset;
    var skipFirstLine = false;
    if (_first && len > maxInitialBytes) {
      start = len - maxInitialBytes;
      skipFirstLine = true;
    }
    _first = false;

    final RandomAccessFile raf;
    try {
      raf = await file.open();
    } on FileSystemException {
      return const [];
    }
    List<int> chunk;
    try {
      await raf.setPosition(start);
      chunk = await raf.read(len - start);
    } finally {
      await raf.close();
    }
    _offset = start + chunk.length;

    final bytes = <int>[..._partial, ...chunk];
    final events = <T>[];
    var lineStart = 0;
    if (skipFirstLine) {
      final nl = bytes.indexOf(10);
      lineStart = nl < 0 ? bytes.length : nl + 1;
    }
    for (var i = lineStart; i < bytes.length; i++) {
      if (bytes[i] != 10) continue;
      final line = utf8.decode(
        bytes.sublist(lineStart, i),
        allowMalformed: true,
      );
      events.addAll(parser.parseLine(line));
      lineStart = i + 1;
    }
    _partial = bytes.sublist(lineStart);
    return events;
  }
}

/// Gestiona un tailer por sesión y vuelca sus eventos en el [SessionStore].
class TranscriptHub {
  TranscriptHub(
    this.store, {
    this.pollInterval = const Duration(milliseconds: 500),
    this.images,
  });

  final SessionStore store;

  /// Dónde se guardan las imágenes de los transcripts.
  final ImageStore? images;
  final Duration pollInterval;

  final Map<String, TranscriptTailer<TranscriptEvent>> _tailers = {};
  final Map<String, SubagentWatcher> _subagents = {};
  final Map<String, Future<void>> _chain = {};
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(pollInterval, (_) => pollAll());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await Future.wait(_chain.values);
  }

  bool isAttached(String sessionId) => _tailers.containsKey(sessionId);

  /// Asocia (o cambia) el transcript de una sesión. La primera lectura
  /// reconstruye el histórico.
  void attach(String sessionId, String path) {
    final cur = _tailers[sessionId];
    if (cur != null && cur.path == path) return;
    _tailers[sessionId] = TranscriptTailer(
      path,
      TranscriptParser(sessionId, images: images),
    );
    _subagents[sessionId] = SubagentWatcher(store, sessionId, path);
    store.upsertSession(sessionId, transcriptPath: path);
    unawaited(pollNow(sessionId));
  }

  void detach(String sessionId) {
    _tailers.remove(sessionId);
    _subagents.remove(sessionId);
    _chain.remove(sessionId);
  }

  /// Sondea ahora una sesión (serializado con otros sondeos de la misma).
  Future<void> pollNow(String sessionId) {
    final t = _tailers[sessionId];
    if (t == null) return Future.value();
    final prev = _chain[sessionId] ?? Future.value();
    final next = prev.then((_) => _pollOne(sessionId, t));
    _chain[sessionId] = next;
    return next;
  }

  Future<void> pollAll() =>
      Future.wait([for (final id in _tailers.keys.toList()) pollNow(id)]);

  Future<void> _pollOne(
    String sessionId,
    TranscriptTailer<TranscriptEvent> t,
  ) async {
    try {
      final events = await t.poll();
      for (final e in events) {
        apply(store, sessionId, e);
      }
      await _subagents[sessionId]?.sync();
    } catch (e, st) {
      Log.error('transcript ${p.basename(t.path)}', e, st);
    }
  }

  /// Aplica un evento del parser al store.
  static void apply(SessionStore store, String sessionId, TranscriptEvent e) {
    switch (e) {
      case ItemEvent():
        store.ingest(sessionId, e.item);
      case ToolResultEvent():
        store.completeTool(
          sessionId,
          e.toolUseId,
          isError: e.isError,
          result: e.result,
          timestamp: e.timestamp,
          images: e.images,
        );
      case MetaEvent():
        store.updateMeta(
          sessionId,
          title: e.title,
          mode: e.mode,
          model: e.model,
          branch: e.branch,
          contextTokens: e.contextTokens,
        );
    }
  }
}

/// Ruta esperada del transcript de una sesión de Claude Code.
String expectedTranscriptPath(
  String projectsDir,
  String cwd,
  String sessionId,
) => p.join(projectsDir, encodeProjectDir(cwd), '$sessionId.jsonl');

/// Codifica un cwd como lo hace Claude Code: no alfanuméricos a '-'.
String encodeProjectDir(String cwd) =>
    cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-');

/// Busca el transcript de una sesión: ruta esperada con cada cwd candidato
/// y, si no existe, una búsqueda en todos los directorios de proyectos.
String? findTranscript(
  String projectsDir,
  String sessionId,
  Iterable<String?> cwds,
) {
  for (final c in cwds) {
    if (c == null || c.isEmpty) continue;
    final path = expectedTranscriptPath(projectsDir, c, sessionId);
    if (File(path).existsSync()) return path;
  }
  try {
    for (final d in Directory(projectsDir).listSync(followLinks: false)) {
      if (d is! Directory) continue;
      final path = p.join(d.path, '$sessionId.jsonl');
      if (File(path).existsSync()) return path;
    }
  } on FileSystemException {
    // sin directorio de proyectos
  }
  return null;
}
