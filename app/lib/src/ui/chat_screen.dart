import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:therd_protocol/protocol.dart';

import '../data/app_state.dart';
import '../data/therd_controller.dart';
import 'chat_items.dart';
import 'composer.dart';
import 'connection_chip.dart';
import 'context_ring.dart';
import 'pending_bar.dart';
import 'sessions_screen.dart';
import 'theme.dart';

/// Ruta de un chat, con nombre para saber cuál está abierto. [instant] la
/// abre sin transición (para sustituir un chat por su continuación).
Route<void> chatRoute(String sessionId, {bool instant = false}) {
  final settings = RouteSettings(name: 'chat/$sessionId');
  if (instant) {
    return PageRouteBuilder<void>(
      settings: settings,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => ChatScreen(sessionId: sessionId),
    );
  }
  return MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => ChatScreen(sessionId: sessionId),
  );
}

/// Sesión que sigue a la que se ha ido en el mismo pane: tras un `/clear`
/// Claude Code continúa en el mismo terminal con otro sessionId.
SessionInfo? successorInPane(List<SessionInfo> sessions, String? paneId) {
  if (paneId == null) return null;
  for (final s in sessions) {
    if (s.paneId == paneId) return s;
  }
  return null;
}

/// Sigue la pila de rutas para saber qué chat está arriba del todo.
class ChatRouteTracker extends NavigatorObserver {
  final _stack = <Route<dynamic>>[];

  /// sessionId del chat visible, o null si arriba hay otra pantalla.
  String? get top {
    final name = _stack.isEmpty ? null : _stack.last.settings.name;
    return name != null && name.startsWith('chat/') ? name.substring(5) : null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) {
      _stack[i] = newRoute;
    } else if (newRoute != null) {
      _stack.add(newRoute);
    }
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// Scroll del chat anclado para no perder la línea de lectura.
///
/// La lista se parte en dos slivers alrededor de un centro fijo: lo cargado al
/// abrir (y el histórico antiguo) crece hacia arriba, y lo que llega después
/// crece hacia abajo. Como Flutter conserva el offset al cambiar la extensión,
/// nada de lo que llega mueve lo que se está leyendo. Con `anchor: 1` el
/// offset P pone la coordenada P de la zona nueva en el borde inferior.
///
/// Al empezar un turno (un prompt nuevo estando abajo) esa fila se «fija»: un
/// relleno al final deja sitio para subirla arriba del todo con un scroll
/// suave, y la respuesta va apareciendo debajo sin mover la vista.
class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();
  final _viewKey = GlobalKey();
  final _centerKey = UniqueKey();
  late final TherdController _ctl;

  /// Aviso efímero visible y su temporizador.
  Notice? _toast;
  Timer? _toastTimer;

  /// Items que han llegado mientras el usuario estaba arriba.
  int _unseen = 0;

  /// Última fila de la zona que crece hacia arriba (null: todo es zona nueva).
  String? _splitId;

  /// Fila fijada arriba y su coordenada en la zona nueva, una vez medida.
  String? _pinId;
  double? _pinStart;

  /// Claves para medir las filas de la zona nueva, una por fila.
  final _rowKeys = <String, GlobalKey>{};

  /// Filas ya vistas; solo las que llegan nuevas entran animadas.
  final _shown = <String>{};

  /// La lista acaba de montarse y hay que llevarla al final.
  bool _needsJump = true;

  /// El último prompt lo ha enviado este móvil: se fija aunque no esté abajo.
  bool _justSent = false;

  /// Último pane conocido de la sesión, para seguirla si cambia de id.
  String? _paneId;

  /// La sesión desapareció sin sucesora: si no llega, se vuelve a la lista.
  Timer? _goneTimer;

