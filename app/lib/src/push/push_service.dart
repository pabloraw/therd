import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:therd_protocol/protocol.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../core/settings_store.dart';
import '../data/deep_link.dart';
import 'quick_reply.dart';

/// Avisos con UnifiedPush: la app se registra en el distribuidor instalado
/// (ntfy), le da su endpoint al daemon y pinta sus propias notificaciones con
/// lo que llega.
///
/// Corre también en segundo plano: con la app cerrada, Android arranca
/// `main` con `--unifiedpush-bg` solo para recibir el aviso, sin interfaz.
class PushService implements DeepLinkSource {
  PushService({FlutterLocalNotificationsPlugin? notifications})
    : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const _kEndpoint = 'push_endpoint';

  final FlutterLocalNotificationsPlugin _notifications;

  /// De una sola suscripción para que guarde el toque del arranque en frío
  /// hasta que la interfaz escuche.
  final _taps = StreamController<Uri>();

  /// Endpoint nuevo (y el anterior, que el daemon debe olvidar).
  void Function(String endpoint, String? previous)? onEndpoint;

  /// El distribuidor dejó de mandar avisos a [endpoint].
  void Function(String endpoint)? onUnregistered;

  String? _endpoint;
  String? get endpoint => _endpoint;

  /// Toques en las notificaciones, como enlaces `therd://session/<id>`.
  @override
  Stream<Uri> get links => _taps.stream;

  Future<void> init() async {
    await _notifications.initialize(
      settings: _initSettings,
      onDidReceiveNotificationResponse: _onTap,
      onDidReceiveBackgroundNotificationResponse: onNotificationAction,
    );
    final prefs = await SharedPreferences.getInstance();
    _endpoint = prefs.getString(_kEndpoint);
    await UnifiedPush.initialize(
      onNewEndpoint: (e, _) => unawaited(_onNewEndpoint(e.url)),
      onUnregistered: (_) => unawaited(_onUnregistered()),
      onRegistrationFailed: (r, _) =>
          debugPrint('UnifiedPush: registro fallido ($r)'),
      onMessage: (m, _) => unawaited(_onMessage(m)),
    );
  }

  /// En primer plano: pide permiso de notificaciones, se registra en el
  /// distribuidor (ntfy) si hay uno y avisa del endpoint guardado para que
  /// llegue al daemon en cada conexión.
  Future<void> register() async {
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    final saved = _endpoint;
    if (saved != null) onEndpoint?.call(saved, null);
    if (await UnifiedPush.tryUseCurrentOrDefaultDistributor()) {
      await UnifiedPush.register();
    } else {
      debugPrint('UnifiedPush: no hay distribuidor instalado');
    }
    // Arranque en frío desde una notificación.
    final launch = await _notifications.getNotificationAppLaunchDetails();
    final r = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true && r != null) _onTap(r);
  }

  Future<void> _onNewEndpoint(String url) async {
    final previous = _endpoint;
    _endpoint = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEndpoint, url);
    onEndpoint?.call(url, previous == url ? null : previous);
  }

  Future<void> _onUnregistered() async {
    final old = _endpoint;
    _endpoint = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kEndpoint);
    if (old != null) onUnregistered?.call(old);
  }

  Future<void> _onMessage(PushMessage m) async {
    final PushPayload? p;
    try {
      final j = jsonDecode(utf8.decode(m.content));
      p = j is Map ? PushPayload.fromJson(Map<String, dynamic>.from(j)) : null;
    } catch (_) {
      return;
    }
    switch (p) {
      case PushPending():
        await _notifications.show(
          id: notificationId(p.requestId),
          title: p.title,
          body: p.body,
          payload: NotificationPayload(
            sessionId: p.sessionId,
            requestId: p.requestId,
          ).encode(),
          notificationDetails: _details(
            p.body,
            actions: [
              for (final (id, label) in QuickAction.forKind(p.kind))
                AndroidNotificationAction(id, label),
            ],
          ),
        );
      case PushResolved():
        await _notifications.cancel(id: notificationId(p.requestId));
      case PushTurnDone():
        await _notifications.show(
          id: notificationId('turno:${p.sessionId}'),
          title: p.title,
          body: p.body,
          payload: NotificationPayload(sessionId: p.sessionId).encode(),
          notificationDetails: _details(p.body),
        );
      case PushTurnCleared():
        await _notifications.cancel(id: notificationId('turno:${p.sessionId}'));
      case null:
        return;
    }
  }

  void _onTap(NotificationResponse r) {
    // Un botón con la app viva: se contesta igual que desde segundo plano.
    if (r.notificationResponseType ==
        NotificationResponseType.selectedNotificationAction) {
      unawaited(handleNotificationAction(r, _notifications));
      return;
    }
    final p = NotificationPayload.decode(r.payload);
    if (p == null) return;
    _taps.add(Uri(scheme: 'therd', host: 'session', path: '/${p.sessionId}'));
  }
}

const _channelId = 'pendientes';

const _initSettings = InitializationSettings(
  android: AndroidInitializationSettings('ic_launcher_monochrome'),
);

NotificationDetails _details(
  String body, {
  List<AndroidNotificationAction> actions = const [],
}) => NotificationDetails(
  android: AndroidNotificationDetails(
    _channelId,
    'Claude espera',
    channelDescription:
        'Permisos, preguntas, planes y sesiones terminadas sin ver',
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.message,
    styleInformation: BigTextStyleInformation(body),
    actions: actions,
  ),
);

/// Botón pulsado con la app cerrada o en segundo plano: Android lo entrega
/// en un isolate aparte, sin interfaz.
@pragma('vm:entry-point')
Future<void> onNotificationAction(NotificationResponse r) async {
  DartPluginRegistrant.ensureInitialized();
  final n = FlutterLocalNotificationsPlugin();
  await n.initialize(settings: _initSettings);
  await handleNotificationAction(r, n);
}

/// Manda al daemon la respuesta de un botón por una conexión suelta. Si
/// falla, deja una notificación que lo dice y abre el chat al tocarla.
Future<void> handleNotificationAction(
  NotificationResponse r,
  FlutterLocalNotificationsPlugin notifications,
) async {
  final p = NotificationPayload.decode(r.payload);
  final rid = p?.requestId;
  if (p == null || rid == null) return;
  final msg = quickMessage(r.actionId, rid);
  if (msg == null) return;
  final config = await PrefsSettingsStore().load();
  final error = config == null
      ? 'La app no está emparejada'
      : await sendQuickReply(config, msg, rid);
  if (error == null) return;
  final body = '$error. Tócala para contestar en el chat.';
  await notifications.show(
    id: notificationId(rid),
    title: 'No se pudo contestar',
    body: body,
    payload: NotificationPayload(sessionId: p.sessionId).encode(),
    notificationDetails: _details(body),
  );
}

/// Id estable de la notificación de un pendiente, igual en cualquier isolate
/// (el hashCode de String no está garantizado entre ejecuciones).
int notificationId(String requestId) {
  var h = 0;
  for (final c in requestId.codeUnits) {
    h = (h * 31 + c) & 0x3fffffff;
  }
  return h;
}

/// Une varias fuentes de enlaces (los de Android y los toques en avisos).
class MergedLinks implements DeepLinkSource {
  MergedLinks(this.sources);
  final List<DeepLinkSource> sources;

  @override
  Stream<Uri> get links {
    final out = StreamController<Uri>();
    final subs = <StreamSubscription<Uri>>[];
    out.onListen = () {
      for (final s in sources) {
        subs.add(s.links.listen(out.add));
      }
    };
    out.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
    };
    return out.stream;
  }
}
