import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:therd_protocol/protocol.dart';

import 'chat_image.dart';
import 'chat_items.dart' show TherdMarkdown;
import 'theme.dart';

String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

String _baseName(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Resumen de una línea de la llamada, para la cabecera de la fila.
String toolSummary(String tool, Map<String, dynamic> input) {
  String firstLine(String s) => s.trim().split('\n').first;
  switch (tool) {
    case 'Bash':
      return firstLine(_str(input['command']));
    case 'Read':
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
      return _str(input['file_path'] ?? input['notebook_path']);
    case 'Grep':
      final path = _str(input['path']);
      return path.isEmpty
          ? _str(input['pattern'])
          : '${_str(input['pattern'])} en ${_baseName(path)}';
    case 'Glob':
      return _str(input['pattern']);
    case 'Task':
    case 'Agent':
      final d = _str(input['description']);
      return d.isNotEmpty ? d : _str(input['subagent_type']);
    case 'TodoWrite':
      final todos = input['todos'];
      return todos is List ? '${todos.length} tareas' : '';
    case 'WebFetch':
      return _str(input['url']);
    case 'WebSearch':
      return _str(input['query']);
  }
  for (final v in input.values) {
    if (v is String && v.isNotEmpty) return firstLine(v);
  }
  return '';
}

/// Nombre corto para la cabecera: `mcp__claude_ai_Gmail__get_thread` pasa a
/// `Gmail: get_thread`; el resto se queda igual.
String toolDisplayName(String tool) {
  if (!tool.startsWith('mcp__')) return tool;
  final parts = tool.substring(5).split('__');
  if (parts.length < 2) return tool;
  var server = parts.first;
  if (server.startsWith('claude_ai_')) server = server.substring(10);
  server = server.replaceAll('_', ' ');
  return '$server: ${parts.sublist(1).join('__')}';
}

IconData toolIcon(String tool) => switch (tool) {
  'Bash' => Icons.terminal,
  'Read' => Icons.description_outlined,
  'Write' => Icons.note_add_outlined,
  'Edit' || 'MultiEdit' || 'NotebookEdit' => Icons.edit_outlined,
  'Grep' => Icons.search,
  'Glob' => Icons.folder_open_outlined,
  'Task' || 'Agent' => Icons.smart_toy_outlined,
  'TodoWrite' => Icons.checklist,
  'WebFetch' || 'WebSearch' => Icons.public,
  _ => Icons.build_outlined,
};

String formatDuration(int ms) {
  if (ms < 1000) return '$ms ms';
  final s = ms / 1000;
  if (s < 60) return '${s.toStringAsFixed(s < 10 ? 1 : 0)} s';
  return '${s ~/ 60} min ${(s % 60).round()} s';
}

/// Código y diffs: Geist Mono 12 con interlineado 1,55.
TextStyle _codeStyle([Color? color]) =>
    mono(size: 12, color: color).copyWith(height: 1.55);

/// Llamada que lanza un subagente (`Task`, o `Agent` en Claude Code reciente).
bool isSubagentCall(ChatItem i) =>
    i is ToolCallItem && (i.toolName == 'Task' || i.toolName == 'Agent');

/// Es un item que va dentro de una tarjeta de herramientas. Los subagentes
/// tienen su propia tarjeta y cortan el grupo.
bool isToolGroupItem(ChatItem i) =>
    (i is ToolCallItem && !isSubagentCall(i)) || i is ThinkingItem;

/// Tarjeta única con las herramientas (y el «Pensando») consecutivas: una
/// fila por item, separadas por `line`; al tocar una se despliega su detalle.
class ToolGroupCard extends StatelessWidget {
  const ToolGroupCard({super.key, required this.items});

  final List<ChatItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: Tk.brCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Container(height: 1, color: c.line),
            switch (items[i]) {
              // Las capturas se ven sin desplegar la herramienta.
              ToolCallItem t when t.images.isNotEmpty => Column(
                key: ValueKey(t.id),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ToolRow(item: t),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: ChatImages(ids: t.images),
                  ),
                ],
              ),
              ToolCallItem t => ToolRow(key: ValueKey(t.id), item: t),
              ThinkingItem t => _ThinkingRow(key: ValueKey(t.id), text: t.text),
              _ => const SizedBox.shrink(),
            },
          ],
        ],
      ),
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.onTap,
    required this.children,
    this.background,
  });

  final VoidCallback onTap;
  final List<Widget> children;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: children),
          ),
        ),
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({required this.open});
  final bool open;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? 0.5 : 0,
    duration: const Duration(milliseconds: 150),
    child: Icon(Icons.expand_more, size: 16, color: context.tc.muted),
  );
}

