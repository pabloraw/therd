import 'dart:io';

import 'package:therd_daemon/src/cli.dart';

Future<void> main(List<String> args) async {
  exit(await runCli(args));
}
