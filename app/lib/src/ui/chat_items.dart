import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:therd_protocol/protocol.dart';

import '../data/app_state.dart' show isLocalItem;
import 'chat_image.dart';
import 'theme.dart';
import 'tool_card.dart';

/// Texto legible de la resolución de un pendiente (null = sigue pendiente).
String resolutionLabel(String? r) => switch (r) {
  null => 'Pendiente',
  Resolution.allowed => 'Permitido',
  Resolution.denied => 'Denegado',
  Resolution.answered => 'Contestada',
  Resolution.released => 'Contestado en el PC',
  Resolution.timeout => 'Sin respuesta, pasó al PC',
  Resolution.cancelled => 'Cancelado',
  _ => r,
};

/// Fila de la lista del chat: un item suelto o un grupo de herramientas
/// consecutivas (ToolCallItem y ThinkingItem) que se pinta como una tarjeta.
class ChatRow {
  const ChatRow(this.items);

  final List<ChatItem> items;

  bool get isGroup => isToolGroupItem(items.first);

  /// Estable mientras el grupo crece: es el id del primer item.
  String get id => items.first.id;
}

/// Agrupa los items (en orden cronológico) en filas del chat.
List<ChatRow> groupChatItems(List<ChatItem> items) {
  final rows = <ChatRow>[];
  var run = <ChatItem>[];
  void flush() {
    if (run.isEmpty) return;
    rows.add(ChatRow(run));
    run = <ChatItem>[];
  }

  for (final item in items) {
    if (isToolGroupItem(item)) {
      run.add(item);
    } else {
      flush();
      rows.add(ChatRow([item]));
    }
  }
  flush();
  return rows;
}

/// Markdown de la guía: 16 px, interlineado 1,6, código inline en mono 13
/// sobre `cont` y bloques de código sobre `code`.
class TherdMarkdown extends StatelessWidget {
  const TherdMarkdown(this.data, {super.key, this.fontSize = 16});

  final String data;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return GptMarkdown(
      data,
      style: TextStyle(fontSize: fontSize, height: 1.6, color: c.text),
      // Código inline: Geist Mono 13 sobre `cont`.
      inlineCodeStyle: InlineCodeStyle(
        fontFamily: kMono,
        fontSizeFactor: 13 / fontSize,
        color: c.text,
        backgroundColor: c.cont,
        borderWidth: 0,
        borderRadius: const Radius.circular(6),
        // El relleno horizontal se pinta fuera del texto y taparía los
        // espacios de alrededor: solo 2 px.
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      ),
      codeBuilder: (context, name, code, closed) => Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: c.code,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            code,
            style: mono(size: 12, color: c.text).copyWith(height: 1.55),
          ),
        ),
      ),
    );
  }
}

/// Widget de una fila del chat (un item suelto o un grupo de herramientas).
class ChatRowView extends StatelessWidget {
  const ChatRowView({super.key, required this.row});

  final ChatRow row;

  @override
  Widget build(BuildContext context) => row.isGroup
      ? ToolGroupCard(items: row.items)
      : ChatItemView(item: row.items.first);
}

/// Widget de un item del chat según su tipo.
class ChatItemView extends StatelessWidget {
  const ChatItemView({super.key, required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserPromptItem i => _UserBlock(
        text: i.text,
        images: i.images,
        sending: isLocalItem(i),
      ),
      AssistantTextItem i => TherdMarkdown(i.text),
      ThinkingItem i => ToolGroupCard(items: [i]),
      ToolCallItem i when isSubagentCall(i) => SubagentCard(item: i),
      ToolCallItem i => ToolGroupCard(items: [i]),
      PermissionItem i => _PermissionRecord(item: i),
      QuestionItem i => _QuestionRecord(item: i),
      PlanItem i => _PlanRecord(item: i),
      MarkerItem i => _Marker(item: i),
      UnknownItem _ => const SizedBox.shrink(),
    };
  }
}

class _UserBlock extends StatelessWidget {
  const _UserBlock({
    required this.text,
    this.images = const [],
    this.sending = false,
  });
  final String text;
  final List<String> images;

  /// Enviado desde el móvil y aún sin confirmar por el transcript.
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final label = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: c.muted,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: c.cont, borderRadius: Tk.brCard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Tú', style: label),
              if (sending) ...[
                const Spacer(),
                Text(
                  'Enviando',
                  style: label.copyWith(
                    fontWeight: FontWeight.w400,
                    color: c.faint,
                  ),
                ),
              ],
            ],
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              text,
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: sending ? c.muted : c.text,
              ),
            ),
          ],
          if (images.isNotEmpty) ...[
            const SizedBox(height: 8),
            ChatImages(ids: images),
          ],
        ],
      ),
    );
  }
}

class _Marker extends StatelessWidget {
  const _Marker({required this.item});
  final MarkerItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final isError = item.kind == MarkerKind.error;
    var text = item.text.trim();
    if (text.isEmpty) {
      text = switch (item.kind) {
        MarkerKind.compact => 'Conversación compactada',
        MarkerKind.turnEnd =>
          item.durationMs == null
              ? 'Turno terminado'
              : 'Turno terminado (${formatDuration(item.durationMs!)})',
        MarkerKind.error => 'Error',
        MarkerKind.other => '',
      };
    }
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 12, color: isError ? c.waitFg : c.faint),
    );
  }
}