class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow({super.key, required this.text});
  final String text;

  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RowShell(
          onTap: () => setState(() => _open = !_open),
          children: [
            Icon(Icons.auto_awesome_outlined, size: 15, color: c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Pensando',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.muted,
                ),
              ),
            ),
            _Chevron(open: _open),
          ],
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              widget.text,
              style: TextStyle(fontSize: 14, height: 1.55, color: c.muted),
            ),
          ),
      ],
    );
  }
}

/// Una herramienta dentro de la tarjeta: cabecera de una línea y detalle.
class ToolRow extends StatefulWidget {
  const ToolRow({super.key, required this.item});

  final ToolCallItem item;

  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final c = context.tc;
    final failed = item.status == ToolStatus.error || item.isError;
    final running = item.status == ToolStatus.running;
    final isTodo = item.toolName == 'TodoWrite';
    final name = isTodo ? 'Tareas' : toolDisplayName(item.toolName);
    final summary = isTodo
        ? _todoSummary(item.input['todos'])
        : toolSummary(item.toolName, item.input);

    final Widget status;
    if (running) {
      status = const Spinner(size: 14, color: kDotWork, stroke: 2.5);
    } else if (failed) {
      status = Text(
        'Error',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: c.waitFg,
        ),
      );
    } else {
      status = Icon(Icons.check, size: 14, color: c.okFg);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RowShell(
          onTap: () => setState(() => _open = !_open),
          background: failed ? c.waitSoft : null,
          children: [
            Icon(
              toolIcon(item.toolName),
              size: 15,
              color: failed ? c.waitFg : c.text,
            ),
            const SizedBox(width: 10),
            // Un nombre largo (MCP) no debe desbordar la fila.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(size: 12, color: c.muted),
              ),
            ),
            if (item.durationMs != null && !running) ...[
              const SizedBox(width: 10),
              Text(
                formatDuration(item.durationMs!),
                style: mono(size: 11, color: c.muted),
              ),
            ],
            const SizedBox(width: 10),
            status,
            const SizedBox(width: 6),
            _Chevron(open: _open),
          ],
        ),
        if (_open)
          Container(
            color: failed ? c.waitSoft : null,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ToolBody(item: item),
          ),
      ],
    );
  }
}

String _todoSummary(Object? todos) {
  if (todos is! List) return '';
  final done = todos.whereType<Map>().where((t) => t['status'] == 'completed');
  return '${done.length} de ${todos.length} hechas';
}

/// Contenido expandido, específico para cada herramienta.
class ToolBody extends StatelessWidget {
  const ToolBody({super.key, required this.item});

  final ToolCallItem item;

