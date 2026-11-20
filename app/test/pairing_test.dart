import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/core/connection_config.dart';

void main() {
  test('parsea una URL therd completa', () {
    final c = ConnectionConfig.tryParse(
      'therd://100.64.0.7:24601?token=abc123',
    );
    expect(c, isNotNull);
    expect(c!.host, '100.64.0.7');
    expect(c.port, 24601);
    expect(c.token, 'abc123');
  });

  test('usa el puerto por defecto si falta', () {
    final c = ConnectionConfig.tryParse('therd://mi-pc.tailnet.ts.net?token=x');
    expect(c!.port, ConnectionConfig.defaultPort);
    expect(c.host, 'mi-pc.tailnet.ts.net');
  });

  test('tolera espacios alrededor y tokens con símbolos', () {
    final c = ConnectionConfig.tryParse(
      '  therd://1.2.3.4:5000?token=a-b_c%2Bd  ',
    );
    expect(c!.token, 'a-b_c+d');
    expect(c.port, 5000);
  });

  test('rechaza esquema distinto, sin token o sin host', () {
    expect(ConnectionConfig.tryParse('http://1.2.3.4:1?token=x'), isNull);
    expect(ConnectionConfig.tryParse('therd://1.2.3.4:24601'), isNull);
    expect(ConnectionConfig.tryParse('therd://1.2.3.4:24601?token='), isNull);
    expect(ConnectionConfig.tryParse('therd://?token=x'), isNull);
    expect(ConnectionConfig.tryParse('basura'), isNull);
  });

  test('la URL del websocket lleva el token en la query', () {
    const c = ConnectionConfig(host: '100.1.1.1', port: 24601, token: 'tk');
    expect(c.webSocketUri.toString(), 'ws://100.1.1.1:24601/?token=tk');
  });
}
