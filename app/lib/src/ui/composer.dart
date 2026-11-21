import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:therd_protocol/protocol.dart';

import 'haptics.dart';
import 'theme.dart';

/// Respuestas rápidas de cuando Claude ha terminado.
const kQuickReplies = ['Sí', 'Continúa'];

/// Imágenes que caben en un mensaje.
const kMaxImages = 4;

/// Lado largo y calidad JPEG de lo que se envía. 1568 px es lo más que
/// aprovecha Claude: por encima la reduce él y solo pesa más.
const kImageSide = 1568.0;
const kImageQuality = 80;

/// Caja de texto como tarjeta: las imágenes adjuntas arriba, el campo y
/// debajo una fila con las respuestas rápidas, adjuntar, el dictado y el
/// botón cuadrado de 44 px (Enviar, que pasa a Detener mientras la sesión
/// trabaja).
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.enabled,
    required this.working,
    required this.hint,
    required this.onSend,
    required this.onStop,
    this.quickReplies = const [],
  });

  /// Si es false se desactiva (sin conexión).
  final bool enabled;
  final bool working;

  /// Texto de ayuda; explica por qué está desactivado.
  final String hint;
  final void Function(String text, List<PromptImage> images) onSend;
  final VoidCallback onStop;

  /// Chips de 36 px en la fila de acciones; cada uno envía su texto. Solo se
  /// ven con el campo vacío.
  final List<String> quickReplies;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctl = TextEditingController();
  final _speech = SpeechToText();

  /// null = sin probar; false = el dictado no está disponible.
  bool? _speechReady;
  bool _listening = false;

  /// Texto que había antes de empezar a dictar; lo dictado se añade detrás.
  String _prefix = '';

  final _picker = ImagePicker();
  final List<_Attachment> _images = [];

  @override
  void dispose() {
    if (_listening) _speech.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctl.text.trim();
    if (text.isEmpty && _images.isEmpty) return;
    if (_listening) _stopListening();
    widget.onSend(text, [
      for (final a in _images)
        PromptImage(mime: a.mime, data: base64.encode(a.bytes)),
    ]);
    _ctl.clear();
    setState(_images.clear);
  }

  Future<void> _attach() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Elegir de la galería'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Hacer una foto'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final left = kMaxImages - _images.length;
    List<XFile> files;
    try {
      if (source == ImageSource.camera) {
        final f = await _picker.pickImage(
          source: source,
          maxWidth: kImageSide,
          maxHeight: kImageSide,
          imageQuality: kImageQuality,
        );
        files = [?f];
      } else {
        files = await _picker.pickMultiImage(
          maxWidth: kImageSide,
          maxHeight: kImageSide,
          imageQuality: kImageQuality,
          limit: left > 1 ? left : null,
        );
      }
    } on Exception {
      _snack(
        'No se pudo abrir la ${source == ImageSource.camera ? 'cámara' : 'galería'}.',
      );
      return;
    }
    final picked = <_Attachment>[];
    for (final f in files.take(left)) {
      final mime = _mimeOf(f);
      if (mime == null) continue;
      picked.add(_Attachment(mime, await f.readAsBytes()));
    }
    if (!mounted) return;
    if (files.length > left) {
      _snack('Caben $kMaxImages imágenes por mensaje.');
    }
    if (picked.length < files.take(left).length) {
      _snack('Solo se pueden enviar PNG, JPEG, WebP o GIF.');
    }
    setState(() => _images.addAll(picked));
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggleMic() async {
    if (_listening) return _stopListening();
    if (_speechReady != true) {
      final ok = await _speech.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted && _listening) {
            setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
      if (!mounted) return;
      setState(() => _speechReady = ok);
      if (!ok) return;
    }
    final current = _ctl.text;
    _prefix = current.isEmpty || current.endsWith(' ') ? current : '$current ';
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        if (!mounted) return;
        final text = _prefix + r.recognizedWords;
        _ctl.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        setState(() {});
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        pauseFor: const Duration(seconds: 4),
        listenFor: const Duration(minutes: 2),
      ),
    );
  }

  Future<void> _stopListening() async {
    setState(() => _listening = false);
    await _speech.stop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final empty = _ctl.text.trim().isEmpty && _images.isEmpty;
    final canSend = widget.enabled && !empty;

    final Widget action;
    if (widget.working) {
      action = _SquareButton(
        tooltip: 'Detener',
        onPressed: widget.enabled ? widget.onStop : null,
        background: Colors.transparent,
        border: c.stopBorder,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: c.waitFg,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );
    } else {
      action = _SquareButton(
        tooltip: 'Enviar',
        onPressed: canSend ? _send : null,
        background: canSend ? c.text : c.cont2,
        child: Icon(
          Icons.arrow_upward,
          size: 20,
          color: canSend ? c.bg : c.muted,
        ),
      );
    }

    final String hint;
    if (_listening) {
      hint = 'Escuchando…';
    } else if (_speechReady == false && widget.enabled) {
      hint = 'El dictado no está disponible';
    } else {
      hint = widget.hint;
    }

    final showReplies = widget.quickReplies.isNotEmpty && empty && !_listening;

    return Material(
      color: c.bg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(Tk.radiusSheet),
              border: Border.all(color: c.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_images.isNotEmpty)
                  _Thumbnails(
                    images: _images,
                    onRemove: (i) => setState(() => _images.removeAt(i)),
                  ),
                TextField(
                  controller: _ctl,
                  enabled: widget.enabled,
                  minLines: 1,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 16, height: 1.4, color: c.text),
                  decoration: InputDecoration(
                    hintText: hint,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: showReplies
                            ? SizedBox(
                                height: Tk.control,
                                child: ListView(
                                  scrollDirection: Axis.horizontal,
                                  children: [
                                    for (final r in widget.quickReplies)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: Center(
                                          child: _QuickChip(
                                            label: r,
                                            onTap: () =>
                                                widget.onSend(r, const []),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              )
                            : const SizedBox(height: Tk.control),
                      ),
                      const SizedBox(width: 8),
                      _IconButton(
                        icon: Icons.add_photo_alternate_outlined,
                        tooltip: 'Adjuntar imagen',
                        onPressed: widget.enabled && _images.length < kMaxImages
                            ? _attach
                            : null,
                      ),
                      _MicButton(
                        listening: _listening,
                        onPressed: widget.enabled && _speechReady != false
                            ? () {
                                Haptics.select();
                                _toggleMic();
                              }
                            : null,
                      ),
                      const SizedBox(width: 6),
                      action,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dictado: icono de micro sin fondo; mientras escucha, fondo `cont2` y un
/// anillo que late.
class _MicButton extends StatefulWidget {
  const _MicButton({required this.listening, required this.onPressed});

  final bool listening;
  final VoidCallback? onPressed;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didUpdateWidget(_MicButton old) {
    super.didUpdateWidget(old);
    if (widget.listening && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.listening && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final on = widget.listening;
    return Semantics(
      button: true,
      toggled: on,
      label: on ? 'Dejar de dictar' : 'Dictar',
      child: Tooltip(
        message: on ? 'Dejar de dictar' : 'Dictar',
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) => DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? c.cont2 : Colors.transparent,
              border: on
                  ? Border.all(
                      color: c.muted.withValues(
                        alpha: 0.25 + 0.5 * _pulse.value,
                      ),
                      width: 1.5,
                    )
                  : null,
            ),
            child: child,
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onPressed,
              child: SizedBox(
                width: Tk.control,
                height: Tk.control,
                child: Icon(
                  on ? Icons.mic : Icons.mic_none,
                  size: 22,
                  color: widget.onPressed == null ? c.faint : c.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Botón cuadrado de 44 px, radio 10.
class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.tooltip,
    required this.onPressed,
    required this.background,
    required this.child,
    this.border,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Color background;
  final Color? border;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: Tk.br,
          side: border == null ? BorderSide.none : BorderSide(color: border!),
        ),
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: Tk.br),
          onTap: onPressed,
          child: SizedBox(
            width: Tk.control,
            height: Tk.control,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: c.line),
    );
    return Material(
      shape: shape,
      color: Colors.transparent,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

class _Attachment {
  const _Attachment(this.mime, this.bytes);
  final String mime;
  final Uint8List bytes;
}

String? _mimeOf(XFile f) {
  final m = f.mimeType;
  if (m != null && m.startsWith('image/')) {
    return m == 'image/jpg' ? 'image/jpeg' : m;
  }
  final name = f.name.toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
  if (name.endsWith('.webp')) return 'image/webp';
  if (name.endsWith('.gif')) return 'image/gif';
  return null;
}

/// Miniaturas de 64 px de lo adjunto, cada una con su botón de quitar.
class _Thumbnails extends StatelessWidget {
  const _Thumbnails({required this.images, required this.onRemove});

  final List<_Attachment> images;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return SizedBox(
      height: 80,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: Tk.br,
              child: Image.memory(
                images[i].bytes,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                cacheWidth: 192,
              ),
            ),
            Positioned(
              top: -6,
              right: -6,
              child: Semantics(
                button: true,
                label: 'Quitar imagen',
                child: Material(
                  color: c.text,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => onRemove(i),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.close, size: 14, color: c.bg),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Icono sin fondo de 44 px.
class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: Tk.control,
            height: Tk.control,
            child: Icon(
              icon,
              size: 22,
              color: onPressed == null ? c.faint : c.text,
            ),
          ),
        ),
      ),
    );
  }
}
