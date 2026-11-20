import 'dart:async';

import 'package:therd_protocol/protocol.dart';

import 'herdr_client.dart';

/// Diálogos de Claude Code que se pueden contestar pulsando teclas.
///
/// Textos y teclas sacados de Claude Code 2.1.x real (capturas en
/// `test/fixtures/`). Reglas que se comprobaron:
/// - Pulsar el número de una opción la elige al instante (en las preguntas
///   multiSelect solo la marca o desmarca).
/// - En un permiso, `Tab` sobre una opción abre el campo de comentario de esa
///   opción; con el texto y `Enter` se manda como feedback.
/// - Los números cambian según el diálogo («Yes, and switch to auto mode» solo
///   aparece a veces), así que se leen de la pantalla y no se fijan.
enum DialogKind { permission, question, plan }

/// Opción numerada de un diálogo.
class DialogOption {
  const DialogOption(this.number, this.label);
  final int number;
  final String label;

  @override
  String toString() => '$number. $label';
}

final _optionLine = RegExp(r'^\s*(?:[❯>]\s*)?(\d+)\.\s+(\S.*)$');

/// El terminal parte las líneas largas: para comparar textos se colapsan los
/// espacios, saltos incluidos.
String flatten(String screen) => screen.replaceAll(RegExp(r'\s+'), ' ');

/// Opciones numeradas que siguen a la última línea que empieza por [anchor].
/// Null si no hay ancla o no hay opciones.
List<DialogOption>? _optionsAfter(String screen, Pattern anchor) {
  final lines = screen.split('\n');
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith(anchor)) start = i;
  }
  if (start < 0) return null;
  final out = <DialogOption>[];
  for (var i = start + 1; i < lines.length; i++) {
    final m = _optionLine.firstMatch(lines[i]);
    if (m == null) continue;
    final n = int.parse(m.group(1)!);
    // Las opciones van numeradas desde 1 sin saltos.
    if (n != out.length + 1) break;
    out.add(DialogOption(n, m.group(2)!.trim()));
  }
  return out.isEmpty ? null : out;
}

/// Opciones del diálogo de permiso («Do you want to proceed?», «Do you want
/// to create X?»...). Null si la pantalla no es uno.
List<DialogOption>? permissionOptions(String screen) {
  if (!flatten(screen).contains('Esc to cancel')) return null;
  final opts = _optionsAfter(screen, RegExp(r'Do you want to\b'));
  if (opts == null || !opts.first.label.startsWith('Yes')) return null;
  if (!opts.any((o) => o.label.startsWith('No'))) return null;
  return opts;
}

/// Opciones del diálogo del plan (`ExitPlanMode`).
List<DialogOption>? planOptions(String screen) {
  final flat = flatten(screen);
  if (!flat.contains('Would you like to proceed?') ||
      !flat.contains('Tell Claude what to change')) {
    return null;
  }
  return _optionsAfter(screen, RegExp(r'.*Would you like to proceed\?')) ??
      _optionsAfter(screen, RegExp(r'Claude has written up a plan'));
}

/// Diálogo de `AskUserQuestion`: la pregunta en curso o la revisión final.
bool questionDialogShown(String screen) {
  final flat = flatten(screen);
  // La revisión final no lleva el pie «Esc to cancel».
  if (flat.contains('Review your answers') && flat.contains('Submit answers')) {
    return true;
  }
  return flat.contains('Esc to cancel') && flat.contains('Chat about this');
}

bool dialogShown(DialogKind kind, String screen) => switch (kind) {
  DialogKind.permission => permissionOptions(screen) != null,
  DialogKind.plan => planOptions(screen) != null,
  DialogKind.question => questionDialogShown(screen),
};

String _oneLine(String s) => s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

/// Teclas para contestar un permiso. Devuelve false (sin pulsar nada) si el
/// diálogo ya no está en pantalla.
///
/// - Permitir: la primera opción («Yes»).
/// - Permitir siempre: la primera opción «Yes, and ...» que no sea cambiar a
///   modo auto; si no existe, se permite solo esta vez.
/// - Denegar: la opción «No»; con mensaje, `Tab` sobre ella y el texto.
Future<bool> answerPermissionDialog(
  TerminalIo io,
  String pane, {
  required bool allow,
  bool always = false,
  String? message,
  Duration pause = const Duration(milliseconds: 150),
}) async {
  final opts = permissionOptions(await io.readVisible(pane));
  if (opts == null) return false;
  if (allow) {
    var target = opts.first;
    if (always) {
      target = opts
          .skip(1)
          .firstWhere(
            (o) => o.label.startsWith('Yes') && !o.label.contains('auto mode'),
            orElse: () => opts.first,
          );
    }
    await io.sendKeys(pane, ['${target.number}']);
    return true;
  }
  final no = opts.lastWhere((o) => o.label.startsWith('No'));
  final text = _oneLine(message ?? '');
  if (text.isEmpty) {
    await io.sendKeys(pane, ['${no.number}']);
    return true;
  }
  // El cursor empieza en la primera opción: se baja hasta «No», `Tab` abre
  // el comentario y `Enter` lo manda.
  await io.sendKeys(pane, [for (var i = 1; i < no.number; i++) 'Down', 'Tab']);
  await Future<void>.delayed(pause);
  await io.sendText(pane, text);
  await Future<void>.delayed(pause);
  await io.sendKeys(pane, ['Enter']);
  return true;
}

