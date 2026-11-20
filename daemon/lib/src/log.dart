import 'dart:io';

/// Registro mínimo a stderr con marca de tiempo.
class Log {
  Log._();

  static bool verbose = false;

  /// Destino sustituible en tests.
  static void Function(String line) sink = (line) => stderr.writeln(line);

  static String _ts() => DateTime.now().toIso8601String().substring(11, 23);

  static void info(String msg) => sink('${_ts()} $msg');

  static void warn(String msg) => sink('${_ts()} AVISO $msg');

  static void error(String msg, [Object? e, StackTrace? st]) {
    sink('${_ts()} ERROR $msg${e != null ? ': $e' : ''}');
    if (verbose && st != null) sink('$st');
  }

  static void debug(String msg) {
    if (verbose) sink('${_ts()} DEBUG $msg');
  }
}