  @override
  Widget build(BuildContext context) {
    final input = item.input;
    final children = <Widget>[];
    // Herramientas de edición y lectura solo muestran el resultado si falló.
    var showResult = true;

    switch (item.toolName) {
      case 'Bash':
        final d = _str(input['description']);
        if (d.isNotEmpty) children.add(_Caption(d));
        children.add(_CodeBox(text: '\$ ${_str(input['command'])}'));
      case 'Edit':
        showResult = item.isError;
        children
          ..add(_PathLine(_str(input['file_path'])))
          ..add(
            DiffView(
              oldText: _str(input['old_string']),
              newText: _str(input['new_string']),
            ),
          );
      case 'MultiEdit':
        showResult = item.isError;
        children.add(_PathLine(_str(input['file_path'])));
        final edits = input['edits'];
        if (edits is List) {
          for (final e in edits.whereType<Map>()) {
            children.add(
              DiffView(
                oldText: _str(e['old_string']),
                newText: _str(e['new_string']),
              ),
            );
          }
        }
      case 'Write':
        showResult = item.isError;
        children.add(_PathLine(_str(input['file_path'])));
        final content = _str(input['content']);
        if (content.isNotEmpty) {
          children.add(_CodeBox(text: _clip(content, 30)));
        }
      case 'Read':
        showResult = item.isError;
        children.add(_PathLine(_str(input['file_path'])));
        final off = input['offset'];
        final lim = input['limit'];
        if (off != null || lim != null) {
          children.add(
            _Caption(
              'Desde la línea ${off ?? 1}, límite ${lim ?? 'sin límite'}',
            ),
          );
        }
      case 'Grep':
      case 'Glob':
        children.add(_CodeBox(text: _str(input['pattern'])));
        final path = _str(input['path']);
        if (path.isNotEmpty) children.add(_Caption('En $path'));
        final glob = _str(input['glob']);
        if (glob.isNotEmpty) children.add(_Caption('Filtro $glob'));
      case 'Task':
      case 'Agent':
        final type = _str(input['subagent_type']);
        children.add(_Caption(type.isEmpty ? 'Subagente' : 'Subagente: $type'));
        final d = _str(input['description']);
        if (d.isNotEmpty) {
          children.add(
            Text(
              d,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          );
        }
        final p = _str(input['prompt']);
        if (p.isNotEmpty) children.add(_CodeBox(text: _clip(p, 20)));
      case 'TodoWrite':
        showResult = item.isError;
        children.add(TodoList(todos: input['todos']));
      default:
        children.add(
          _CodeBox(text: const JsonEncoder.withIndent('  ').convert(input)),
        );
    }

    final result = item.result;
    if (showResult && result != null && result.isNotEmpty) {
      children.add(_Caption(item.isError ? 'Error' : 'Salida'));
      children.add(_CodeBox(text: _clip(result, 60), error: item.isError));
    } else if (showResult && item.status == ToolStatus.running) {
      children.add(const _Caption('Ejecutando…'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }
}

String _clip(String s, int maxLines) {
  final lines = s.split('\n');
  if (lines.length <= maxLines) return s;
  return '${lines.take(maxLines).join('\n')}\n… (${lines.length - maxLines} líneas más)';
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 13, color: context.tc.muted));
}

class _PathLine extends StatelessWidget {
  const _PathLine(this.path);
  final String path;

  @override
  Widget build(BuildContext context) => Text(
    path,
    style: mono(size: 12, weight: FontWeight.w500, color: context.tc.text),
  );
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.code,
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(text, style: _codeStyle(error ? c.delFg : c.text)),
        ),
      ),
    );
  }
}