  /// Ya se ha sustituido este chat por otro (o se ha cerrado).
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _ctl = ref.read(therdProvider.notifier);
    _scroll.addListener(_onScroll);
    _paneId = ref.read(therdProvider).session(widget.sessionId)?.paneId;
    // No se toca el estado durante la construcción del árbol.
    Future.microtask(() => _ctl.openSession(widget.sessionId));
  }

  /// La lista de sesiones cambió: si la de este chat ya no está, se sigue a
  /// la que ocupa ahora su pane o, pasado un rato sin ninguna, se cierra.
  void _onSessions(List<SessionInfo> sessions) {
    if (_leaving || !mounted) return;
    final mine = sessions.where((s) => s.sessionId == widget.sessionId);
    if (mine.isNotEmpty) {
      _paneId = mine.first.paneId ?? _paneId;
      _goneTimer?.cancel();
      _goneTimer = null;
      return;
    }
    final next = successorInPane(sessions, _paneId);
    if (next != null) {
      _leaving = true;
      _goneTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(
          context,
        ).pushReplacement(chatRoute(next.sessionId, instant: true));
      });
      return;
    }
    _goneTimer ??= Timer(const Duration(seconds: 6), () {
      if (!mounted || _leaving) return;
      if (ref.read(therdProvider).session(widget.sessionId) != null) return;
      _leaving = true;
      Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _goneTimer?.cancel();
    _toastTimer?.cancel();
    _ctl.closeSession(widget.sessionId);
    _scroll.dispose();
    super.dispose();
  }

  /// El final de la conversación es el máximo del scroll.
  bool get _atBottom =>
      !_scroll.hasClients ||
      _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;

  void _onScroll() {
    _maybeLoadOlder();
    if (_unseen > 0 && _atBottom) setState(() => _unseen = 0);
  }

  /// Lo más antiguo está en el mínimo del scroll.
  void _maybeLoadOlder() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels <= p.minScrollExtent + 400) _ctl.loadOlder(widget.sessionId);
  }

  void _onItems(List<ChatItem>? prev, List<ChatItem> next) {
    if (prev == null || prev.isEmpty || next.isEmpty) return;
    if (next.last.id == prev.last.id) return;
    // Lo que va detrás del antiguo último item es nuevo; si ese item ya no
    // está (cambió la ventana de carga) no se cuenta.
    // Un provisional confirmado deja de estar: se ancla en el último item que
    // sigue en la lista.
    final nextIds = {for (final i in next) i.id};
    final anchor = prev.lastWhere(
      (i) => nextIds.contains(i.id),
      orElse: () => prev.first,
    );
    final at = next.indexWhere((i) => i.id == anchor.id);
    if (at < 0) return;
    final prevIds = {for (final i in prev) i.id};
    final added = [
      for (final i in next.sublist(at + 1))
        if (!prevIds.contains(i.id)) i,
    ];

    // El prompt real ocupa el sitio de su provisional: ni entra animado ni
    // abre otro turno, y hereda la fijación.
    final gone = [
      for (final i in prev)
        if (isLocalItem(i) && !nextIds.contains(i.id)) i.id,
    ];
    for (final localId in gone) {
      final real = added.whereType<UserPromptItem>().where(
        (i) => !isLocalItem(i),
      );
      if (real.isEmpty) break;
      final r = real.first;
      added.remove(r);
      _shown.add(r.id);
      if (_pinId == localId) _pinId = r.id;
    }
    if (added.isEmpty) return;

    final follow = _atBottom || _justSent;
    if (!follow) {
      setState(() => _unseen += added.length);
      return;
    }
    // Un prompt nuevo abre turno; sin turno fijado, lo primero que llegue.
    final prompt = added.whereType<UserPromptItem>().firstOrNull;
    final target = prompt ?? (_pinId == null ? added.first : null);
    if (target == null) return;
    _justSent = false;
    final rows = groupChatItems(next);
    final rowIdx = rows.indexWhere(
      (r) => r.items.any((i) => i.id == target.id),
    );
    final splitIdx = _splitId == null
        ? -1
        : rows.indexWhere((r) => r.id == _splitId);
    if (rowIdx <= splitIdx) return;
    setState(() => _pinId = rows[rowIdx].id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measurePin());
  }

  /// Mide dónde quedó la fila fijada y, con el relleno ya puesto, la sube.
  void _measurePin() {
    if (!mounted || !_scroll.hasClients || _pinId == null) return;
    final row = _rowKeys[_pinId]?.currentContext?.findRenderObject();
    final view = _viewKey.currentContext?.findRenderObject();
    if (row is! RenderBox || view is! RenderBox) {
      _toBottom();
      return;
    }
    final vp = _scroll.position.viewportDimension;
    final y = row.localToGlobal(Offset.zero, ancestor: view).dy;
    setState(() => _pinStart = _scroll.offset - vp + y);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _pinStart == null) return;
      final p = _scroll.position;
      final target = (_pinStart! + p.viewportDimension).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      );
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showToast(Notice n) {
    _toastTimer?.cancel();
    setState(() => _toast = n);
    _toastTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    setState(() => _unseen = 0);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.sessionId;
    final session = ref.watch(therdProvider.select((s) => s.session(id)));
    final chat = ref.watch(therdProvider.select((s) => s.chat(id)));
    final pendings = ref.watch(therdProvider.select((s) => s.pendingOf(id)));
    final link = ref.watch(therdProvider.select((s) => s.link));
    final c = context.tc;

    ref.listen(therdProvider.select((s) => s.notice), (prev, next) {
      if (next != null && next.id != prev?.id) _showToast(next);
    });
    ref.listen(therdProvider.select((s) => s.chat(id).view), _onItems);
    ref.listen(therdProvider.select((s) => s.sessions), (_, next) {
      _onSessions(next);
    });
    if (session?.paneId != null) _paneId = session!.paneId;

    final status = session?.status ?? SessionStatus.unknown;
    final working = status == SessionStatus.working;
    final hasPending = pendings.isNotEmpty;
    final finished =
        status == SessionStatus.idle || status == SessionStatus.done;

    final items = chat.view;
    final rows = groupChatItems(items);
    final showList = chat.loaded && items.isNotEmpty;

    // El centro se fija con lo cargado al abrir; si esa fila desaparece (otra
    // ventana de carga, reconexión) se vuelve a partir por el final.
    var splitIdx = _splitId == null
        ? -1
        : rows.indexWhere((r) => r.id == _splitId);
    if (showList && (_needsJump || (_splitId != null && splitIdx < 0))) {
      if (splitIdx < 0 && _splitId != null) _needsJump = true;
      _splitId = rows.last.id;
      splitIdx = rows.length - 1;
      _pinId = null;
      _pinStart = null;
      _shown.addAll(rows.map((r) => r.id));
    }
    if (!showList) _needsJump = true;
    final older = rows.sublist(0, splitIdx + 1);
    final newer = rows.sublist(splitIdx + 1);
    _rowKeys.removeWhere((id, _) => !newer.any((r) => r.id == id));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_needsJump) {
        _needsJump = false;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
      // Si el contenido no llena la pantalla no hay scroll que dispare la carga.
      if (_scroll.position.minScrollExtent > -400) _maybeLoadOlder();
    });

    Widget rowView(ChatRow row, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: EnterAnimation(
        animate: _shown.add(row.id),
        child: ChatRowView(key: ValueKey(row.id), row: row),
      ),
    );
    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          _ChatHeader(
            title: session == null ? 'Sesión' : sessionTitle(session),
            // Con el chat abierto lo terminado ya está leído.
            status: viewStatus(status),
            branch: session?.branch,
            contextUsed: session?.contextUsed,
          ),
          ConnectionBanner(status: link),
          Expanded(
            // El hueco entre la cabecera y el teclado, para medir la hoja.
            child: LayoutBuilder(
              builder: (context, box) => Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: !chat.loaded
                              ? const Center(
                                  child: Spinner(size: 24, stroke: 2.2),
                                )
                              : items.isEmpty
                              ? Center(
                                  child: Text(
                                    'Todavía no hay mensajes',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: c.muted,
                                    ),
                                  ),
                                )
                              : SelectionArea(
                                  child: CustomScrollView(
                                    key: _viewKey,
                                    controller: _scroll,
                                    center: _centerKey,
                                    anchor: 1,
                                    cacheExtent: 800,
                                    slivers: [
                                      // Zona antigua: crece hacia arriba desde el centro.
                                      SliverPadding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        sliver: SliverList.builder(
                                          itemCount: older.length + 1,
                                          itemBuilder: (context, index) {
                                            if (index == older.length) {
                                              // Extremo antiguo de la lista.
                                              return SizedBox(
                                                height: 40,
                                                child: chat.hasMore
                                                    ? const Center(
                                                        child: Spinner(
                                                          size: 18,
                                                        ),
                                                      )
                                                    : null,
                                              );
                                            }
                                            return rowView(
                                              older[older.length - 1 - index],
                                            );
                                          },
                                        ),
                                      ),
                                      // Zona nueva: crece hacia abajo sin mover la vista.
                                      SliverPadding(
                                        key: _centerKey,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        sliver: SliverList.builder(
                                          itemCount:
                                              newer.length + (working ? 1 : 0),
                                          itemBuilder: (context, index) {
                                            if (index == newer.length) {
                                              return const Padding(
                                                padding: EdgeInsets.symmetric(
                                                  vertical: 12,
                                                ),
                                                child: EnterAnimation(
                                                  animate: true,
                                                  child: ThinkingIndicator(),
                                                ),
                                              );
                                            }
                                            final row = newer[index];
                                            return rowView(
                                              row,
                                              key: _rowKeys.putIfAbsent(
                                                row.id,
                                                GlobalKey.new,
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      // Hueco para que el turno fijado quepa arriba.
                                      SliverLayoutBuilder(
                                        builder: (context, cons) {
                                          final pin = _pinStart;
                                          final fill = pin == null
                                              ? 0.0
                                              : pin +
                                                    cons.viewportMainAxisExtent -
                                                    cons.precedingScrollExtent;
                                          return SliverToBoxAdapter(
                                            child: SizedBox(
                                              height: fill > 12 ? fill : 12,
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                        if (_unseen > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 12,
                            child: Center(
                              child: _NewMessagesPill(
                                count: _unseen,
                                onTap: _toBottom,
                              ),
                            ),
                          ),
                        if (_toast != null)
                          Positioned(
                            left: 16,
                            right: 16,
                            top: 12,
                            child: _Toast(
                              key: ValueKey(_toast!.id),
                              notice: _toast!,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Con un pendiente, la hoja sustituye a la caja de texto.
                  if (hasPending)
                    PendingBar(
                      maxHeight: _sheetMax(context, box.maxHeight),
                      pending: pendings.first,
                      total: pendings.length,
                      onPermission:
                          ({required allow, always = false, message}) =>
                              _ctl.respondPermission(
                                pendings.first.requestId,
                                allow: allow,
                                always: always,
                                message: message,
                              ),
                      onAnswer: (a) => _ctl.answer(pendings.first.requestId, a),
                      onRelease: () => _ctl.release(pendings.first.requestId),
                    )
                  else
                    Composer(
                      enabled: link.isConnected,
                      working: working,
                      hint: link.isConnected
                          ? 'Escribe a Claude'
                          : 'Sin conexión',
                      quickReplies:
                          finished && link.isConnected && items.isNotEmpty
                          ? kQuickReplies
                          : const [],
                      onSend: (t, images) {
                        _justSent = true;
                        _ctl.sendPrompt(id, t, images: images);
                      },
                      onStop: () => _ctl.interrupt(id),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Alto máximo de la hoja de pendientes: media pantalla, y como mucho el
/// 80 % del hueco entre la cabecera y el teclado (con el teclado abierto la
/// media pantalla no cabe).
double _sheetMax(BuildContext context, double available) {
  final half = MediaQuery.sizeOf(context).height * 0.5;
  return half < available * 0.8 ? half : available * 0.8;
}

/// Cabecera propia: volver, título y estado en su color con la rama.
class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.title,
    required this.status,
    required this.branch,
    this.contextUsed,
  });

  final String title;
  final ViewStatus status;
  final String? branch;
  final double? contextUsed;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final hasBranch = branch != null && branch!.isNotEmpty;
    return Container(
      color: c.bg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 6),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: Tk.control,
                    child: IconButton(
                      tooltip: 'Volver a sesiones',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back, size: 20),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.18,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            // Con rama, el color del punto ya dice el estado y
                            // el texto queda para lectores de pantalla. Sin
                            // rama, el punto solo se ve suelto: lo acompaña el
                            // nombre del estado.
                            Semantics(
                              label: hasBranch ? viewLabel(status) : null,
                              child: StatusDot(status, size: 8),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                hasBranch ? branch! : viewLabel(status),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: hasBranch
                                    ? mono(size: 13, color: c.muted)
                                    : TextStyle(fontSize: 13, color: c.muted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (contextUsed != null) ...[
                    const SizedBox(width: 12),
                    ContextRing(used: contextUsed!),
                  ],
                ],
              ),
            ),
          ),
          Container(height: 1, color: c.line),
        ],
      ),
    );
  }
}

/// Píldora flotante «N mensajes nuevos» que baja al final.
class _NewMessagesPill extends StatelessWidget {
  const _NewMessagesPill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Material(
      color: c.text,
      elevation: 6,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 14, color: c.bg),
              const SizedBox(width: 6),
              Text(
                count == 1 ? '1 mensaje nuevo' : '$count mensajes nuevos',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.bg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Aviso efímero: píldora flotante `text` sobre `bg` con icono de alerta.
class _Toast extends StatelessWidget {
  const _Toast({super.key, required this.notice});

  final Notice notice;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: c.text,
        elevation: 8,
        shadowColor: Colors.black,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: c.bg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  notice.message,
                  style: TextStyle(fontSize: 14, color: c.bg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
