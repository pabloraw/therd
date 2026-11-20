import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/settings_store.dart';
import 'src/data/deep_link.dart';
import 'src/data/therd_client.dart';
import 'src/data/therd_controller.dart';
import 'src/push/push_service.dart';
import 'src/ui/app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final push = PushService();
  await push.init();
  // Android arranca así la app cerrada solo para recibir un aviso.
  if (args.contains('--unifiedpush-bg')) return;

  final container = ProviderContainer(
    overrides: [
      clientProvider.overrideWithValue(WebSocketTherdClient()),
      settingsStoreProvider.overrideWithValue(PrefsSettingsStore()),
      deepLinkSourceProvider.overrideWithValue(
        MergedLinks([AppLinksSource(), push]),
      ),
    ],
  );
  final ctl = container.read(therdProvider.notifier);
  push
    ..onEndpoint = ((e, previous) => ctl.registerPush(e, previous: previous))
    ..onUnregistered = ctl.unregisterPush;
  runApp(
    UncontrolledProviderScope(container: container, child: const TherdApp()),
  );
  unawaited(push.register());
}
