// Genera plugin/hooks/hooks.json a partir de la misma definición que usa
// `therd install`. Uso: dart run tool/gen_plugin.dart
import 'dart:convert';
import 'dart:io';

import 'package:therd_daemon/src/installer.dart';

void main() {
  final file = File('../plugin/hooks/hooks.json')
    ..parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'hooks': buildHooks()})}\n',
  );
  stdout.writeln('Escrito ${file.path}');
}
