import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:therd_daemon/src/images.dart';
import 'package:therd_daemon/src/transcript_parser.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

String pngB64(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (final px in im) {
    px
      ..r = (px.x * 7) % 256
      ..g = (px.y * 13) % 256
      ..b = (px.x * px.y) % 256;
  }
  return base64.encode(img.encodePng(im));
}

Map<String, dynamic> imageBlock(String data) => {
  'type': 'image',
  'source': {'type': 'base64', 'media_type': 'image/png', 'data': data},
};

void main() {
  test('el mismo contenido da el mismo id y se guarda una vez', () {
    final store = ImageStore(makeTemp('img').path);
    final data = pngB64(4, 4);
    final a = store.putBlock(imageBlock(data));
    expect(a, matches(RegExp(r'^[0-9a-f]{24}\.png$')));
    expect(store.putBlock(imageBlock(data)), a);
    expect(store.file(a!)!.readAsBytesSync(), base64.decode(data));
    expect(store.putBlock({'type': 'text'}), isNull);
    expect(store.file('../config.json'), isNull);
  });

  test('miniatura: JPEG reducido; una pequeña se sirve tal cual', () async {
    final store = ImageStore(makeTemp('img').path, thumbSide: 64);
    final big = store.put('image/png', pngB64(400, 200))!;
    final t = (await store.thumb(big))!;
    expect(t.path, endsWith('.t64.jpeg'));
    final dec = img.decodeJpg(t.readAsBytesSync())!;
    expect((dec.width, dec.height), (64, 32));

    final small = store.put('image/png', pngB64(10, 10))!;
    expect((await store.thumb(small))!.path, store.file(small)!.path);
  });

  test('el parser da ids en prompts y resultados', () {
    final store = ImageStore(makeTemp('img').path);
    final parser = TranscriptParser('s', images: store);
    final data = pngB64(3, 3);
    final prompt = parser.parseLine(
      jsonEncode({
        'type': 'user',
        'uuid': 'u1',
        'timestamp': '2026-11-20T10:00:00Z',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'mira [Image #11]'},
            imageBlock(data),
          ],
        },
      }),
    );
    final item = (prompt.single as ItemEvent).item as UserPromptItem;
    expect(item.text, 'mira');
    expect(item.images, [store.put('image/png', data)]);

    final res = parser.parseLine(
      jsonEncode({
        'type': 'user',
        'uuid': 'u2',
        'timestamp': '2026-11-20T10:00:01Z',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_1',
              'content': [
                {'type': 'text', 'text': 'captura'},
                imageBlock(data),
              ],
            },
          ],
        },
      }),
    );
    final r = res.single as ToolResultEvent;
    expect(r.result, 'captura');
    expect(r.images, item.images);
  });

  test('sin store se pintan como [imagen]', () {
    final parser = TranscriptParser('s');
    final ev = parser.parseLine(
      jsonEncode({
        'type': 'user',
        'uuid': 'u1',
        'timestamp': '2026-11-20T10:00:00Z',
        'message': {
          'role': 'user',
          'content': [imageBlock(pngB64(2, 2))],
        },
      }),
    );
    final item = (ev.single as ItemEvent).item as UserPromptItem;
    expect(item.text, '[imagen]');
    expect(item.images, isEmpty);
  });

  test('prune borra lo propio viejo y respeta archivos ajenos', () async {
    final dir = makeTemp('img').path;
    final old = DateTime.now().subtract(const Duration(days: 40));
    final hash = 'a' * 24;
    final propios = [
      File('$dir/$hash.png'),
      File('$dir/$hash.t1024.jpeg'),
      File('$dir/$hash.png.tmp'),
    ];
    final ajenos = [File('$dir/notas.txt'), File('$dir/x.png')];
    for (final f in [...propios, ...ajenos]) {
      f
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(old);
    }
    await ImageStore(dir).prune();
    for (final f in propios) {
      expect(f.existsSync(), isFalse, reason: f.path);
    }
    for (final f in ajenos) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }
  });
}
