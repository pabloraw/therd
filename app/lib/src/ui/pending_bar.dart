import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:therd_protocol/protocol.dart';

import 'haptics.dart';
import 'theme.dart';
import 'tool_card.dart';

typedef PermissionCallback =
    void Function({required bool allow, bool always, String? message});

/// Hoja inferior con el pendiente más antiguo de la sesión.
class PendingBar extends StatelessWidget {
  const PendingBar({
    super.key,
    required this.pending,
    this.total = 1,
    required this.onPermission,
    required this.onAnswer,
    required this.onRelease,
    this.maxHeight,
  });

  final Pending pending;

  /// Alto máximo; por defecto, media pantalla.
  final double? maxHeight;

  /// Cuántos pendientes hay en la sesión (para mostrar «1 de N»).
  final int total;
  final PermissionCallback onPermission;
  final void Function(Map<String, String> answers) onAnswer;
  final VoidCallback onRelease;

  String get _title => switch (pending.kind) {
    PendingKind.permission =>
      pending.toolName == 'Bash'
          ? 'Permiso para ejecutar un comando'
          : 'Permiso para usar ${pending.toolName}',
    PendingKind.question => 'Claude te pregunta',
    PendingKind.plan => 'Claude propone un plan',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final maxH = maxHeight ?? MediaQuery.sizeOf(context).height * 0.5;
    final body = switch (pending.kind) {
      PendingKind.permission => PermissionCard(
        key: ValueKey(pending.requestId),
        pending: pending,
        onPermission: onPermission,
        onRelease: onRelease,
      ),
      PendingKind.question => QuestionCard(
        key: ValueKey(pending.requestId),
        pending: pending,
        onAnswer: onAnswer,
        onRelease: onRelease,
      ),
      PendingKind.plan => PlanCard(
        key: ValueKey(pending.requestId),
        pending: pending,
        onPermission: onPermission,
        onRelease: onRelease,
      ),
    };
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Tk.radiusSheet),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            offset: Offset(0, -10),
            blurRadius: 28,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: kDotWait,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (total > 1)
                    Text(
                      '1 de $total pendientes',
                      style: mono(size: 12, color: c.muted),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// Contenido con scroll interno y, fijos debajo, los botones y «Contestar en
/// el PC».
class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.content,
    required this.actions,
    required this.onRelease,
  });

  final Widget content;
  final Widget actions;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(child: SingleChildScrollView(child: content)),
        const SizedBox(height: 12),
        actions,
        Center(
          child: TextButton.icon(
            onPressed: onRelease,
            style: TextButton.styleFrom(
              foregroundColor: c.muted,
              minimumSize: const Size(Tk.control, 40),
              textStyle: const TextStyle(
                fontFamily: kSans,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
            icon: const Icon(Icons.desktop_windows_outlined, size: 16),
            label: const Text('Contestar en el PC'),
          ),
        ),
      ],
    );
  }
}

/// Botón de la acción negativa: texto rojo de estado y borde rojo al 45 %.
ButtonStyle _negativeStyle(TherdColors c) => OutlinedButton.styleFrom(
  foregroundColor: c.waitFg,
  side: BorderSide(color: c.negativeBorder),
  backgroundColor: Colors.transparent,
);

/// Confirmación de denegar o rechazar: fondo rojo tenue, nunca macizo.
ButtonStyle _confirmStyle(TherdColors c) => FilledButton.styleFrom(
  backgroundColor: c.waitSoft,
  foregroundColor: c.waitFg,
  side: BorderSide(color: c.negativeBorder),
  textStyle: const TextStyle(
    fontFamily: kSans,
    fontWeight: FontWeight.w600,
    fontSize: 14,
  ),
);

Widget _row(List<(int, Widget)> items) => Row(
  children: [
    for (var i = 0; i < items.length; i++) ...[
      if (i > 0) const SizedBox(width: 8),
      Expanded(flex: items[i].$1, child: items[i].$2),
    ],
  ],
);

