import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Desde qué fracción de contexto usado se avisa: falta poco para compactar.
const double contextWarnAt = 0.70;

/// Rosco con el porcentaje de la ventana de contexto que ocupa la sesión.
/// Desde [contextWarnAt] se pinta en el color de aviso.
class ContextRing extends StatelessWidget {
  const ContextRing({
    super.key,
    required this.used,
    this.size = 36,
    this.showLabel = true,
  });

  /// Fracción usada, de 0 a 1.
  final double used;

  /// Lado del rosco en px.
  final double size;

  /// Si se pinta el número dentro (en tamaños pequeños no cabe).
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final pct = (used * 100).round();
    final color = used >= contextWarnAt ? c.waitFg : c.muted;
    return Semantics(
      label: 'Contexto usado: $pct %',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(
            used: used,
            track: c.line,
            color: color,
            stroke: size >= 28 ? 3 : 2,
          ),
          child: showLabel
              ? Center(
                  child: Text(
                    '$pct',
                    style: mono(
                      size: 11,
                      color: color,
                      weight: FontWeight.w600,
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.used,
    required this.track,
    required this.color,
    required this.stroke,
  });

  final double used;
  final Color track;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = track);
    if (used <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * used,
      false,
      paint
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.used != used ||
      old.track != track ||
      old.color != color ||
      old.stroke != stroke;
}
