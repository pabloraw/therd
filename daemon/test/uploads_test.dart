import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:therd_daemon/src/uploads.dart';
import 'package:therd_protocol/protocol.dart';

import 'support.dart';

void main() {
  test('texto del prompt con una y varias imágenes', () {
    expect(promptWithImages(' hola ', []), 'hola');
    expect(promptWithImages('', ['/a.png']), '/a.png');
    expect(
      promptWithImages('mira', ['/a.png', '/b.jpg']),
      'mira\n\n/a.png\n/b.jpg',
    );
  });

  test('el texto pintado no lleva rutas subidas ni marcas de imagen', () {
    const up = '/home/u/.cache/therd/uploads/20261120-101010-abcd1234';
    expect(cleanPromptText('mira\n\n$up.png\n$up.jpg'), 'mira');
    expect(cleanPromptText('$up.webp'), '');
    expect(cleanPromptText('[Image #11]Imagen adjunta:'), '');
    expect(cleanPromptText('mira [Image #2] esto'), 'mira  esto');
    // Otras rutas o frases se quedan.
    expect(cleanPromptText('lee /tmp/x.png'), 'lee /tmp/x.png');
    expect(cleanPromptText('hora: 10:00'), 'hora: 10:00');
  });

  test('prune borra solo las viejas', () async {
    final dir = makeTemp('up').path;
    final u = Uploads(dir, keep: const Duration(days: 7));
    final old = File('$dir/20260101-000000-aaaaaaaa.png')
      ..writeAsBytesSync([1]);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
    final fresh = File('$dir/20260101-000001-bbbbbbbb.png')
      ..writeAsBytesSync([1]);
    await u.prune();
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('una imagen que no vale no deja nada escrito', () async {
    final dir = makeTemp('up2').path;
    final u = Uploads(dir, maxBytes: 4);
    await expectLater(u.save(const []).then((p) => p), completion(isEmpty));
    await expectLater(
      u.save(const [PromptImage(mime: 'image/png', data: 'AAAAAAAA')]),
      throwsA(isA<UploadException>()),
    );
    expect(Directory(dir).listSync(), isEmpty);
  });

  test('rechaza base64 desmesurado y demasiadas imágenes', () async {
    final dir = makeTemp('up3').path;
    final u = Uploads(dir, maxBytes: 300);
    await expectLater(
      u.save([PromptImage(mime: 'image/png', data: 'A' * 1000)]),
      throwsA(isA<UploadException>()),
    );
    final ok = PromptImage(mime: 'image/png', data: base64Encode([1, 2, 3]));
    expect(await u.save(List.filled(Uploads.maxImages, ok)), hasLength(4));
    await expectLater(
      u.save(List.filled(Uploads.maxImages + 1, ok)),
      throwsA(isA<UploadException>()),
    );
  });

  test('prune solo borra archivos con el nombre que genera Uploads', () async {
    final dir = makeTemp('up4').path;
    final u = Uploads(dir, keep: const Duration(days: 7));
    final img = PromptImage(mime: 'image/png', data: base64Encode([1]));
    final saved = File((await u.save([img])).single);
    final ajeno = File('$dir/notas.txt')..writeAsBytesSync([1]);
    final viejo = DateTime.now().subtract(const Duration(days: 9));
    saved.setLastModifiedSync(viejo);
    ajeno.setLastModifiedSync(viejo);
    await u.prune();
    expect(saved.existsSync(), isFalse);
    expect(ajeno.existsSync(), isTrue);
  });
}
