import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Pantalla de arranque animada, encima de la app.
///
/// Empieza donde la deja el arranque nativo: `th_` blanco sobre negro, como
/// el icono. El cursor parpadea, termina de escribir `therd` (el texto se
/// recentra con cada letra) y se abre hasta llenar la pantalla, dejando ver
/// la app por el hueco. Si la app aún no está lista, el cursor sigue
/// parpadeando hasta que lo esté.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.ready, required this.child});

  /// La app ya sabe qué pantalla enseñar.
  final bool ready;
  final Widget child;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> with TickerProviderStateMixin {
  /// Parpadeo inicial y escritura.
  late final AnimationController _type = AnimationController(
    vsync: this,
    duration: _kTypeDuration,
  )..addStatusListener((s) => _maybeReveal());

  /// Parpadeo del cursor mientras se espera a que la app esté lista.
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// Apertura del cursor hasta llenar la pantalla.
  late final AnimationController _reveal =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 620),
      )..addStatusListener((s) {
        if (s == AnimationStatus.completed) setState(() => _done = true);
      });

  bool _done = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Con las animaciones desactivadas en el sistema no hay espectáculo.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _done = true;
      return;
    }
    _type.forward();
  }

  @override
  void didUpdateWidget(SplashGate old) {
    super.didUpdateWidget(old);
    _maybeReveal();
  }

  void _maybeReveal() {
    if (_done || !_type.isCompleted || _reveal.isAnimating) return;
    if (!widget.ready) {
      if (!_idle.isAnimating) _idle.repeat();
      return;
    }
    _idle.stop();
    _reveal.forward();
  }

  @override
  void dispose() {
    _type.dispose();
    _idle.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // No bloquea: un toque durante la animación llega a la app.
        IgnorePointer(
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: Semantics(
              label: 'therd',
              child: CustomPaint(
                painter: _SplashPainter(
                  type: _type,
                  idle: _idle,
                  reveal: _reveal,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

const _kTypeDuration = Duration(milliseconds: 1250);

/// Momento (fracción de _kTypeDuration) en que se teclea cada letra nueva.
/// Ritmo algo irregular, como a mano.
const _kKeys = [('e', 0.38), ('r', 0.46), ('d', 0.56)];

/// Tamaño de la caja del logo en px lógicos. Debe coincidir con el del
/// arranque nativo (drawable/splash_logo.xml y drawable/splash_icon.xml).
const _kBox = 132.0;

// Geometría del logo (assets/logo/therd-glyph.svg) en unidades de su caja de
// 108: GeistMono SemiBold a 50 de cuerpo, celdas de 30, `t` en la celda que
// empieza en x=10 y línea base en y=65.9.
const _kEm = 50.0;
const _kCell = 30.0;
const _kCell0 = 10.0;
const _kBaseline = 65.9;
// El `_` de GeistMono: de 72 a 528 en x y 107 bajo la línea base (de 1000).
const _kCursorLeft = 0.072 * _kEm;
const _kCursorWidth = 0.456 * _kEm;
const _kCursorHeight = 0.107 * _kEm;

class _SplashPainter extends CustomPainter {
  _SplashPainter({required this.type, required this.idle, required this.reveal})
    : super(repaint: Listenable.merge([type, idle, reveal]));

  final Animation<double> type;
  final Animation<double> idle;
  final Animation<double> reveal;

  static const _black = Color(0xFF000000);
  static const _white = Color(0xFFFFFFFF);

  final Map<String, TextPainter> _glyphs = {};

  TextPainter _glyph(String ch, double fontSize) => _glyphs.putIfAbsent(
    ch,
    () => TextPainter(
      text: TextSpan(
        text: ch,
        style: TextStyle(
          fontFamily: kMono,
          fontWeight: FontWeight.w600,
          fontSize: fontSize,
          height: 1,
          color: _white,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final s = type.value;
    final r = Curves.easeInOutCubic.transform(reveal.value);
    final k = _kBox / 108; // px por unidad de la caja
    final center = size.center(Offset.zero);

    // Letras ya tecleadas y desplazamiento para mantener el texto centrado:
    // cada letra nueva corre el conjunto media celda a la izquierda.
    var typed = 0;
    var shift = 0.0;
    for (final (_, at) in _kKeys) {
      if (s < at) break;
      typed++;
      shift +=
          0.5 * Curves.easeOutCubic.transform(((s - at) / 0.1).clamp(0, 1));
    }

    // Unidades de la caja → pantalla, con la caja centrada en pantalla.
    double x(double u) => center.dx + (u - 54 - shift * _kCell) * k;
    double y(double u) => center.dy + (u - 54) * k;

    final cursorCell = 2 + typed;
    final cursorLeft = _kCell0 + cursorCell * _kCell + _kCursorLeft;
    final cursor = Rect.fromLTRB(
      x(cursorLeft),
      y(_kBaseline),
      x(cursorLeft + _kCursorWidth),
      y(_kBaseline + _kCursorHeight),
    );

    // Fondo negro con un hueco que nace del cursor y crece hasta la pantalla.
    final bg = Path()..addRect(Offset.zero & size);
    if (r > 0) {
      final hole = Rect.fromLTRB(
        lerpDouble(cursor.left, -1, r)!,
        lerpDouble(cursor.top, -1, r)!,
        lerpDouble(cursor.right, size.width + 1, r)!,
        lerpDouble(cursor.bottom, size.height + 1, r)!,
      );
      bg
        ..fillType = PathFillType.evenOdd
        ..addRRect(
          RRect.fromRectAndRadius(
            hole,
            Radius.circular(28 * math.sin(math.pi * r)),
          ),
        );
    }
    canvas.drawPath(bg, Paint()..color = _black);

    // Las letras se desvanecen en cuanto el cursor empieza a abrirse.
    final textAlpha = (1 - r * 3).clamp(0.0, 1.0);
    if (textAlpha > 0) {
      final fontSize = _kEm * k;
      final letters = [('t', -1.0), ('h', -1.0), for (final l in _kKeys) l];
      for (final (i, (ch, at)) in letters.take(2 + typed).indexed) {
        // Las nuevas entran con un rebote mínimo hacia arriba.
        final pop = at < 0 ? 1.0 : ((s - at) / 0.05).clamp(0.0, 1.0);
        final dy = 3 * (1 - Curves.easeOutBack.transform(pop));
        final tp = _glyph(ch, fontSize);
        final baseline = tp.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        );
        final pos = Offset(
          x(_kCell0 + i * _kCell),
          y(_kBaseline + dy) - baseline,
        );
        if (textAlpha < 1 || pop < 1) {
          canvas.saveLayer(
            null,
            Paint()
              ..color = _white.withValues(alpha: textAlpha * (0.4 + 0.6 * pop)),
          );
          tp.paint(canvas, pos);
          canvas.restore();
        } else {
          tp.paint(canvas, pos);
        }
      }
    }

    // El cursor: parpadeo duro, como en una terminal.
    if (r == 0 && _cursorOn(s)) {
      canvas.drawRect(cursor, Paint()..color = _white);
    }
  }

  bool _cursorOn(double s) {
    if (idle.isAnimating) return idle.value < 0.55;
    // Dos parpadeos sobre `th_`, cursor fijo al teclear y uno al terminar.
    if (s < 0.10) return true;
    if (s < 0.18) return false;
    if (s < 0.27) return true;
    if (s < 0.35) return false;
    if (s < 0.74) return true;
    if (s < 0.84) return false;
    return true;
  }

  @override
  bool shouldRepaint(_SplashPainter old) => false;
}
