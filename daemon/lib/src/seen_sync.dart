import 'dart:async';

import 'package:therd_protocol/protocol.dart';

import 'herdr_client.dart';
import 'log.dart';
import 'session_store.dart';

/// Lo mínimo de herdr para dar una sesión por vista en el PC.
abstract interface class FocusIo {
  /// Pane enfocado ahora en el PC.
  Future<String?> currentPane();
  Future<void> focusPane(String paneId);
}

/// Lleva lo leído en el móvil al PC.
///
/// herdr solo marca una sesión como vista al enfocarla, así que se enfoca un
/// instante y se vuelve al pane que había. Solo se hace si herdr la tiene
/// como terminada sin ver (`done`) y la app ya ha visto todo lo que tiene.
class SeenSync {
  SeenSync({
    required this.store,
    required this.io,
    this.settle = const Duration(milliseconds: 1500),
  });

  final SessionStore store;
  final FocusIo io;

  /// Margen tras pasar a `done` por si aún llega el final del transcript.
  final Duration settle;

  /// Hasta qué seq ha visto cada sesión alguna app.
  final Map<String, int> _appSeen = {};
  final Set<String> _queued = {};
  Future<void> _chain = Future.value();
  StreamSubscription<StoreEvent>? _sub;
  final Set<Timer> _timers = {};

  void start() {
    // Si la sesión desaparece y vuelve, su seq empieza de cero.
    _sub = store.events.listen((e) {
      if (e is SessionRemoved) _appSeen.remove(e.sessionId);
    });
  }

  Future<void> dispose() async {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    await _sub?.cancel();
  }

  /// Una app tiene el chat abierto y lo ha visto hasta [seq].
  void fromApp(String sessionId, int seq) {
    store.markSeen(sessionId, seq);
    if (seq > (_appSeen[sessionId] ?? 0)) _appSeen[sessionId] = seq;
    _maybeAck(sessionId);
  }

  /// herdr cambió el estado de la sesión.
  void onHerdrStatus(String sessionId, SessionStatus status) {
    if (status != SessionStatus.done) return;
    late final Timer t;
    t = Timer(settle, () {
      _timers.remove(t);
      _maybeAck(sessionId);
    });
    _timers.add(t);
  }

  void _maybeAck(String sessionId) {
    final info = store.info(sessionId);
    final pane = info?.paneId;
    if (info == null || pane == null) return;
    if (store.herdrStatusOf(sessionId) != SessionStatus.done) return;
    if ((_appSeen[sessionId] ?? 0) < info.lastSeq) return;
    if (!_queued.add(sessionId)) return;
    // De una en una: cada una vuelve al pane que había antes.
    _chain = _chain.then((_) => _ack(sessionId, pane));
  }

  Future<void> _ack(String sessionId, String pane) async {
    _queued.remove(sessionId);
    if (store.herdrStatusOf(sessionId) != SessionStatus.done) return;
    try {
      final prev = await io.currentPane();
      await io.focusPane(pane);
      if (prev != null && prev != pane) await io.focusPane(prev);
      // herdr avisará de `idle`; se adelanta para no repetir el foco.
      store.setHerdrStatus(sessionId, SessionStatus.idle);
    } on HerdrException catch (e) {
      Log.warn('herdr: no se pudo marcar vista $sessionId (${e.message})');
    }
  }
}
