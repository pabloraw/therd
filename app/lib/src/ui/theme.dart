import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:therd_protocol/protocol.dart';

/// Familias de texto: Geist para todo, Geist Mono solo para lo que es código
/// o máquina (comandos, rutas, ramas, IPs, tokens, diffs).
const kSans = 'Geist';
const kMono = 'GeistMono';

/// Colores fijos del punto de estado (iguales en claro y oscuro).
const kDotWait = Color(0xFFE0685C);
const kDotUnread = Color(0xFF6AA6D6);
const kDotWork = Color(0xFFD4A24C);
const kDotDone = Color(0xFF6FB98A);
const kDotUnknown = Color(0xFF77716A);

/// Tokens de la guía «Cayado» (docs/design-brief.md). Interfaz monocroma: el
/// único color es el de los estados y los errores.
@immutable
class TherdColors extends ThemeExtension<TherdColors> {
  const TherdColors({
    required this.bg,
    required this.surface,
    required this.cont,
    required this.cont2,
    required this.line,
    required this.text,
    required this.muted,
    required this.faint,
    required this.code,
    required this.waitFg,
    required this.unreadFg,
    required this.workFg,
    required this.okFg,
    required this.addFg,
    required this.delFg,
  });

  /// Fondo de pantalla.
  final Color bg;

  /// Barras fijas, hoja de pendiente, grupos de herramientas.
  final Color surface;

  /// Mensaje del usuario, fila pulsada, opción elegida, filtro activo.
  final Color cont;

  /// Botón desactivado, selección.
  final Color cont2;

  /// Separadores, bordes de botones secundarios, línea de árbol.
  final Color line;

  /// Texto principal; también fondo de la acción principal.
  final Color text;

  /// Texto secundario: ramas, rutas, descripciones.
  final Color muted;

  /// Lo que se camufla: marcadores de turno.
  final Color faint;

  /// Fondo de bloques de código y diffs.
  final Color code;

  /// Texto de estado (variante legible sobre el fondo del tema).
  final Color waitFg;
  final Color unreadFg;
  final Color workFg;
  final Color okFg;

  /// Texto de diffs.
  final Color addFg;
  final Color delFg;

  // Fondos tenues: el color del punto al 13–15 %.
  Color get waitSoft => kDotWait.withValues(alpha: 0.14);
  Color get unreadSoft => kDotUnread.withValues(alpha: 0.13);
  Color get workSoft => kDotWork.withValues(alpha: 0.13);
  Color get okSoft => kDotDone.withValues(alpha: 0.13);
  Color get addSoft => kDotDone.withValues(alpha: 0.15);
  Color get delSoft => kDotWait.withValues(alpha: 0.15);

  /// Borde de la acción negativa (rojo al 45 %) y de Detener (al 60 %).
  Color get negativeBorder => kDotWait.withValues(alpha: 0.45);
  Color get stopBorder => kDotWait.withValues(alpha: 0.6);

  static const dark = TherdColors(
    bg: Color(0xFF161513),
    surface: Color(0xFF1F1D1A),
    cont: Color(0xFF2A2724),
    cont2: Color(0xFF332F2B),
    line: Color(0xFF34302C),
    text: Color(0xFFEDEAE4),
    muted: Color(0xFFA8A299),
    faint: Color(0xFF5E5953),
    code: Color(0xFF11100E),
    waitFg: Color(0xFFEFA59C),
    unreadFg: Color(0xFFA4C8E8),
    workFg: Color(0xFFE6C17E),
    okFg: Color(0xFF8FCBA4),
    addFg: Color(0xFFA6D9B5),
    delFg: Color(0xFFEFA59C),
  );