String _inputPreview(Pending p) {
  final s = toolSummary(p.toolName, p.toolInput);
  if (p.toolName == 'Bash') {
    final cmd = p.toolInput['command'];
    if (cmd is String) return cmd;
  }
  if (s.isNotEmpty) return s;
  return p.toolInput.isEmpty
      ? ''
      : const JsonEncoder.withIndent('  ').convert(p.toolInput);
}

class PermissionCard extends StatefulWidget {
  const PermissionCard({
    super.key,
    required this.pending,
    required this.onPermission,
    required this.onRelease,
  });

  final Pending pending;
  final PermissionCallback onPermission;
  final VoidCallback onRelease;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  final _reason = TextEditingController();
  bool _denying = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final p = widget.pending;
    final preview = _inputPreview(p);
    final desc = p.toolInput['description'];
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          desc is String && desc.isNotEmpty
              ? desc
              : 'Claude quiere usar ${p.toolName}.',
          style: TextStyle(fontSize: 14, height: 1.45, color: c.muted),
        ),
        if (preview.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.code,
              borderRadius: BorderRadius.circular(Tk.radius),
            ),
            child: SelectableText(
              preview,
              style: mono(size: 13, color: c.text).copyWith(height: 1.55),
            ),
          ),
        ],
        if (_denying) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Motivo para Claude (opcional)',
            ),
          ),
        ],
      ],
    );
    final Widget actions;
    if (_denying) {
      actions = _row([
        (
          1,
          OutlinedButton(
            onPressed: () => setState(() => _denying = false),
            child: const Text('Cancelar'),
          ),
        ),
        (
          1,
          FilledButton(
            style: _confirmStyle(c),
            onPressed: () =>
                widget.onPermission(allow: false, message: _reason.text),
            child: const Text('Denegar'),
          ),
        ),
      ]);
    } else {
      final always = p.suggestions.isNotEmpty;
      actions = _row([
        (
          100,
          OutlinedButton(
            style: _negativeStyle(c),
            onPressed: () => setState(() => _denying = true),
            child: const Text('Denegar'),
          ),
        ),
        if (always)
          (
            125,
            OutlinedButton(
              onPressed: () => widget.onPermission(allow: true, always: true),
              child: const Text('Permitir siempre'),
            ),
          ),
        (
          135,
          FilledButton(
            onPressed: () => widget.onPermission(allow: true),
            child: const Text('Permitir'),
          ),
        ),
      ]);
    }
    return _SheetBody(
      content: content,
      actions: actions,
      onRelease: widget.onRelease,
    );
  }
}

class PlanCard extends StatefulWidget {
  const PlanCard({
    super.key,
    required this.pending,
    required this.onPermission,
    required this.onRelease,
  });

  final Pending pending;
  final PermissionCallback onPermission;
  final VoidCallback onRelease;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  final _reason = TextEditingController();
  bool _rejecting = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final p = widget.pending;
    final plan = p.plan ?? '${p.toolInput['plan'] ?? ''}';
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 15, height: 1.5),
          child: GptMarkdown(plan),
        ),
        if (_rejecting) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Qué cambiarías (opcional)',
            ),
          ),
        ],
      ],
    );
    final Widget actions;
    if (_rejecting) {
      actions = _row([
        (
          1,
          OutlinedButton(
            onPressed: () => setState(() => _rejecting = false),
            child: const Text('Cancelar'),
          ),
        ),
        (
          1,
          FilledButton(
            style: _confirmStyle(c),
            onPressed: () =>
                widget.onPermission(allow: false, message: _reason.text),
            child: const Text('Rechazar'),
          ),
        ),
      ]);
    } else {
      actions = _row([
        (
          10,
          OutlinedButton(
            style: _negativeStyle(c),
            onPressed: () => setState(() => _rejecting = true),
            child: const Text('Rechazar'),
          ),
        ),
        (
          15,
          FilledButton(
            onPressed: () => widget.onPermission(allow: true),
            child: const Text('Aprobar'),
          ),
        ),
      ]);
    }
    return _SheetBody(
      content: content,
      actions: actions,
      onRelease: widget.onRelease,
    );
  }
}

/// Estado de selección de una pregunta.
class _Choice {
  final Set<String> labels = {};
  bool other = false;
  final TextEditingController text = TextEditingController();
}