/// Mini diff sobre `code`: líneas antiguas con «-» en delSoft/delFg, nuevas
/// con «+» en addSoft/addFg.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.oldText, required this.newText});

  final String oldText;
  final String newText;

  static const _maxLines = 30;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    Widget block(String text, String prefix, Color bg, Color fg) {
      if (text.isEmpty) return const SizedBox.shrink();
      final lines = text.split('\n');
      final shown = lines.take(_maxLines).toList();
      return Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in shown) Text('$prefix $l', style: _codeStyle(fg)),
            if (lines.length > _maxLines)
              Text(
                '… (${lines.length - _maxLines} líneas más)',
                style: _codeStyle(c.muted),
              ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.code,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              block(oldText, '-', c.delSoft, c.delFg),
              block(newText, '+', c.addSoft, c.addFg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Checklist de TodoWrite.
class TodoList extends StatelessWidget {
  const TodoList({super.key, required this.todos});

  final Object? todos;

  @override
  Widget build(BuildContext context) {
    final list = todos is List
        ? (todos as List).whereType<Map>().toList()
        : const <Map>[];
    final c = context.tc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TodoBox(status: _str(t['status'])),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _str(
                      t['status'] == 'in_progress' && t['activeForm'] != null
                          ? t['activeForm']
                          : t['content'],
                    ),
                    style: TextStyle(
                      fontSize: 13,
                      color: t['status'] == 'completed' ? c.muted : c.text,
                      decoration: t['status'] == 'completed'
                          ? TextDecoration.lineThrough
                          : null,
                      fontWeight: t['status'] == 'in_progress'
                          ? FontWeight.w600
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _plural(int n) => n == 1 ? '1 herramienta' : '$n herramientas';

/// Tarjeta de un subagente: tipo y descripción, estado y, al desplegarla, su
/// prompt, las herramientas que va usando y su respuesta.
class SubagentCard extends StatefulWidget {
  const SubagentCard({super.key, required this.item});

  final ToolCallItem item;

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final sub = item.subagent;
    final c = context.tc;
    final failed = item.status == ToolStatus.error || item.isError;
    // En segundo plano el Task se cierra al lanzarlo: manda el subagente.
    final working = sub != null
        ? !sub.finished
        : item.status == ToolStatus.running;
    final type = _str(item.input['subagent_type']);
    final description = _str(item.input['description']);
    final prompt = _str(item.input['prompt']);
    final duration = sub?.durationMs ?? item.durationMs;
    final steps = sub?.steps ?? const <SubagentStep>[];
    final count = sub?.toolCount ?? 0;
    final answer = (sub?.finalText?.isNotEmpty ?? false)
        ? sub!.finalText!
        : (item.result ?? '');

    final String label;
    final Color labelColor;
    if (failed) {
      label = 'Error';
      labelColor = c.waitFg;
    } else if (working) {
      label = 'Trabajando';
      labelColor = kDotWork;
    } else {
      label = 'Hecho';
      labelColor = c.okFg;
    }
    // Sin desplegar: lo último que hace, o cuántas herramientas ha usado.
    final live = working && steps.isNotEmpty
        ? '${toolDisplayName(steps.last.name)} '
              '${toolSummary(steps.last.name, steps.last.input)}'
        : (count > 0 ? _plural(count) : '');

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: failed ? c.waitFg : c.line),
        borderRadius: Tk.brCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: failed ? c.waitSoft : Colors.transparent,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.smart_toy_outlined,
                        size: 16,
                        color: failed ? c.waitFg : c.text,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            type.isEmpty ? 'Subagente' : type,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (description.isNotEmpty)
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: c.muted),
                            ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              if (working) ...[
                                const Spinner(
                                  size: 12,
                                  color: kDotWork,
                                  stroke: 2.5,
                                ),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: labelColor,
                                ),
                              ),
                              if (duration != null) ...[
                                const SizedBox(width: 8),
                                Text(
                                  formatDuration(duration),
                                  style: mono(size: 11, color: c.muted),
                                ),
                              ],
                              if (live.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    live,
                                    key: const ValueKey('subagent-live'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono(size: 12, color: c.muted),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: _Chevron(open: _open),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line)),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (prompt.isNotEmpty) ...[
                    const _Caption('Prompt'),
                    const SizedBox(height: 6),
                    _CodeBox(text: _clip(prompt, 8)),
                    const SizedBox(height: 10),
                  ],
                  if (steps.isNotEmpty) ...[
                    _Caption(
                      count > steps.length
                          ? 'Herramientas, las últimas ${steps.length} de $count'
                          : 'Herramientas',
                    ),
                    const SizedBox(height: 6),
                    _SubagentSteps(steps: steps),
                    const SizedBox(height: 10),
                  ],
                  if (answer.isNotEmpty && !working) ...[
                    _Caption(failed ? 'Error' : 'Respuesta'),
                    const SizedBox(height: 6),
                    if (failed)
                      _CodeBox(text: _clip(answer, 30), error: true)
                    else
                      TherdMarkdown(answer, fontSize: 14),
                  ] else if (working)
                    const _Caption('Sigue trabajando…'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Herramientas del subagente: filas compactas, sin detalle.
class _SubagentSteps extends StatelessWidget {
  const _SubagentSteps({required this.steps});

  final List<SubagentStep> steps;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(Tk.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) Container(height: 1, color: c.line),
            _StepRow(key: ValueKey(steps[i].id), step: steps[i]),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({super.key, required this.step});

  final SubagentStep step;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final failed = step.status == ToolStatus.error;
    final Widget status = switch (step.status) {
      ToolStatus.running => const Spinner(
        size: 12,
        color: kDotWork,
        stroke: 2.5,
      ),
      ToolStatus.error => Icon(Icons.close, size: 13, color: c.waitFg),
      ToolStatus.ok => Icon(Icons.check, size: 13, color: c.okFg),
    };
    return Container(
      color: failed ? c.waitSoft : null,
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Icon(
            toolIcon(step.name),
            size: 14,
            color: failed ? c.waitFg : c.text,
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              toolDisplayName(step.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              toolSummary(step.name, step.input),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(size: 11, color: c.muted),
            ),
          ),
          const SizedBox(width: 8),
          status,
        ],
      ),
    );
  }
}

class _TodoBox extends StatelessWidget {
  const _TodoBox({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final done = status == 'completed';
    return Container(
      width: 16,
      height: 16,
      margin: const EdgeInsets.only(top: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: done ? c.text : null,
        border: done
            ? null
            : Border.all(
                color: status == 'in_progress' ? kDotWork : c.muted,
                width: 2,
              ),
      ),
      child: done ? Icon(Icons.check, size: 12, color: c.bg) : null,
    );
  }
}