  static const light = TherdColors(
    bg: Color(0xFFFBFAF7),
    surface: Color(0xFFFFFFFF),
    cont: Color(0xFFF1EEE8),
    cont2: Color(0xFFE8E4DC),
    line: Color(0xFFE3DED5),
    text: Color(0xFF1C1B19),
    muted: Color(0xFF5F5A52),
    faint: Color(0xFFB3ADA3),
    code: Color(0xFFF4F1EB),
    waitFg: Color(0xFFA93A30),
    unreadFg: Color(0xFF2F6690),
    workFg: Color(0xFF8A5A12),
    okFg: Color(0xFF2F7A4B),
    addFg: Color(0xFF2F6B42),
    delFg: Color(0xFF8F3128),
  );

  @override
  TherdColors copyWith() => this;

  @override
  TherdColors lerp(TherdColors? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

extension TherdThemeX on BuildContext {
  /// Tokens del tema activo.
  TherdColors get tc =>
      Theme.of(this).extension<TherdColors>() ?? TherdColors.dark;
}

/// Medidas compartidas.
abstract final class Tk {
  static const control = 44.0;
  static const radius = 10.0;
  static const radiusCard = 12.0;
  static const radiusSheet = 16.0;
  static final br = BorderRadius.circular(radius);
  static final brCard = BorderRadius.circular(radiusCard);
}

/// Texto en Geist Mono (rama, ruta, resumen de herramienta, código).
TextStyle mono({double size = 12, Color? color, FontWeight? weight}) =>
    TextStyle(
      fontFamily: kMono,
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: 1.4,
    );

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final c = dark ? TherdColors.dark : TherdColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.text,
    onPrimary: c.bg,
    secondary: c.muted,
    onSecondary: c.bg,
    error: c.waitFg,
    onError: c.bg,
    surface: c.bg,
    onSurface: c.text,
    onSurfaceVariant: c.muted,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.cont,
    surfaceContainerHighest: c.cont2,
    outline: c.muted,
    outlineVariant: c.line,
    primaryContainer: c.cont,
    onPrimaryContainer: c.text,
    secondaryContainer: c.cont,
    onSecondaryContainer: c.text,
    tertiaryContainer: c.workSoft,
    onTertiaryContainer: c.workFg,
    errorContainer: c.waitSoft,
    onErrorContainer: c.waitFg,
    inverseSurface: c.text,
    onInverseSurface: c.bg,
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: kSans,
  ).textTheme;
  final text = base
      .copyWith(
        headlineSmall: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.56,
          height: 1.2,
        ),
        titleLarge: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        titleMedium: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.18,
        ),
        bodyLarge: const TextStyle(fontSize: 16, height: 1.6),
        bodyMedium: const TextStyle(fontSize: 15, height: 1.5),
        bodySmall: const TextStyle(fontSize: 13, height: 1.45),
        labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        labelMedium: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        labelSmall: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
      )
      .apply(fontFamily: kSans, bodyColor: c.text, displayColor: c.text);

  final shape = RoundedRectangleBorder(borderRadius: Tk.br);
  const minSize = Size(Tk.control, Tk.control);
  const btnText = TextStyle(
    fontFamily: kSans,
    fontSize: 14,
    fontWeight: FontWeight.w500,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: kSans,
    textTheme: text,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashFactory: InkRipple.splashFactory,
    highlightColor: c.cont,
    splashColor: c.cont,
    hoverColor: c.cont,
    dividerColor: c.line,
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    extensions: [c],
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: c.bg,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge,
    ),
    iconTheme: IconThemeData(color: c.text, size: 20),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.text,
        minimumSize: minSize,
        shape: RoundedRectangleBorder(borderRadius: Tk.brCard),
      ),
    ),
    // Principal: fondo `text`, texto `bg`. Solo una por grupo.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.text,
        foregroundColor: c.bg,
        disabledBackgroundColor: c.cont2,
        disabledForegroundColor: c.muted,
        minimumSize: minSize,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: shape,
        elevation: 0,
        textStyle: btnText.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    // Secundaria: sin fondo, borde de 1 px en `line`.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        disabledForegroundColor: c.muted,
        side: BorderSide(color: c.line),
        minimumSize: minSize,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: shape,
        textStyle: btnText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.muted,
        minimumSize: minSize,
        shape: shape,
        textStyle: btnText.copyWith(fontSize: 13),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: TextStyle(color: c.muted),
      labelStyle: TextStyle(color: c.muted),
      errorStyle: TextStyle(color: c.waitFg, fontWeight: FontWeight.w500),
      border: OutlineInputBorder(
        borderRadius: Tk.br,
        borderSide: BorderSide(color: c.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: Tk.br,
        borderSide: BorderSide(color: c.line),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: Tk.br,
        borderSide: BorderSide(color: c.line.withValues(alpha: 0.5)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: Tk.br,
        borderSide: BorderSide(color: c.muted),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: Tk.br,
        borderSide: const BorderSide(color: kDotWait),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: Tk.br,
        borderSide: const BorderSide(color: kDotWait),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.text,
      selectionColor: c.cont2,
      selectionHandleColor: c.muted,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.muted,
      linearTrackColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.text,
      contentTextStyle: TextStyle(fontFamily: kSans, color: c.bg, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 6,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()},
    ),
  );
}

