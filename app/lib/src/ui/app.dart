import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_state.dart';
import '../data/deep_link.dart';
import '../data/therd_controller.dart';
import 'chat_screen.dart';
import 'connection_screen.dart';
import 'sessions_screen.dart';
import 'splash.dart';
import 'theme.dart';

class TherdApp extends ConsumerStatefulWidget {
  const TherdApp({super.key});

  @override
  ConsumerState<TherdApp> createState() => _TherdAppState();
}

class _TherdAppState extends ConsumerState<TherdApp> {
  late final AppLifecycleListener _lifecycle;
  final _navKey = GlobalKey<NavigatorState>();
  final _chatTracker = ChatRouteTracker();
  StreamSubscription<Uri>? _linkSub;

  /// Enlace a una sesión que aún no se ha podido abrir, con el número de
  /// `hello` que había al recibirlo (null si la lista ya era fresca).
  String? _pendingId;
  int _helloAtLink = 0;
  bool _needsFreshHello = false;
  Timer? _giveUp;

  @override
  void initState() {
    super.initState();
    _linkSub = ref.read(deepLinkSourceProvider).links.listen(_onLink);
    // Solo hay socket con la app en primer plano. Al volver tras salir con
    // «atrás» (el motor sigue vivo) se pasa de detached a resumed sin onShow.
    final ctl = ref.read(therdProvider.notifier);
    _lifecycle = AppLifecycleListener(
      onHide: ctl.pause,
      onShow: ctl.resume,
      onResume: ctl.resume,
    );
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _giveUp?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _onLink(Uri uri) {
    final id = parseSessionLink(uri);
    if (id == null) return;
    final s = ref.read(therdProvider);
    if (s.configLoaded && s.config == null) return; // sin emparejar: se ignora
    _pendingId = id;
    // Aviso de otro ordenador: se pasa a él antes de abrir el chat.
    final target = s.computers.byDaemon(parseLinkDaemon(uri));
    final switching = target != null && target.id != s.computers.activeId;
    if (switching) {
      unawaited(ref.read(therdProvider.notifier).switchTo(target.id));
    }
    // Con el socket vivo la lista de sesiones ya está al día; si no, hay que
    // esperar al `hello` de la reconexión para saber si la sesión existe.
    _needsFreshHello = switching || !s.link.isConnected || s.hellos == 0;
    _helloAtLink = s.hellos;
    // Si nunca llega a conectar, el enlace caduca y no abre nada por sorpresa.
    _giveUp?.cancel();
    _giveUp = Timer(const Duration(seconds: 30), () => _pendingId = null);
    _tryOpen(s);
  }

  void _tryOpen(AppState s) {
    final id = _pendingId;
    if (id == null || !s.configLoaded) return;
    if (s.config == null) {
      _pendingId = null;
      return;
    }
    if (_needsFreshHello && s.hellos == _helloAtLink) return;
    final nav = _navKey.currentState;
    if (nav == null) return;
    _pendingId = null;
    _giveUp?.cancel();
    // Si la sesión ya no existe se queda la lista, sin chat vacío colgado.
    if (s.session(id) == null) return;
    if (_chatTracker.top == id) return;
    // Se vuelve a la lista y se apila el chat: «atrás» lleva a la lista.
    nav.popUntil((r) => r.isFirst);
    nav.push(chatRoute(id));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(therdProvider, (_, next) => _tryOpen(next));
    final loaded = ref.watch(therdProvider.select((s) => s.configLoaded));
    final hasConfig = ref.watch(therdProvider.select((s) => s.config != null));
    return MaterialApp(
      navigatorKey: _navKey,
      navigatorObservers: [_chatTracker],
      title: 'therd',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      builder: (context, child) =>
          SplashGate(ready: loaded, child: child ?? const SizedBox()),
      // Mientras carga la tapa el splash; esto solo pinta el fondo del tema.
      home: !loaded
          ? const Scaffold()
          : hasConfig
          ? const SessionsScreen()
          : const ConnectionScreen(firstRun: true),
    );
  }
}
