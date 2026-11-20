import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

// La cámara es siempre oscura, aunque el tema sea claro: colores fijos.
const _camBg = Color(0xFF0C0B0A);
const _camVeil = Color(0xFF24211E);
const _camText = Color(0xFFEDEAE4);
const _camMuted = Color(0xFFA8A299);
const _camBorder = Color(0xFF3A3631);
const _camBack = Color(0xD91F1D1A); // surface al 85 %
const _errBg = Color(0xFF161513);

/// Lee un QR y devuelve su texto con Navigator.pop. Si el usuario prefiere
/// escribir los datos, hace pop sin valor.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.startsWith('therd://')) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _camBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) => state.error != null
                ? _CameraError(onManual: _close)
                : _Viewfinder(
                    controller: _controller,
                    onDetect: _onDetect,
                    onManual: _close,
                  ),
          ),
          Positioned(
            left: 12,
            top: 12,
            child: SafeArea(
              child: Material(
                color: _camBack,
                borderRadius: Tk.brCard,
                child: InkWell(
                  borderRadius: Tk.brCard,
                  onTap: _close,
                  child: const SizedBox(
                    width: Tk.control,
                    height: Tk.control,
                    child: Icon(
                      Icons.arrow_back,
                      size: 20,
                      color: _camText,
                      semanticLabel: 'Volver',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Viewfinder extends StatelessWidget {
  const _Viewfinder({
    required this.controller,
    required this.onDetect,
    required this.onManual,
  });

  final MobileScannerController controller;
  final void Function(BarcodeCapture) onDetect;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(controller: controller, onDetect: onDetect),
        IgnorePointer(
          child: ColoredBox(color: _camVeil.withValues(alpha: 0.5)),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(
              children: [
                const SizedBox(height: 72),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text.rich(
                    TextSpan(
                      text: 'Apunta al QR que muestra ',
                      children: [
                        TextSpan(
                          text: 'therd pair',
                          style: mono(
                            size: 22,
                            color: _camText,
                            weight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    style: const TextStyle(
                      fontFamily: kSans,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      letterSpacing: -0.22,
                      color: _camText,
                    ),
                  ),
                ),
                const Spacer(),
                const SizedBox(
                  width: 280,
                  height: 280,
                  child: CustomPaint(painter: _CornersPainter()),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Se cierra sola al leer un QR de therd',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: kSans,
                    fontSize: 14,
                    color: _camMuted,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: onManual,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _camText,
                      side: const BorderSide(color: _camBorder),
                      textStyle: const TextStyle(
                        fontFamily: kSans,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: const Text('Escribir los datos a mano'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Cuatro esquinas de 3 px, brazos de 44 px y radio 20.
class _CornersPainter extends CustomPainter {
  const _CornersPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = _camText
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.butt;
    const a = 44.0;
    const r = 20.0;
    final w = size.width;
    final h = size.height;
    const half = 1.5; // el trazo queda dentro del marco
    final path = Path()
      // arriba izquierda
      ..moveTo(half, a)
      ..lineTo(half, r)
      ..arcToPoint(const Offset(r, half), radius: const Radius.circular(r))
      ..lineTo(a, half)
      // arriba derecha
      ..moveTo(w - a, half)
      ..lineTo(w - r, half)
      ..arcToPoint(Offset(w - half, r), radius: const Radius.circular(r))
      ..lineTo(w - half, a)
      // abajo derecha
      ..moveTo(w - half, h - a)
      ..lineTo(w - half, h - r)
      ..arcToPoint(Offset(w - r, h - half), radius: const Radius.circular(r))
      ..lineTo(w - a, h - half)
      // abajo izquierda
      ..moveTo(a, h - half)
      ..lineTo(r, h - half)
      ..arcToPoint(Offset(half, h - r), radius: const Radius.circular(r))
      ..lineTo(half, h - a);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_CornersPainter old) => false;
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.onManual});

  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _errBg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                size: 40,
                color: Color(0xFFEFA59C),
              ),
              const SizedBox(height: 16),
              const Text(
                'No se pudo abrir la cámara.',
                style: TextStyle(
                  fontFamily: kSans,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                  letterSpacing: -0.22,
                  color: _camText,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Revisa el permiso o escribe los datos a mano.',
                style: TextStyle(
                  fontFamily: kSans,
                  fontSize: 15,
                  height: 1.5,
                  color: _camMuted,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onManual,
                style: FilledButton.styleFrom(
                  backgroundColor: _camText,
                  foregroundColor: _errBg,
                ),
                child: const Text('Escribir a mano'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
