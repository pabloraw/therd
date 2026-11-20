import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_state.dart';
import '../data/deep_link.dart';
import '../data/therd_controller.dart';
import 'chat_screen.dart';
import 'connection_screen.dart';
import 'sessions_screen.dart';
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
    // Con el socket vivo la lista de sesiones ya está al día; si no, hay que
    // esperar al `hello` de la reconexión para saber si la sesión existe.
    _needsFreshHello = !s.link.isConnected || s.hellos == 0;
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
      home: !loaded
          ? const _Startup()
          : hasConfig
          ? const SessionsScreen()
          : const ConnectionScreen(firstRun: true),
    );
  }
}

/// Arranque: logo, nombre y cuatro puntos de estado que saltan en secuencia.
class _Startup extends StatefulWidget {
  const _Startup();

  @override
  State<_Startup> createState() => _StartupState();
}

class _StartupState extends State<_Startup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Scaffold(
      backgroundColor: c.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(label: 'Logo de therd', child: const TherdLogo(size: 96)),
            const SizedBox(height: 22),
            Text(
              'therd',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.56,
                color: c.text,
              ),
            ),
            const SizedBox(height: 22),
            Semantics(
              label: 'Cargando',
              child: SizedBox(
                height: 16,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final (i, v) in const [
                      ViewStatus.working,
                      ViewStatus.blocked,
                      ViewStatus.unread,
                      ViewStatus.read,
                    ].indexed) ...[
                      if (i > 0) const SizedBox(width: 8),
                      _HopDot(ctl: _ctl, delay: i * 0.125, status: v),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HopDot extends StatelessWidget {
  const _HopDot({required this.ctl, required this.delay, required this.status});
  final Animation<double> ctl;
  final double delay;
  final ViewStatus status;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ctl,
      builder: (context, child) {
        final t = (ctl.value - delay) % 1.0;
        // 0 -> 1 -> 0 suave, como ease-in-out de 0% a 50% a 100%.
        final k = 0.5 - 0.5 * math.cos(2 * math.pi * t);
        return Opacity(
          opacity: 0.25 + 0.75 * k,
          child: Transform.translate(offset: Offset(0, -4 * k), child: child),
        );
      },
      child: StatusDot(status, size: 9),
    );
  }
}