/// Estado tal como se pinta. «Sin leer» lo decide la app (lo visto en el
/// móvil), no herdr.
enum ViewStatus { working, blocked, unread, read, unknown }

ViewStatus viewStatus(
  SessionStatus s, {
  bool unread = false,
  bool hasPending = false,
}) {
  if (hasPending || s == SessionStatus.blocked) return ViewStatus.blocked;
  return switch (s) {
    SessionStatus.working => ViewStatus.working,
    SessionStatus.idle ||
    SessionStatus.done => unread ? ViewStatus.unread : ViewStatus.read,
    _ => ViewStatus.unknown,
  };
}

/// Prioridad para resumir varias sesiones en un solo punto (mayor gana):
/// esperando > sin leer > trabajando > leído > desconocido.
int viewPriority(ViewStatus v) => switch (v) {
  ViewStatus.blocked => 4,
  ViewStatus.unread => 3,
  ViewStatus.working => 2,
  ViewStatus.read => 1,
  ViewStatus.unknown => 0,
};

/// Color del punto: los tonos de herdr, desaturados.
Color viewColor(ViewStatus v) => switch (v) {
  ViewStatus.working => kDotWork,
  ViewStatus.blocked => kDotWait,
  ViewStatus.unread => kDotUnread,
  ViewStatus.read => kDotDone,
  ViewStatus.unknown => kDotUnknown,
};

/// Color del texto de estado, con contraste 4,5:1 sobre el fondo del tema.
Color viewTextColor(ViewStatus v, TherdColors c) => switch (v) {
  ViewStatus.working => c.workFg,
  ViewStatus.blocked => c.waitFg,
  ViewStatus.unread => c.unreadFg,
  ViewStatus.read => c.okFg,
  ViewStatus.unknown => c.muted,
};

String viewLabel(ViewStatus v) => switch (v) {
  ViewStatus.working => 'Trabajando',
  ViewStatus.blocked => 'Esperando respuesta',
  ViewStatus.unread => 'Terminado, sin leer',
  ViewStatus.read => 'Libre',
  ViewStatus.unknown => 'Desconocido',
};

/// Punto de estado: relleno, salvo «leído» y «desconocido», que son un anillo
/// de 2 px.
///
/// Los cambios de estado se animan: el color se mezcla y el relleno crece o
/// mengua desde el centro. Al entrar en «te espera» el punto da un salto y
/// suelta una onda; al entrar en «sin leer», solo el salto. Al aparecer no se
/// anima (si no, toda la lista latiría al abrirla).
class StatusDot extends StatefulWidget {
  const StatusDot(this.status, {super.key, this.size = 11});
  final ViewStatus status;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with TickerProviderStateMixin {
  /// Mezcla del estado anterior al nuevo (1 = ya en el nuevo).
  late final AnimationController _change = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: 1,
  );

