import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:therd_protocol/protocol.dart';

import '../core/connection_config.dart';
import '../data/app_state.dart' show localImages;
import '../data/therd_controller.dart';
import 'theme.dart';

/// URL de la imagen [id] en el daemon; con [full] el original, si no la
/// miniatura ligera.
Uri imageUri(ConnectionConfig cfg, String id, {bool full = false}) => Uri(
  scheme: 'http',
  host: cfg.host,
  port: cfg.port,
  path: imagePath(id),
  queryParameters: full ? {'full': '1'} : null,
);

/// Imágenes de un mensaje o de un resultado: una sola ocupa el ancho, varias
/// van en cuadrados. Al tocarlas se abren a pantalla completa.
class ChatImages extends StatelessWidget {
  const ChatImages({super.key, required this.ids});

  final List<String> ids;

  @override
  Widget build(BuildContext context) {
    if (ids.length == 1) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ChatImage(id: ids.single, fit: BoxFit.contain),
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final id in ids)
          SizedBox.square(
            dimension: 120,
            child: ChatImage(id: id, fit: BoxFit.cover),
          ),
      ],
    );
  }
}

class ChatImage extends ConsumerWidget {
  const ChatImage({super.key, required this.id, this.fit = BoxFit.cover});

  final String id;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(therdProvider.select((s) => s.config));
    return GestureDetector(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => ImageViewer(id: id))),
      child: ClipRRect(
        borderRadius: Tk.br,
        child: _image(context, cfg, id, fit: fit, full: false),
      ),
    );
  }
}

Widget _image(
  BuildContext context,
  ConnectionConfig? cfg,
  String id, {
  required BoxFit fit,
  required bool full,
}) {
  final c = context.tc;
  final local = localImages[id];
  Widget broken() => Container(
    color: c.cont2,
    width: 120,
    height: 120,
    alignment: Alignment.center,
    child: Icon(Icons.broken_image_outlined, color: c.faint),
  );
  if (local != null) {
    return Image.memory(
      local,
      fit: fit,
      cacheWidth: full ? null : 1024,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => broken(),
    );
  }
  if (cfg == null) return broken();
  return Image.network(
    imageUri(cfg, id, full: full).toString(),
    headers: {'Authorization': 'Bearer ${cfg.token}'},
    fit: fit,
    gaplessPlayback: true,
    loadingBuilder: (context, child, progress) => progress == null
        ? child
        : Container(
            color: c.cont2,
            width: 120,
            height: 120,
            alignment: Alignment.center,
            child: const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
    errorBuilder: (_, _, _) => broken(),
  );
}

/// Imagen a pantalla completa, con zoom. Pide el original al daemon.
class ImageViewer extends ConsumerWidget {
  const ImageViewer({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(therdProvider.select((s) => s.config));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: _image(context, cfg, id, fit: BoxFit.contain, full: true),
        ),
      ),
    );
  }
}
