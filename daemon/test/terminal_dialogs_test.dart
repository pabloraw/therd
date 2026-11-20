import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/terminal_dialogs.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

/// Pantallas reales de Claude Code 2.1.x capturadas con `pane.read visible`.
String fixture(String name) =>
    File('test/fixtures/$name.txt').readAsStringSync();

const _color = QuestionSpec(
  question: '¿Cuál es tu color favorito?',
  header: 'Color',
  options: [
    QuestionOption(label: 'Rojo'),
    QuestionOption(label: 'Verde'),
    QuestionOption(label: 'Azul'),
  ],
);
const _animal = QuestionSpec(
  question: '¿Qué animal prefieres?',
  options: [
    QuestionOption(label: 'Perro'),
    QuestionOption(label: 'Gato'),
  ],
);
const _pizza = QuestionSpec(
  question: '¿Qué ingredientes quieres en tu pizza?',
  multiSelect: true,
  options: [
    QuestionOption(label: 'Queso'),
    QuestionOption(label: 'Jamón'),
    QuestionOption(label: 'Piña'),
  ],
);

void main() {
  group('detección', () {
    test('permiso de Bash', () {
      final o = permissionOptions(fixture('permiso_bash'))!;
      expect(o.map((e) => e.number), [1, 2, 3, 4]);
      expect(o.first.label, 'Yes');
      expect(o.last.label, 'No');
      expect(
        dialogShown(DialogKind.permission, fixture('permiso_bash')),
        isTrue,
      );
    });

    test('permiso de escritura, con «No» en la opción 3', () {
      final o = permissionOptions(fixture('permiso_write'))!;
      expect(o.map((e) => e.number), [1, 2, 3]);
      expect(o.last.label, 'No');
    });

    test('plan', () {
      final o = planOptions(fixture('plan'))!;
      expect(o.map((e) => e.number), [1, 2, 3]);
      expect(o[2].label, 'Tell Claude what to change');
      expect(dialogShown(DialogKind.plan, fixture('plan')), isTrue);
    });

    test('preguntas: simple, varias, revisión y multiSelect', () {
      for (final f in [
        'pregunta_simple',
        'pregunta_multiple',
        'pregunta_multiple_revision',
        'pregunta_multiselect',
      ]) {
        expect(questionDialogShown(fixture(f)), isTrue, reason: f);
      }
    });

    test('cada diálogo solo se reconoce como el suyo', () {
      final kinds = {
        'permiso_bash': DialogKind.permission,
        'permiso_write': DialogKind.permission,
        'plan': DialogKind.plan,
        'pregunta_simple': DialogKind.question,
        'pregunta_multiple': DialogKind.question,
        'pregunta_multiple_revision': DialogKind.question,
        'pregunta_multiselect': DialogKind.question,
      };
      for (final f in kinds.entries) {
        for (final k in DialogKind.values) {
          expect(
            dialogShown(k, fixture(f.key)),
            k == f.value,
            reason: '${f.key} como ${k.name}',
          );
        }
      }
    });

    test('una pantalla sin diálogo no se reconoce', () {
      const idle = '❯ hola\n\n● Hecho.\n\n  ⏸ manual mode on';
      for (final k in DialogKind.values) {
        expect(dialogShown(k, idle), isFalse);
      }
    });

    test('con las líneas partidas por el ancho del terminal', () {
      const wrapped = '''
 Claude has written up a plan and is ready to execute. Would you
 like to
 proceed?

 ❯ 1. Yes, and use auto mode
   2. Yes, manually approve edits
   3. Tell Claude
 what to change
''';
      // El ancla parte en varias líneas: se tolera al compararlo plano.
      expect(flatten(wrapped).contains('Would you like to proceed?'), isTrue);
    });
  });

  group('teclas de permiso', () {
    late FakeTerminal t;
    setUp(() => t = FakeTerminal(fixture('permiso_bash')));

    test('permitir pulsa 1', () async {
      expect(
        await answerPermissionDialog(t, 'p', allow: true, pause: Duration.zero),
        isTrue,
      );
      expect(t.sent, [
        ['1'],
      ]);
    });

    test('permitir siempre pulsa la opción «Yes, and always»', () async {
      await answerPermissionDialog(
        t,
        'p',
        allow: true,
        always: true,
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['2'],
      ]);
    });

    test('siempre no elige cambiar a modo auto', () async {
      t.screen = '''
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and switch to auto mode · auto mode handles these prompts for you
   3. No

 Esc to cancel · Tab to amend
''';
      await answerPermissionDialog(
        t,
        'p',
        allow: true,
        always: true,
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['1'],
      ]);
    });

    test('denegar sin mensaje pulsa el número de «No»', () async {
      await answerPermissionDialog(t, 'p', allow: false, pause: Duration.zero);
      expect(t.sent, [
        ['4'],
      ]);
    });

    test('denegar con mensaje: Down hasta «No», Tab, texto y Enter', () async {
      await answerPermissionDialog(
        t,
        'p',
        allow: false,
        message: 'usa otro\nnombre',
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['Down', 'Down', 'Down', 'Tab'],
        'usa otro nombre',
        ['Enter'],
      ]);
    });

    test('con «No» en la opción 3 baja dos veces', () async {
      t.screen = fixture('permiso_write');
      await answerPermissionDialog(
        t,
        'p',
        allow: false,
        message: 'no',
        pause: Duration.zero,
      );
      expect(t.sent.first, ['Down', 'Down', 'Tab']);
    });

    test('sin diálogo en pantalla no pulsa nada', () async {
      t.screen = 'nada';
      expect(
        await answerPermissionDialog(t, 'p', allow: true, pause: Duration.zero),
        isFalse,
      );
      expect(t.sent, isEmpty);
    });
  });

  group('teclas del plan', () {
    late FakeTerminal t;
    setUp(() => t = FakeTerminal(fixture('plan')));

    test('aprobar elige «manually approve edits»', () async {
      await answerPlanDialog(t, 'p', allow: true, pause: Duration.zero);
      expect(t.sent, [
        ['2'],
      ]);
    });

    test('aprobar siempre elige la primera (modo auto)', () async {
      await answerPlanDialog(
        t,
        'p',
        allow: true,
        always: true,
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['1'],
      ]);
    });

    test('rechazar sin mensaje es Escape', () async {
      await answerPlanDialog(t, 'p', allow: false, pause: Duration.zero);
      expect(t.sent, [
        ['Escape'],
      ]);
    });

    test('rechazar con mensaje: opción 3, texto y Enter', () async {
      await answerPlanDialog(
        t,
        'p',
        allow: false,
        message: 'Cambia el paso 1',
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['3'],
        'Cambia el paso 1',
        ['Enter'],
      ]);
    });
  });

  group('teclas de preguntas', () {
    test('una pregunta, una opción: solo el número', () async {
      final t = FakeTerminal(fixture('pregunta_simple'));
      final ok = await answerQuestionDialog(
        t,
        'p',
        [_color],
        {_color.question: 'Verde'},
        pause: Duration.zero,
      );
      expect(ok, isTrue);
      expect(t.sent, [
        ['2'],
      ]);
    });

    test(
      'texto libre «Other»: número de «Type something», texto y Enter',
      () async {
        final t = FakeTerminal(fixture('pregunta_simple'));
        await answerQuestionDialog(
          t,
          'p',
          [_color],
          {_color.question: 'naranja'},
          pause: Duration.zero,
        );
        expect(t.sent, [
          ['4'],
          'naranja',
          ['Enter'],
        ]);
      },
    );

    test('varias preguntas: un número por pregunta y Submit', () async {
      final t = FakeTerminal(fixture('pregunta_multiple'));
      await answerQuestionDialog(
        t,
        'p',
        [_color, _animal],
        {_color.question: 'Rojo', _animal.question: 'Gato'},
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['1'],
        ['2'],
        ['1'],
      ]);
    });

    test('multiSelect: casillas, Flecha derecha y Submit', () async {
      final t = FakeTerminal(fixture('pregunta_multiselect'));
      await answerQuestionDialog(
        t,
        'p',
        [_pizza],
        {_pizza.question: 'Queso, Piña'},
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['1'],
        ['3'],
        ['Right'],
        ['1'],
      ]);
    });

    test('texto libre en multiSelect: casillas, «Type something», bajar, texto '
        'y Submit', () async {
      final t = FakeTerminal(fixture('pregunta_multiselect'));
      final ok = await answerQuestionDialog(
        t,
        'p',
        [_pizza],
        {_pizza.question: 'Queso, Piña, olivas, sin cebolla'},
        pause: Duration.zero,
      );
      expect(ok, isTrue);
      expect(t.sent, [
        ['1'],
        ['3'],
        ['4'],
        ['Down', 'Down', 'Down'],
        'olivas, sin cebolla',
        ['Down', 'Enter'],
        ['1'],
      ]);
    });

    test('multiSelect solo con texto libre', () async {
      final t = FakeTerminal(fixture('pregunta_multiselect'));
      await answerQuestionDialog(
        t,
        'p',
        [_pizza],
        {_pizza.question: 'Atún'},
        pause: Duration.zero,
      );
      expect(t.sent, [
        ['4'],
        ['Down', 'Down', 'Down'],
        'Atún',
        ['Down', 'Enter'],
        ['1'],
      ]);
    });

    test('sin diálogo en pantalla no pulsa nada', () async {
      final t = FakeTerminal('nada');
      final ok = await answerQuestionDialog(
        t,
        'p',
        [_color],
        {_color.question: 'Rojo'},
        pause: Duration.zero,
      );
      expect(ok, isFalse);
      expect(t.sent, isEmpty);
    });
  });
}
