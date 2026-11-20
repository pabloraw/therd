import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_daemon/src/transcript_parser.dart';
import 'package:therd_daemon/src/transcript_tailer.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

List<String> fixtureLines() =>
    File('test/fixtures/transcript.jsonl').readAsLinesSync();

void main() {
  group('TranscriptParser con líneas reales', () {
    final parser = TranscriptParser('sess-1');
    final events = [for (final l in fixtureLines()) ...parser.parseLine(l)];
    final items = [
      for (final e in events)
        if (e is ItemEvent) e.item,
    ];

    test('prompt de usuario, texto, thinking, herramienta y marcadores', () {
      expect(items.whereType<UserPromptItem>(), hasLength(1));
      expect(items.whereType<UserPromptItem>().single.text, contains('moshi'));
      expect(items.whereType<AssistantTextItem>(), isNotEmpty);
      expect(items.whereType<ThinkingItem>(), isNotEmpty);
      final tool = items.whereType<ToolCallItem>().single;
      expect(tool.id, 'toolu_01XuieArsFR9HhTTJKBeWwh1');
      expect(tool.toolName, 'Bash');
      expect(tool.status, ToolStatus.running);
      expect(tool.input['command'], isA<String>());
      final markers = items.whereType<MarkerItem>().toList();
      expect(
        markers.map((m) => m.kind),
        containsAll([MarkerKind.turnEnd, MarkerKind.compact]),
      );
      expect(
        markers.firstWhere((m) => m.kind == MarkerKind.turnEnd).durationMs,
        66314,
      );
    });

    test('descarta isMeta y sidechain', () {
      expect(items.any((i) => i.id == 'sidechain-1'), isFalse);
      expect(
        items.whereType<UserPromptItem>().any(
          (u) => u.text.contains('system-reminder'),
        ),
        isFalse,
      );
    });

    test('extrae el resultado de la herramienta y los metadatos', () {
      final res = events.whereType<ToolResultEvent>().single;
      expect(res.toolUseId, 'toolu_01XuieArsFR9HhTTJKBeWwh1');
      expect(res.isError, isFalse);
      expect(res.result, isNotEmpty);
      final metas = events.whereType<MetaEvent>().toList();
      expect(
        metas.any((m) => m.title == 'Vista Moshi para Claude Code'),
        isTrue,
      );
      expect(metas.any((m) => m.mode == 'auto'), isTrue);
      expect(metas.any((m) => m.model == 'claude-opus-5-5'), isTrue);
    });

    test('empareja tool_use con tool_result en el store', () {
      final store = SessionStore()..upsertSession('sess-1');
      for (final e in events) {
        TranscriptHub.apply(store, 'sess-1', e);
      }
      final tool =
          store.itemById('sess-1', 'toolu_01XuieArsFR9HhTTJKBeWwh1')
              as ToolCallItem;
      expect(tool.status, ToolStatus.ok);
      expect(tool.result, isNotEmpty);
      expect(store.info('sess-1')!.title, 'Vista Moshi para Claude Code');
      expect(store.info('sess-1')!.model, 'claude-opus-5-5');
    });

    test('tolera basura, tipos desconocidos y líneas vacías', () {
      expect(parser.parseLine(''), isEmpty);
      expect(parser.parseLine('{no es json'), isEmpty);
      expect(parser.parseLine('[1,2]'), isEmpty);
      expect(parser.parseLine('{"type":"api-request","x":1}'), isEmpty);
      expect(parser.parseLine('{"type":"futuro","uuid":"z"}'), isEmpty);
    });

    test('tool_result con error y contenido en lista', () {
      final ev = parser.parseLine(
        '{"type":"user","uuid":"u9","message":{"role":"user","content":['
        '{"type":"tool_result","tool_use_id":"t1","is_error":true,'
        '"content":[{"type":"text","text":"boom"}]}]}}',
      );
      final r = ev.whereType<ToolResultEvent>().single;
      expect(r.isError, isTrue);
      expect(r.result, 'boom');
    });

    test('AskUserQuestion y ExitPlanMode no son tarjetas de herramienta', () {
      final ev = parser.parseLine(
        '{"type":"assistant","uuid":"a1","message":{"model":"m","content":['
        '{"type":"tool_use","id":"tq","name":"AskUserQuestion","input":{"questions":['
        '{"question":"¿Cuál?","header":"H","options":[{"label":"A","description":"a"}],"multiSelect":false}]}},'
        '{"type":"tool_use","id":"tp","name":"ExitPlanMode","input":{"plan":"Plan X"}}]}}',
      );
      final items = ev.whereType<ItemEvent>().map((e) => e.item).toList();
      expect(items[0], isA<QuestionItem>());
      expect((items[0] as QuestionItem).questions.single.question, '¿Cuál?');
      expect(items[1], isA<PlanItem>());
      // varios bloques en una línea: ids distintos
      expect(items[0].id, 'tq');
    });
  });

  group('TranscriptTailer', () {
    test('lee por offset, guarda líneas parciales y reanuda', () async {
      final dir = makeTemp('tail');
      final file = File('${dir.path}/s.jsonl');
      final tailer = TranscriptTailer(file.path, TranscriptParser('s'));
      const l1 =
          '{"type":"user","uuid":"u1","message":{"role":"user","content":"hola"}}';
      const l2 =
          '{"type":"user","uuid":"u2","message":{"role":"user","content":"adiós ñ"}}';

      expect(await tailer.poll(), isEmpty); // el archivo no existe

      file.writeAsStringSync('$l1\n${l2.substring(0, 30)}');
      var ev = await tailer.poll();
      expect(ev.whereType<ItemEvent>().map((e) => e.item.id), ['u1']);

      file.writeAsStringSync(l2.substring(30), mode: FileMode.append);
      expect(await tailer.poll(), isEmpty); // aún sin salto de línea
      file.writeAsStringSync('\n', mode: FileMode.append);
      ev = await tailer.poll();
      final item = ev.whereType<ItemEvent>().single.item as UserPromptItem;
      expect(item.text, 'adiós ñ');
      expect(await tailer.poll(), isEmpty);
      dir.deleteSync(recursive: true);
    });

    test('hub: deduplica al releer y el histórico queda en el store', () async {
      final dir = makeTemp('hub');
      final file = File('${dir.path}/sess-1.jsonl');
      file.writeAsStringSync('${fixtureLines().join('\n')}\n');
      final store = SessionStore();
      final hub = TranscriptHub(store);
      hub.attach('sess-1', file.path);
      await hub.pollNow('sess-1');
      final n = store.itemsOf('sess-1').length;
      expect(n, greaterThan(5));
      // Se trunca y reescribe: no duplica por uuid.
      file.writeAsStringSync('${fixtureLines().join('\n')}\n');
      await hub.pollNow('sess-1');
      expect(store.itemsOf('sess-1').length, n);
      expect(store.itemsOf('sess-1').map((e) => e.seq).toList(), [
        for (var i = 1; i <= n; i++) i,
      ]);
      await hub.stop();
      dir.deleteSync(recursive: true);
    });

    test('encodeProjectDir y findTranscript', () {
      expect(
        encodeProjectDir('/home/user/dev/lab/therd'),
        '-home-user-dev-lab-therd',
      );
      final dir = makeTemp('find');
      final proj = Directory('${dir.path}/-tmp-x')..createSync();
      File('${proj.path}/abc.jsonl').writeAsStringSync('');
      expect(
        findTranscript(dir.path, 'abc', ['/tmp/x']),
        '${proj.path}/abc.jsonl',
      );
      expect(
        findTranscript(dir.path, 'abc', ['/otro']),
        '${proj.path}/abc.jsonl',
      );
      expect(findTranscript(dir.path, 'nada', ['/tmp/x']), isNull);
      dir.deleteSync(recursive: true);
    });
  });
}
