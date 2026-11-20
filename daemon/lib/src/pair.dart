import 'package:qr/qr.dart';

/// URL de emparejamiento que lee la app.
String pairingUrl(String host, int port, String token) =>
    'therd://$host:$port?token=$token';

/// Dibuja un QR en ASCII (medios bloques, negro sobre blanco con ANSI).
String renderQr(String data, {bool color = true}) {
  final code = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final img = QrImage(code);
  final n = img.moduleCount;
  const quiet = 2;
  bool dark(int r, int c) =>
      r >= 0 && c >= 0 && r < n && c < n && img.isDark(r, c);

  final buf = StringBuffer();
  for (var r = -quiet; r < n + quiet; r += 2) {
    if (color) buf.write('\x1b[30;47m');
    for (var c = -quiet; c < n + quiet; c++) {
      final top = dark(r, c);
      final bottom = dark(r + 1, c);
      buf.write(
        top && bottom
            ? '█'
            : top
            ? '▀'
            : bottom
            ? '▄'
            : ' ',
      );
    }
    if (color) buf.write('\x1b[0m');
    buf.writeln();
  }
  return buf.toString();
}