/// Teclas para contestar el diálogo del plan.
///
/// - Aprobar: «Yes, manually approve edits» (la conducta de un allow por
///   hook, que no cambia el modo); «Yes, and use auto mode» si pides
///   «siempre».
/// - Rechazar: `Escape`; con mensaje, la opción «Tell Claude what to change»
///   y el texto.
Future<bool> answerPlanDialog(
  TerminalIo io,
  String pane, {
  required bool allow,
  bool always = false,
  String? message,
  Duration pause = const Duration(milliseconds: 150),
}) async {
  final opts = planOptions(await io.readVisible(pane));
  if (opts == null) return false;
  if (allow) {
    final manual = opts.where((o) => o.label.contains('manually approve'));
    final target = always || manual.isEmpty ? opts.first : manual.first;
    await io.sendKeys(pane, ['${target.number}']);
    return true;
  }
  final text = _oneLine(message ?? '');
  if (text.isEmpty) {
    await io.sendKeys(pane, ['Escape']);
    return true;
  }
  final feedback = opts.firstWhere(
    (o) => o.label.startsWith('Tell Claude'),
    orElse: () => opts.last,
  );
  await io.sendKeys(pane, ['${feedback.number}']);
  await Future<void>.delayed(pause);
  await io.sendText(pane, text);
  await Future<void>.delayed(pause);
  await io.sendKeys(pane, ['Enter']);
  return true;
}

/// Cómo se contesta una pregunta: opciones marcadas (índices desde 1) y,
/// si hay, texto libre («Type something»). Fuera de multiSelect va una cosa
/// u otra.
class _Choice {
  const _Choice(this.picks, [this.other]);
  final List<int> picks;
  final String? other;
}

_Choice? _choiceFor(QuestionSpec q, String? answer) {
  if (answer == null || answer.trim().isEmpty) return null;
  final labels = [for (final o in q.options) o.label];
  final direct = labels.indexOf(answer);
  if (direct >= 0) return _Choice([direct + 1]);
  if (q.multiSelect) {
    // La app junta las marcadas, en el orden de las opciones, con «, » y deja
    // el texto libre al final: lo que sigue a la última opción reconocida es
    // el texto.
    final parts = answer.split(', ');
    final picks = <int>[];
    var next = 0;
    while (next < parts.length) {
      final i = labels.indexOf(parts[next]);
      if (i < 0 || (picks.isNotEmpty && i + 1 <= picks.last)) break;
      picks.add(i + 1);
      next++;
    }
    final rest = parts.sublist(next).join(', ');
    return _Choice(picks, rest.trim().isEmpty ? null : _oneLine(rest));
  }
  return _Choice(const [], _oneLine(answer));
}

/// ¿Se puede contestar esta pregunta por teclas con esas respuestas?
bool canAnswerByKeys(List<QuestionSpec> qs, Map<String, String> answers) {
  if (qs.isEmpty) return false;
  for (final q in qs) {
    if (_choiceFor(q, answers[q.question]) == null) return false;
  }
  return true;
}

/// Teclas para contestar un `AskUserQuestion`. En orden, por pregunta:
/// - una opción: su número (elige y pasa a la siguiente pregunta);
/// - texto libre: el número de «Type something», el texto y `Enter`;
/// - multiSelect: el número de cada casilla y `Flecha derecha` para pasar;
///   con texto libre se marca «Type something» con su número, se baja hasta
///   ella (el cursor sigue en la 1), se escribe y `Abajo` y `Enter` sobre
///   «Submit» pasan a la siguiente.
/// Con varias preguntas o alguna multiSelect, al final queda la pantalla de
/// revisión y la opción 1 es «Submit answers».
///
/// Devuelve false, sin pulsar nada, si el diálogo ya no está o si alguna
/// respuesta no se puede dar por teclas (vacía).
Future<bool> answerQuestionDialog(
  TerminalIo io,
  String pane,
  List<QuestionSpec> qs,
  Map<String, String> answers, {
  Duration pause = const Duration(milliseconds: 150),
}) async {
  if (!canAnswerByKeys(qs, answers)) return false;
  if (!questionDialogShown(await io.readVisible(pane))) return false;
  for (final q in qs) {
    final c = _choiceFor(q, answers[q.question])!;
    final other = c.other;
    if (q.multiSelect) {
      for (final n in c.picks) {
        await io.sendKeys(pane, ['$n']);
        await Future<void>.delayed(pause);
      }
      if (other == null) {
        await io.sendKeys(pane, ['Right']);
      } else {
        final n = q.options.length;
        await io.sendKeys(pane, ['${n + 1}']);
        await Future<void>.delayed(pause);
        await io.sendKeys(pane, [for (var i = 0; i < n; i++) 'Down']);
        await Future<void>.delayed(pause);
        await io.sendText(pane, other);
        await Future<void>.delayed(pause);
        await io.sendKeys(pane, ['Down', 'Enter']);
      }
    } else if (other != null) {
      await io.sendKeys(pane, ['${q.options.length + 1}']);
      await Future<void>.delayed(pause);
      await io.sendText(pane, other);
      await Future<void>.delayed(pause);
      await io.sendKeys(pane, ['Enter']);
    } else {
      await io.sendKeys(pane, ['${c.picks.single}']);
    }
    await Future<void>.delayed(pause);
  }
  if (qs.length > 1 || qs.any((q) => q.multiSelect)) {
    await io.sendKeys(pane, ['1']);
  }
  return true;
}