/// Fila de historial para permisos, preguntas y planes ya mostrados: título
/// con elipsis a la izquierda y desenlace a la derecha.
class _Record extends StatelessWidget {
  const _Record({required this.title, required this.resolution, this.body});

  final String title;
  final String? resolution;
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final pending = resolution == null;
    final Widget outcome;
    if (pending) {
      outcome = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: kDotWait,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Pendiente',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: c.waitFg,
            ),
          ),
        ],
      );
    } else {
      final good =
          resolution == Resolution.allowed || resolution == Resolution.answered;
      final color = switch (resolution) {
        Resolution.allowed || Resolution.answered => c.okFg,
        Resolution.denied => c.waitFg,
        _ => c.muted,
      };
      outcome = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (good) ...[
            Icon(Icons.check, size: 14, color: c.okFg),
            const SizedBox(width: 4),
          ],
          Text(
            resolutionLabel(resolution),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: pending ? c.waitSoft : null,
        border: pending ? null : Border.all(color: c.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 10),
              outcome,
            ],
          ),
          if (body != null) ...[const SizedBox(height: 6), body!],
        ],
      ),
    );
  }
}

class _PermissionRecord extends StatelessWidget {
  const _PermissionRecord({required this.item});
  final PermissionItem item;

  @override
  Widget build(BuildContext context) {
    final summary = toolSummary(item.toolName, item.toolInput);
    return _Record(
      title: summary.isEmpty
          ? 'Permiso: ${item.toolName}'
          : 'Permiso: ${item.toolName} $summary',
      resolution: item.resolution,
    );
  }
}

class _QuestionRecord extends StatelessWidget {
  const _QuestionRecord({required this.item});
  final QuestionItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final answers = item.answers;
    final first = item.questions.isEmpty ? '' : item.questions.first.question;
    final given = <String>[
      for (final q in item.questions)
        if (answers != null && answers[q.question] != null)
          '${answers[q.question]}',
    ];
    return _Record(
      title: first.isEmpty ? 'Pregunta de Claude' : 'Pregunta: $first',
      resolution: item.resolution,
      body: given.isEmpty
          ? null
          : Text(
              'Respuesta: ${given.join(', ')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
    );
  }
}

class _PlanRecord extends StatefulWidget {
  const _PlanRecord({required this.item});
  final PlanItem item;

  @override
  State<_PlanRecord> createState() => _PlanRecordState();
}

class _PlanRecordState extends State<_PlanRecord> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() => _open = !_open),
      child: _Record(
        title: _open ? 'Plan' : 'Plan (toca para ver)',
        resolution: widget.item.resolution,
        body: _open ? TherdMarkdown(widget.item.plan, fontSize: 15) : null,
      ),
    );
  }
}

/// Entrada rápida de una fila nueva: aparece y sube 8 px en 220 ms.
///
/// Solo anima si [animate] es true al crearse; las reconstrucciones posteriores
/// (o volver a la vista tras hacer scroll) la pintan quieta.
class EnterAnimation extends StatefulWidget {
  const EnterAnimation({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<EnterAnimation> createState() => _EnterAnimationState();
}

class _EnterAnimationState extends State<EnterAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    child: widget.child,
    builder: (context, child) => Opacity(
      opacity: _t.value,
      child: Transform.translate(
        offset: Offset(0, 8 * (1 - _t.value)),
        child: child,
      ),
    ),
  );
}

/// «Pensando» al final del chat mientras Claude trabaja: una chispa ámbar que
/// respira y gira, y el texto con un brillo que lo recorre.
class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key});

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Semantics(
      label: 'Claude está pensando',
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          // Banda de luz que cruza el texto de izquierda a derecha.
          final x = -0.6 + t * 2.2;
          return Row(
            children: [
              CustomPaint(
                size: const Size.square(18),
                painter: _SparkPainter(t, kDotWork),
              ),
              const SizedBox(width: 10),
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => LinearGradient(
                  colors: [c.muted, c.text, c.muted],
                  stops: [
                    (x - 0.25).clamp(0.0, 1.0),
                    x.clamp(0.0, 1.0),
                    (x + 0.25).clamp(0.0, 1.0),
                  ],
                ).createShader(r),
                child: const Text('Pensando', style: TextStyle(fontSize: 15)),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Chispa de seis rayos cuya longitud ondula en cadena mientras gira despacio.
class _SparkPainter extends CustomPainter {
  _SparkPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    canvas.translate(r, r);
    // En un ciclo gira un sexto de vuelta: cada rayo acaba donde estaba el
    // siguiente. La onda depende del ángulo absoluto del rayo (no de su
    // índice), así el último fotograma empalma con el primero sin salto.
    final rot = t * math.pi / 3;
    canvas.rotate(rot);
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.13
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final wave = 0.5 + 0.5 * math.sin(4 * math.pi * t - (a + rot));
      final len = r * (0.45 + 0.4 * wave);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(dir * (r * 0.12), dir * len, paint);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.t != t || old.color != color;
}
