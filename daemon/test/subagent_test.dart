import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/session_store.dart';
import 'package:therd_daemon/src/subagent.dart';
import 'package:therd_daemon/src/transcript_tailer.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

const _fx = 'test/fixtures/subagent';

/// Copia el fixture a una carpeta temporal con la estructura de Claude Code.
Directory copyFixture() {
  final dir = makeTemp('sub');
  Directory('${dir.path}/sess-sub/subagents').createSync(recursive: true);
  File('$_fx/sess-sub.jsonl').copySync('${dir.path}/sess-sub.jsonl');
  for (final n in ['agent-aaa111.jsonl', 'agent-aaa111.meta.json']) {
    File(
      '$_fx/sess-sub/subagents/$n',
    ).copySync('${dir.path}/sess-sub/subagents/$n');
  }
  return dir;
}

void main() {
  group('SubagentParser y AgentProgress', () {
    final parser = SubagentParser();
    final progress = AgentProgress();
    for (final l in File(
      '$_fx/sess-sub/subagents/agent-aaa111.jsonl',
    ).readAsLinesSync()) {
      parser.parseLine(l).forEach(progress.apply);
    }

    test('herramientas con su estado, texto final y duración', () {
      expect(progress.toolCount, 3);
      expect(progress.steps.map((s) => s.name), ['Grep', 'Read', 'Bash']);
      expect(progress.steps.map((s) => s.status), [
        ToolStatus.ok,
        ToolStatus.ok,
        ToolStatus.error,
      ]);
      expect(progress.finalText, contains('lib/api/client.dart'));
      expect(progress.durationMs, 8000);
    });

    test('el input se reduce a lo que pinta una fila', () {
      expect(progress.steps.first.input, {
        'pattern': 'HttpClient',
        'path': '/proyecto/lib',
      });
      expect(progress.steps[1].input, {
        'file_path': '/proyecto/lib/api/client.dart',
      });
    });

    test('recorta a las últimas herramientas pero cuenta todas', () {
      final p = AgentProgress();
      for (var i = 0; i < 50; i++) {
        p.apply(AgentEvent(toolId: 't$i', toolName: 'Read'));
        p.apply(AgentEvent(toolId: 't$i', isEnd: true));
      }
      expect(p.toolCount, 50);
      expect(p.steps, hasLength(maxSubagentSteps));
      expect(p.steps.last.id, 't49');
      expect(p.steps.first.id, 't${50 - maxSubagentSteps}');
    });

    test('líneas rotas o de otro tipo no lanzan', () {
      expect(parser.parseLine('{roto'), isEmpty);
      expect(parser.parseLine('{"type":"attachment"}'), isEmpty);
      expect(parser.parseLine(''), isEmpty);
    });
  });

  group('SubagentWatcher', () {
    test('enlaza el Agent con su transcript y no crea items nuevos', () async {
      final dir = copyFixture();
      final store = SessionStore();
      final hub = TranscriptHub(store);
      final events = <StoreEvent>[];
      store.events.listen(events.add);
      hub.attach('sess-sub', '${dir.path}/sess-sub.jsonl');
      await hub.pollNow('sess-sub');
      await hub.pollNow('sess-sub');

      final items = store.itemsOf('sess-sub');
      final task = items.whereType<ToolCallItem>().single;
      expect(task.toolName, 'Agent');
      expect(task.status, ToolStatus.ok);
      final sub = task.subagent!;
      expect(sub.agentId, 'aaa111');
      expect(sub.finished, isTrue);
      expect(sub.toolCount, 3);
      expect(sub.steps, hasLength(3));
      expect(sub.finalText, contains('client.dart'));

      // Ni items suyos ni seq: solo un item.update del Agent.
      expect(items.map((i) => i.id), isNot(contains('s-3')));
      expect(store.info('sess-sub')!.lastSeq, items.length);
      expect(
        events.whereType<ItemAppended>().length,
        items.length,
        reason: 'los pasos del subagente no se añaden como items',
      );
      await hub.stop();
      dir.deleteSync(recursive: true);
    });

    test('en vivo: sigue trabajando hasta que termina', () async {
      final dir = copyFixture();
      // Main sin el resultado del Agent, subagente a medias y sin finished.
      final main = File('${dir.path}/sess-sub.jsonl');
      final lines = main.readAsLinesSync();
      main.writeAsStringSync('${lines.take(3).join('\n')}\n');
      final agent = File('${dir.path}/sess-sub/subagents/agent-aaa111.jsonl');
      final all = agent.readAsLinesSync();
      agent.writeAsStringSync('${all.take(4).join('\n')}\n');
      final meta = File(
        '${dir.path}/sess-sub/subagents/agent-aaa111.meta.json',
      );
      final metaJson = jsonDecode(meta.readAsStringSync()) as Map;
      meta.writeAsStringSync(jsonEncode({...metaJson, 'finished': false}));

      final store = SessionStore();
      final hub = TranscriptHub(store);
      hub.attach('sess-sub', main.path);
      await hub.pollNow('sess-sub');
      var task = store.itemsOf('sess-sub').whereType<ToolCallItem>().single;
      expect(task.status, ToolStatus.running);
      expect(task.subagent!.finished, isFalse);
      expect(task.subagent!.steps.single.name, 'Grep');
      expect(task.subagent!.steps.single.status, ToolStatus.running);

      // Llega el resto y el meta marca el final.
      agent.writeAsStringSync('${all.join('\n')}\n');
      meta.writeAsStringSync(jsonEncode({...metaJson, 'finished': true}));
      await hub.pollNow('sess-sub');
      task = store.itemsOf('sess-sub').whereType<ToolCallItem>().single;
      expect(task.subagent!.finished, isTrue);
      expect(task.subagent!.toolCount, 3);
      await hub.stop();
      dir.deleteSync(recursive: true);
    });

    test(
      'sin transcript del subagente la tarjeta se queda como estaba',
      () async {
        final dir = copyFixture();
        Directory('${dir.path}/sess-sub').deleteSync(recursive: true);
        final store = SessionStore();
        final hub = TranscriptHub(store);
        hub.attach('sess-sub', '${dir.path}/sess-sub.jsonl');
        await hub.pollNow('sess-sub');
        final task = store.itemsOf('sess-sub').whereType<ToolCallItem>().single;
        expect(task.subagent, isNull);
        expect(task.status, ToolStatus.ok);
        await hub.stop();
        dir.deleteSync(recursive: true);
      },
    );
  });
}