  /// Salto y onda al llegar a un estado que pide atención (1 = en reposo).
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
    value: 1,
  );

  late Color _fromColor = viewColor(widget.status);
  late double _fromFill = _fill(widget.status);
  bool _ripple = false;

  static double _fill(ViewStatus s) =>
      s == ViewStatus.read || s == ViewStatus.unknown ? 0 : 1;

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    if (old.status == widget.status) return;
    // Se parte de lo que se ve ahora, aunque la mezcla anterior no acabara.
    final t = Curves.easeOut.transform(_change.value);
    _fromColor = Color.lerp(_fromColor, viewColor(old.status), t)!;
    _fromFill += (_fill(old.status) - _fromFill) * t;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _change.value = 1;
      return;
    }
    _change.forward(from: 0);
    if (widget.status == ViewStatus.blocked ||
        widget.status == ViewStatus.unread) {
      _ripple = widget.status == ViewStatus.blocked;
      _pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _change.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_change, _pulse]),
      builder: (context, _) {
        final t = Curves.easeOut.transform(_change.value);
        final to = viewColor(widget.status);
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _DotPainter(
            color: Color.lerp(_fromColor, to, t)!,
            fill: _fromFill + (_fill(widget.status) - _fromFill) * t,
            pulse: _pulse.value,
            ripple: _ripple,
          ),
        );
      },
    );
  }
}

class _DotPainter extends CustomPainter {
  const _DotPainter({
    required this.color,
    required this.fill,
    required this.pulse,
    required this.ripple,
  });

  final Color color;

  /// 0 = anillo, 1 = relleno.
  final double fill;

  /// Progreso del salto y la onda (1 = en reposo).
  final double pulse;
  final bool ripple;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    // Onda: sale del punto, crece hasta casi tres veces y se apaga.
    if (ripple && pulse < 1) {
      final k = Curves.easeOutCubic.transform(pulse);
      canvas.drawCircle(
        c,
        r * (1 + 1.8 * k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: 0.55 * (1 - k)),
      );
    }

    // Salto: crece un 35 % y vuelve, en el primer 40 % del pulso.
    final pop = pulse < 0.4 ? math.sin(math.pi * pulse / 0.4) : 0.0;
    final rr = r * (1 + 0.35 * pop);

    // Anillo de 2 px que engorda hacia dentro hasta cerrarse en un punto
    // relleno: una sola pieza, sin juntas que dejen ver una raya.
    if (fill >= 1) {
      canvas.drawCircle(c, rr, Paint()..color = color);
    } else {
      final sw = 2 + (rr - 2) * fill;
      canvas.drawCircle(
        c,
        rr - sw / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_DotPainter old) =>
      old.color != color ||
      old.fill != fill ||
      old.pulse != pulse ||
      old.ripple != ripple;
}

/// Spinner fino para estados de carga y reconexión.
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.size = 14, this.color, this.stroke = 2});
  final double size;
  final Color? color;
  final double stroke;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(
      strokeWidth: stroke,
      color: color ?? context.tc.muted,
    ),
  );
}

/// Logo de therd: «th_» en GeistMono blanco sobre un cuadrado negro redondeado.
///
/// Proporciones de la referencia de 64 px: radio 15, texto 30 px, filete
/// interior de 1 px #2A2724 y el texto subido 0,12 em.
class TherdLogo extends StatelessWidget {
  const TherdLogo({super.key, this.size = 64});
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = size / 64;
    final fontSize = 30 * k;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF000000),
        borderRadius: BorderRadius.circular(15 * k),
        border: Border.all(
          color: const Color(0xFF2A2724),
          width: k < 1 ? 1 : k,
        ),
      ),
      child: Transform.translate(
        offset: Offset(0, -0.12 * fontSize),
        child: Text(
          'th_',
          maxLines: 1,
          softWrap: false,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: kMono,
            fontWeight: FontWeight.w600,
            fontSize: fontSize,
            letterSpacing: -0.02 * fontSize,
            height: 1,
            color: const Color(0xFFFFFFFF),
          ),
        ),
      ),
    );
  }
}
