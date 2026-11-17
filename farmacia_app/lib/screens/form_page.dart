import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/medicamento.dart';
import '../services/api_service.dart';
import '../utils/validadores.dart';

/// Crear (medicamento == null) o editar un medicamento.
class FormPage extends StatefulWidget {
  final Medicamento? medicamento;
  const FormPage({super.key, this.medicamento});

  @override
  State<FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<FormPage> {
  final _form = GlobalKey<FormState>();
  final _codigo = TextEditingController();
  final _nombre = TextEditingController();
  final _principio = TextEditingController();
  final _laboratorio = TextEditingController();
  final _concentracion = TextEditingController();
  final _registro = TextEditingController();
  final _lote = TextEditingController();
  final _stock = TextEditingController();
  final _stockMin = TextEditingController(text: '10');
  final _pCompra = TextEditingController();
  final _pVenta = TextEditingController();

  String _forma = 'TABLETA';
  String _estado = 'ACTIVO';
  bool _receta = false;
  DateTime? _fab;
  DateTime? _ven;
  int _version = 1;

  bool _guardando = false;
  String? _mensajeGeneral;

  /// Errores que devolvió el SERVIDOR (backend o BD) por campo
  Map<String, String> _erroresServidor = {};

  bool get _esEdicion => widget.medicamento != null;

  @override
  void initState() {
    super.initState();
    if (widget.medicamento != null) _cargar(widget.medicamento!);
  }

  void _cargar(Medicamento m) {
    _codigo.text = m.codigo;
    _nombre.text = m.nombreComercial;
    _principio.text = m.principioActivo;
    _laboratorio.text = m.laboratorio;
    _concentracion.text = m.concentracion;
    _registro.text = m.registroSanitario;
    _lote.text = m.lote;
    _stock.text = '${m.stock}';
    _stockMin.text = '${m.stockMinimo}';
    _pCompra.text = m.precioCompra.toStringAsFixed(2);
    _pVenta.text = m.precioVenta.toStringAsFixed(2);
    _forma = m.formaFarmaceutica;
    _estado = m.estado;
    _receta = m.requiereReceta;
    _fab = m.fechaFabricacion;
    _ven = m.fechaVencimiento;
    _version = m.version;
  }

  @override
  void dispose() {
    for (final c in [
      _codigo, _nombre, _principio, _laboratorio, _concentracion, _registro,
      _lote, _stock, _stockMin, _pCompra, _pVenta
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // Combina el error local con el del servidor para ese campo
  String? Function(String?) _v(String campo, String? Function(String?) local) =>
      (valor) => local(valor) ?? _erroresServidor[campo];

  Map<String, dynamic> _cuerpo() => {
        if (!_esEdicion) 'codigo': _codigo.text.trim().toUpperCase(),
        'nombre_comercial': Validadores.limpiar(_nombre.text),
        'principio_activo': Validadores.limpiar(_principio.text),
        'laboratorio': Validadores.limpiar(_laboratorio.text),
        'concentracion': Validadores.limpiar(_concentracion.text)
            .toLowerCase()
            .replaceAll('ui', 'UI'),
        'forma_farmaceutica': _forma,
        'registro_sanitario': _registro.text.trim().toUpperCase(),
        'lote': _lote.text.trim().toUpperCase(),
        'fecha_fabricacion': fechaIso(_fab!),
        'fecha_vencimiento': fechaIso(_ven!),
        'stock': int.parse(_stock.text),
        'stock_minimo': int.parse(_stockMin.text),
        'precio_compra': double.parse(_pCompra.text),
        'precio_venta': double.parse(_pVenta.text),
        'requiere_receta': _receta,
        if (_esEdicion) 'estado': _estado,
        if (_esEdicion) 'version': _version, // <- concurrencia optimista
      };

  String? _validarFechas() {
    if (_fab == null || _ven == null) return 'Seleccione ambas fechas';
    final hoy = DateUtils.dateOnly(DateTime.now());
    if (_fab!.isAfter(hoy)) return 'La fabricación no puede ser futura';
    if (!_ven!.isAfter(_fab!)) return 'El vencimiento debe ser posterior a la fabricación';
    if (!_esEdicion && !_ven!.isAfter(hoy)) return 'No se puede registrar un medicamento vencido';
    return null;
  }

  Future<void> _guardar() async {
    setState(() {
      _erroresServidor = {};
      _mensajeGeneral = null;
    });
    final okForm = _form.currentState!.validate();
    final errFechas = _validarFechas();
    String? errPrecio;
    if (okForm &&
        double.parse(_pVenta.text) < double.parse(_pCompra.text)) {
      errPrecio = 'El precio de venta no puede ser menor al de compra';
    }
    if (!okForm || errFechas != null || errPrecio != null) {
      setState(() => _mensajeGeneral = errFechas ?? errPrecio ?? 'Revise los campos marcados');
      return;
    }

    setState(() => _guardando = true);
    try {
      final r = _esEdicion
          ? await ApiService.actualizar(widget.medicamento!.id, _cuerpo())
          : await ApiService.crear(_cuerpo());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r.mensaje)));
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.esConcurrencia && e.medicamento != null) {
        await _dialogoConcurrencia(e);
      } else {
        setState(() {
          _erroresServidor = e.errores;
          _mensajeGeneral = e.mensaje;
        });
        _form.currentState!.validate(); // pinta errores del servidor
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Igual que en facturación: otro usuario guardó antes que yo.
  Future<void> _dialogoConcurrencia(ApiException e) async {
    final actual = e.medicamento!;
    final recargar = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.sync_problem, color: Colors.orange, size: 40),
        title: const Text('Otro usuario modificó este medicamento'),
        content: Text(
          '${e.mensaje}\n\n'
          'Valores actuales:\n'
          '• Stock: ${actual.stock}\n'
          '• Precio venta: \$${actual.precioVenta.toStringAsFixed(2)}\n'
          '• Estado: ${actual.estado}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cargar datos actuales')),
        ],
      ),
    );
    if (recargar == true && mounted) {
      setState(() {
        _cargar(actual);
        _mensajeGeneral = 'Se cargaron los datos actuales. Revise y vuelva a guardar.';
      });
    }
  }

  Future<void> _elegirFecha(bool esFab) async {
    final hoy = DateTime.now();
    final f = await showDatePicker(
      context: context,
      initialDate: (esFab ? _fab : _ven) ?? hoy,
      firstDate: DateTime(2000),
      lastDate: esFab ? hoy : DateTime(2100),
    );
    if (f != null) setState(() => esFab ? _fab = f : _ven = f);
  }

  // ------------------------------------------------------------------
  Widget _campo(String campo, String etiqueta, TextEditingController c,
      {required String? Function(String?) validar,
      List<TextInputFormatter>? fmt,
      TextInputType teclado = TextInputType.text,
      bool habilitado = true,
      String? ayuda,
      TextCapitalization cap = TextCapitalization.none}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        enabled: habilitado,
        decoration: InputDecoration(
            labelText: etiqueta, helperText: ayuda, border: const OutlineInputBorder()),
        keyboardType: teclado,
        inputFormatters: fmt,
        textCapitalization: cap,
        validator: _v(campo, validar),
        autovalidateMode: AutovalidateMode.onUserInteraction,
        onChanged: (_) {
          if (_erroresServidor.containsKey(campo)) {
            setState(() => _erroresServidor.remove(campo));
          }
        },
      ),
    );
  }

  Widget _fila(List<Widget> hijos) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < hijos.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: hijos[i]),
        ]
      ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_esEdicion ? 'Editar medicamento' : 'Nuevo medicamento'),
        actions: [
          if (_esEdicion)
            Center(
                child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Chip(label: Text('v$_version')),
            )),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_mensajeGeneral != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_mensajeGeneral!),
                ),
              ),
            _campo('codigo', 'Código', _codigo,
                habilitado: !_esEdicion,
                ayuda: 'MED- y 4 números (no se puede cambiar)',
                fmt: [...Validadores.alfanumericoFmt, LengthLimitingTextInputFormatter(8)],
                validar: Validadores.codigo),
            _campo('nombre_comercial', 'Nombre comercial', _nombre,
                ayuda: 'Solo letras. No puede repetirse',
                fmt: [...Validadores.soloLetrasFmt, LengthLimitingTextInputFormatter(100)],
                cap: TextCapitalization.words,
                validar: (v) => Validadores.soloLetras(v, 'Nombre', 3, 100)),
            _campo('principio_activo', 'Principio activo', _principio,
                fmt: [...Validadores.soloLetrasFmt, LengthLimitingTextInputFormatter(100)],
                cap: TextCapitalization.words,
                validar: (v) => Validadores.soloLetras(v, 'Principio activo', 3, 100)),
            _campo('laboratorio', 'Laboratorio', _laboratorio,
                fmt: [...Validadores.soloLetrasFmt, LengthLimitingTextInputFormatter(80)],
                cap: TextCapitalization.words,
                validar: (v) => Validadores.soloLetras(v, 'Laboratorio', 2, 80)),
            _fila([
              _campo('concentracion', 'Concentración', _concentracion,
                  ayuda: '500 mg · 250 mg/5 ml',
                  fmt: Validadores.concentracionFmt,
                  validar: Validadores.concentracion),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: _forma,
                  key: ValueKey('forma$_forma'),
                  decoration: const InputDecoration(
                      labelText: 'Forma', border: OutlineInputBorder()),
                  items: Validadores.formas
                      .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                      .toList(),
                  onChanged: (v) => setState(() => _forma = v!),
                ),
              ),
            ]),
            _fila([
              _campo('registro_sanitario', 'Registro sanitario', _registro,
                  fmt: Validadores.alfanumericoFmt, validar: Validadores.registro),
              _campo('lote', 'Lote', _lote,
                  fmt: Validadores.alfanumericoFmt, validar: Validadores.lote),
            ]),
            _fila([
              _botonFecha('Fabricación', _fab, () => _elegirFecha(true)),
              _botonFecha('Vencimiento', _ven, () => _elegirFecha(false)),
            ]),
            const SizedBox(height: 12),
            _fila([
              _campo('stock', 'Stock', _stock,
                  teclado: TextInputType.number,
                  fmt: Validadores.soloEnterosFmt,
                  ayuda: 'Solo enteros ≥ 0',
                  validar: (v) => Validadores.entero(v, 'Stock', 0, 100000)),
              _campo('stock_minimo', 'Stock mínimo', _stockMin,
                  teclado: TextInputType.number,
                  fmt: Validadores.soloEnterosFmt,
                  validar: (v) => Validadores.entero(v, 'Stock mínimo', 0, 10000)),
            ]),
            _fila([
              _campo('precio_compra', 'Precio compra \$', _pCompra,
                  teclado: const TextInputType.numberWithOptions(decimal: true),
                  fmt: Validadores.decimalFmt,
                  validar: (v) => Validadores.precio(v, 'Precio compra')),
              _campo('precio_venta', 'Precio venta \$', _pVenta,
                  teclado: const TextInputType.numberWithOptions(decimal: true),
                  fmt: Validadores.decimalFmt,
                  validar: (v) => Validadores.precio(v, 'Precio venta')),
            ]),
            SwitchListTile(
              title: const Text('Requiere receta'),
              value: _receta,
              onChanged: (v) => setState(() => _receta = v),
            ),
            if (_esEdicion)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: _estado,
                  key: ValueKey('estado$_estado'),
                  decoration: const InputDecoration(
                      labelText: 'Estado', border: OutlineInputBorder()),
                  items: Validadores.estados
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) => setState(() => _estado = v!),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _guardando ? null : _guardar,
              icon: _guardando
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              label: Text(_esEdicion ? 'Guardar cambios' : 'Registrar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _botonFecha(String etiqueta, DateTime? valor, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.event),
      label: Text(valor == null ? etiqueta : '$etiqueta: ${fechaIso(valor)}'),
    );
  }
}