/// Compone la respuesta de una pregunta: etiquetas en orden y texto libre.
/// Devuelve null si no hay nada elegido.
String? composeAnswer(
  QuestionSpec q,
  Set<String> labels,
  bool other,
  String otherText,
) {
  final parts = [
    for (final o in q.options)
      if (labels.contains(o.label)) o.label,
  ];
  if (other && otherText.trim().isNotEmpty) parts.add(otherText.trim());
  return parts.isEmpty ? null : parts.join(', ');
}

class QuestionCard extends StatefulWidget {
  const QuestionCard({
    super.key,
    required this.pending,
    required this.onAnswer,
    required this.onRelease,
  });

  final Pending pending;
  final void Function(Map<String, String> answers) onAnswer;
  final VoidCallback onRelease;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  late final List<_Choice> _choices = [
    for (final _ in widget.pending.questions) _Choice(),
  ];

  @override
  void dispose() {
    for (final c in _choices) {
      c.text.dispose();
    }
    super.dispose();
  }

  Map<String, String>? _answers() {
    final out = <String, String>{};
    final qs = widget.pending.questions;
    for (var i = 0; i < qs.length; i++) {
      final a = composeAnswer(
        qs[i],
        _choices[i].labels,
        _choices[i].other,
        _choices[i].text.text,
      );
      if (a == null) return null;
      out[qs[i].question] = a;
    }
    return out.isEmpty ? null : out;
  }

  void _toggle(int qi, String label) {
    final q = widget.pending.questions[qi];
    final c = _choices[qi];
    setState(() {
      if (q.multiSelect) {
        c.labels.contains(label) ? c.labels.remove(label) : c.labels.add(label);
      } else {
        c.labels
          ..clear()
          ..add(label);
        c.other = false;
      }
    });
  }

  void _toggleOther(int qi) {
    final q = widget.pending.questions[qi];
    final c = _choices[qi];
    setState(() {
      c.other = !c.other;
      if (c.other && !q.multiSelect) c.labels.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final qs = widget.pending.questions;
    final answers = _answers();
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var qi = 0; qi < qs.length; qi++) ...[
          if (qi > 0) const SizedBox(height: 16),
          if (qs[qi].header.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(qs[qi].header, style: mono(size: 11, color: c.muted)),
            ),
          Text(
            qs[qi].question,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          if (qs[qi].multiSelect)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Puedes elegir varias',
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ),
          const SizedBox(height: 8),
          for (final o in qs[qi].options)
            _OptionRow(
              label: o.label,
              description: o.description,
              multi: qs[qi].multiSelect,
              selected: _choices[qi].labels.contains(o.label),
              onTap: () {
                Haptics.select();
                _toggle(qi, o.label);
              },
            ),
          // El texto libre va dentro de la propia opción, no como otra fila.
          _OptionRow(
            label: 'Otra',
            description: '',
            multi: qs[qi].multiSelect,
            selected: _choices[qi].other,
            onTap: () {
              Haptics.select();
              _toggleOther(qi);
            },
            child: _choices[qi].other
                ? TextField(
                    controller: _choices[qi].text,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      contentPadding: const EdgeInsets.only(top: 6, bottom: 2),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'Escribe tu respuesta',
                      hintStyle: TextStyle(color: c.muted),
                    ),
                  )
                : null,
          ),
        ],
      ],
    );
    return _SheetBody(
      content: content,
      actions: FilledButton(
        onPressed: answers == null ? null : () => widget.onAnswer(answers),
        child: const Text('Enviar respuesta'),
      ),
      onRelease: widget.onRelease,
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.description,
    required this.multi,
    required this.selected,
    required this.onTap,
    this.child,
  });

  final String label;
  final String description;
  final bool multi;
  final bool selected;
  final VoidCallback onTap;

  /// Debajo del texto, dentro de la opción (el campo de «Otra»).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final icon = multi
        ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
        : (selected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? c.cont : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: Tk.br,
          side: BorderSide(color: selected ? c.muted : c.line),
        ),
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: Tk.br),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Tk.control),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: selected ? c.text : c.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (description.isNotEmpty)
                          Text(
                            description,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: c.muted,
                            ),
                          ),
                        ?child,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
