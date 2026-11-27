import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/connection_config.dart';
import '../data/therd_controller.dart';
import 'qr_scan_screen.dart';
import 'theme.dart';

/// Emparejar un ordenador: QR o host, puerto y token a mano.
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key, this.firstRun = false, this.computerId});

  /// Primera vez (sin configuración): no hay pantalla a la que volver.
  final bool firstRun;

  /// Ordenador que se edita; null = añadir uno nuevo.
  final String? computerId;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _token;
  late final TextEditingController _name;
  final _formKey = GlobalKey<FormState>();
  bool _testing = false;
  String? _result;

  /// Parte del resultado que va en mono (host:puerto), al final del texto.
  String? _resultMono;
  bool _resultOk = false;

  /// Datos a mano: abiertos en ajustes, o si ya hay datos o errores.
  late bool _manualOpen;

  /// IPs de la red local (del QR o de la conexión guardada), sin campo en el
  /// formulario. Solo valen mientras el host sea el mismo del que vinieron.
  List<String> _lan = const [];
  String _lanOf = '';

  @override
  void initState() {
    super.initState();
    final pc = ref.read(therdProvider).computers.byId(widget.computerId);
    final c = pc?.config;
    _machine = pc?.machine;
    _name = TextEditingController(text: pc?.name ?? '');
    _manualOpen = _editing || c != null;
    _lan = c?.lanHosts ?? const [];
    _lanOf = c?.host ?? '';
    _host = TextEditingController(text: c?.host ?? '');
    _port = TextEditingController(
      text: '${c?.port ?? ConnectionConfig.defaultPort}',
    );
    _token = TextEditingController(text: c?.token ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _editing => widget.computerId != null;

  /// Hostname que anunció el daemon: sugerencia para el nombre.
  String? _machine;

  ConnectionConfig? _readForm() {
    if (!_formKey.currentState!.validate()) {
      setState(() => _manualOpen = true);
      return null;
    }
    final host = _host.text.trim();
    return ConnectionConfig(
      host: host,
      port: int.parse(_port.text.trim()),
      token: _token.text.trim(),
      lanHosts: host == _lanOf ? _lan : const [],
    );
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;
    final c = ConnectionConfig.tryParse(raw);
    setState(() {
      _resultMono = null;
      if (c == null) {
        _result = 'El QR no es de therd';
        _resultOk = false;
      } else {
        _host.text = c.host;
        _lan = c.lanHosts;
        _lanOf = c.host;
        _port.text = '${c.port}';
        _token.text = c.token;
        _result = 'QR leído, ya puedes probar o guardar';
        _resultOk = true;
        _manualOpen = true;
      }
    });
  }

  Future<void> _test() async {
    final c = _readForm();
    if (c == null) return;
    setState(() {
      _testing = true;
      _result = 'Probando ';
      _resultMono = c.label;
    });
    final error = await ref.read(therdProvider.notifier).probe(c);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _resultOk = error == null;
      _result = error ?? 'Conexión correcta con ';
      _resultMono = error == null ? c.label : null;
    });
  }

  Future<void> _save() async {
    final c = _readForm();
    if (c == null) return;
    final ctl = ref.read(therdProvider.notifier);
    final id = widget.computerId;
    final exists = ref.read(therdProvider).computers.byId(id) != null;
    if (id != null && exists) {
      await ctl.updateComputer(id, c, name: _name.text);
    } else {
      await ctl.addComputer(c, name: _name.text);
    }
    if (mounted && !widget.firstRun) Navigator.of(context).pop();
  }

  Future<void> _forget() async {
    final id = widget.computerId;
    if (id != null) await ref.read(therdProvider.notifier).removeComputer(id);
    if (mounted && !widget.firstRun) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.tc;
    final title = widget.firstRun
        ? 'Hola, conecta tu PC'
        : _editing
        ? 'Conexión'
        : 'Añadir ordenador';
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Align(
                alignment: Alignment.centerLeft,
                child: widget.firstRun
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: IconButton(
                          tooltip: 'Volver',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back),
                        ),
                      ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.56,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text.rich(
                      TextSpan(
                        text:
                            'Empareja la app con el daemon de tu PC. Ejecuta ',
                        children: [
                          TextSpan(
                            text: 'therd pair',
                            style: mono(size: 15, color: c.text),
                          ),
                          const TextSpan(text: ' para ver el QR.'),
                        ],
                      ),
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.55,
                        color: c.muted,
                      ),
                    ),
                    const SizedBox(height: 22),
                    _step(
                      c,
                      '1',
                      Text.rich(
                        TextSpan(
                          text: 'En el PC, ejecuta ',
                          children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: c.cont,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'therd pair',
                                  style: mono(size: 15, color: c.text),
                                ),
                              ),
                            ),
                          ],
                        ),
                        style: const TextStyle(fontSize: 15, height: 1.5),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _step(
                      c,
                      '2',
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Escanea el QR que aparece',
                            style: TextStyle(fontSize: 15, height: 1.5),
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            onPressed: _scan,
                            icon: const Icon(Icons.qr_code_scanner, size: 20),
                            label: const Text('Escanear QR'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.line)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            borderRadius: Tk.br,
                            onTap: () =>
                                setState(() => _manualOpen = !_manualOpen),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: Tk.control,
                              ),
                              child: Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Escribir los datos a mano',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    _manualOpen
                                        ? Icons.keyboard_arrow_up
                                        : Icons.keyboard_arrow_down,
                                    color: c.muted,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Visibility(
                            visible: _manualOpen,
                            maintainState: true,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: _form(c),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_result != null) ...[
                      const SizedBox(height: 22),
                      _resultLine(c),
                    ],
                    if (_editing && !widget.firstRun) ...[
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _forget,
                        style: TextButton.styleFrom(
                          foregroundColor: c.waitFg,
                          padding: EdgeInsets.zero,
                          textStyle: const TextStyle(
                            fontFamily: kSans,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        child: const Text('Olvidar este ordenador'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _testing ? null : _test,
                      child: _testing
                          ? const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Spinner(),
                                SizedBox(width: 8),
                                Text('Probando'),
                              ],
                            )
                          : const Text('Probar conexión'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: const Text('Guardar y conectar'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(TherdColors c, String n, Widget body) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: c.cont, shape: BoxShape.circle),
        child: Text(
          n,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Padding(padding: const EdgeInsets.only(top: 3), child: body),
      ),
    ],
  );

  Widget _label(TherdColors c, String text, Widget field) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: c.muted,
        ),
      ),
      const SizedBox(height: 6),
      field,
    ],
  );

  InputDecoration _deco(TherdColors c, {String? hint, String? help}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: mono(size: 15, color: c.muted),
        helperText: help,
        helperMaxLines: 2,
        helperStyle: TextStyle(
          fontSize: 12,
          color: c.muted,
          fontWeight: FontWeight.w400,
        ),
        errorStyle: TextStyle(
          fontSize: 12,
          color: c.waitFg,
          fontWeight: FontWeight.w500,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 11,
        ),
      );

  Widget _form(TherdColors c) {
    final style = mono(size: 15, color: c.text);
    return Form(
      key: _formKey,
      child: Column(
        children: [
          _label(
            c,
            'Host',
            TextFormField(
              controller: _host,
              style: style,
              decoration: _deco(
                c,
                hint: '100.x.y.z',
                help: 'IP del PC, normalmente de Tailscale (100.x.y.z)',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Escribe la IP del PC'
                  : null,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: _label(
                  c,
                  'Puerto',
                  TextFormField(
                    controller: _port,
                    style: style,
                    decoration: _deco(c),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return (n == null || n <= 0 || n > 65535)
                          ? 'Entre 1 y 65535'
                          : null;
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _label(
                  c,
                  'Token',
                  TextFormField(
                    controller: _token,
                    style: style,
                    decoration: _deco(c, hint: 'Pega el token'),
                    autocorrect: false,
                    enableSuggestions: false,
                    obscureText: true,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Falta el token'
                        : null,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _label(
            c,
            'Nombre',
            TextFormField(
              controller: _name,
              style: TextStyle(fontSize: 15, color: c.text),
              decoration: _deco(
                c,
                hint: _machine ?? 'Trabajo, Personal…',
                help: 'Opcional, para distinguirlo si emparejas varios',
              ).copyWith(hintStyle: TextStyle(fontSize: 15, color: c.muted)),
              textCapitalization: TextCapitalization.sentences,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultLine(TherdColors c) {
    final color = _testing ? c.muted : (_resultOk ? c.okFg : c.waitFg);
    return Row(
      children: [
        if (_testing)
          const Spinner()
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _resultOk ? kDotDone : kDotWait,
            ),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text.rich(
              TextSpan(
                text: _result,
                children: [
                  if (_resultMono != null)
                    TextSpan(text: _resultMono, style: mono(size: 14)),
                ],
              ),
              style: TextStyle(fontSize: 14, color: color),
            ),
          ),
        ),
      ],
    );
  }
}
