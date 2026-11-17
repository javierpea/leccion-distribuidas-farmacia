import 'package:flutter/material.dart';

import '../models/medicamento.dart';
import '../services/api_service.dart';
import '../utils/validadores.dart';

/// Pantalla para DEMOSTRAR en la exposición:
///  1) Despacho simultáneo: N peticiones a la vez sobre el mismo
///     medicamento -> el stock nunca queda negativo.
///  2) Edición simultánea: 2 PUT con la misma versión -> 1 gana, 1 recibe 409.
///  3) Controles del servidor: se envían datos inválidos saltándose la
///     validación de la app -> el backend/BD los rechazan.
class ConcurrenciaPage extends StatefulWidget {
  const ConcurrenciaPage({super.key});

  @override
  State<ConcurrenciaPage> createState() => _ConcurrenciaPageState();
}

class _Resultado {
  final int n;
  final bool ok;
  final int status;
  final String servidor;
  final String mensaje;
  _Resultado(this.n, this.ok, this.status, this.servidor, this.mensaje);
}

class _ConcurrenciaPageState extends State<ConcurrenciaPage> {
  List<Medicamento> _meds = [];
  Medicamento? _sel;
  final _peticiones = TextEditingController(text: '20');
  final _cantidad = TextEditingController(text: '1');
  final _demora = TextEditingController(text: '200');
  bool _corriendo = false;
  List<_Resultado> _resultados = [];
  String _resumen = '';

  @override
  void initState() {
    super.initState();
    _cargarMeds();
  }

  @override
  void dispose() {
    _peticiones.dispose();
    _cantidad.dispose();
    _demora.dispose();
    super.dispose();
  }

  Future<void> _cargarMeds() async {
    try {
      final r = await ApiService.listar(estado: 'ACTIVO');
      setState(() {
        _meds = r.datos;
        _sel = _meds.where((m) => m.codigo == 'MED-0020').firstOrNull ??
            (_meds.isNotEmpty ? _meds.first : null);
      });
    } on ApiException catch (e) {
      setState(() => _resumen = e.mensaje);
    }
  }

  Future<Medicamento> _refrescar(int id) async => (await ApiService.obtener(id)).datos;

  // ----------------------- PRUEBA 1 ---------------------------------
  Future<void> _despachoSimultaneo() async {
    final n = int.tryParse(_peticiones.text) ?? 0;
    final cant = int.tryParse(_cantidad.text) ?? 0;
    final demora = int.tryParse(_demora.text) ?? 0;
    if (_sel == null || n < 1 || n > 100 || cant < 1 || demora > 3000) {
      setState(() => _resumen = 'Peticiones 1-100, cantidad ≥ 1, demora ≤ 3000 ms');
      return;
    }
    setState(() {
      _corriendo = true;
      _resultados = [];
      _resumen = '';
    });
    try {
      final inicial = await _refrescar(_sel!.id);
      final reloj = Stopwatch()..start();

      // Todas las peticiones salen AL MISMO TIEMPO
      final futuros = List.generate(n, (i) async {
        try {
          final r = await ApiService.moverStock(inicial.id, 'SALIDA', cant, demoraMs: demora);
          return _Resultado(i + 1, true, 200, r.servidor,
              'stock ${r.datos.stockAnterior} → ${r.datos.medicamento.stock}');
        } on ApiException catch (e) {
          return _Resultado(i + 1, false, e.status, e.servidor, e.mensaje);
        }
      });
      final res = await Future.wait(futuros);
      reloj.stop();

      final fin = await _refrescar(inicial.id);
      final exitos = res.where((r) => r.ok).length;
      final rechazos = res.where((r) => r.status == 409).length;
      final porServidor = <String, int>{};
      for (final r in res) {
        porServidor[r.servidor] = (porServidor[r.servidor] ?? 0) + 1;
      }
      final esperado = inicial.stock - exitos * cant;
      final correcto = fin.stock == esperado && fin.stock >= 0;

      setState(() {
        _resultados = res;
        _resumen = '${correcto ? "✅ CORRECTO" : "❌ INCONSISTENTE"}\n'
            'Stock inicial: ${inicial.stock}  →  final: ${fin.stock} (esperado $esperado)\n'
            'Exitosas: $exitos   ·   Rechazadas 409: $rechazos   ·   '
            'Otros errores: ${n - exitos - rechazos}\n'
            'Reparto: ${porServidor.entries.map((e) => "${e.key}=${e.value}").join("  ")}\n'
            'Tiempo total: ${reloj.elapsedMilliseconds} ms';
      });
    } on ApiException catch (e) {
      setState(() => _resumen = e.mensaje);
    } finally {
      if (mounted) setState(() => _corriendo = false);
    }
  }

  Future<void> _reponer() async {
    if (_sel == null) return;
    try {
      final actual = await _refrescar(_sel!.id);
      final faltan = 10 - actual.stock;
      if (faltan > 0) await ApiService.moverStock(actual.id, 'ENTRADA', faltan);
      final r = await _refrescar(actual.id);
      setState(() => _resumen = 'Stock de ${r.nombreComercial} repuesto a ${r.stock}');
    } on ApiException catch (e) {
      setState(() => _resumen = e.mensaje);
    }
  }

  // ----------------------- PRUEBA 2 ---------------------------------
  Future<void> _edicionSimultanea() async {
    if (_sel == null) return;
    setState(() {
      _corriendo = true;
      _resultados = [];
      _resumen = '';
    });
    try {
      final m = await _refrescar(_sel!.id);
      // Usuario A y Usuario B leyeron la MISMA versión y guardan a la vez
      Map<String, dynamic> cuerpo(double incremento) {
        final j = m.toJsonActualizar();
        j['precio_venta'] = double.parse((m.precioVenta + incremento).toStringAsFixed(2));
        return j;
      }

      Future<_Resultado> enviar(int n, double inc) async {
        try {
          final r = await ApiService.actualizar(m.id, cuerpo(inc));
          return _Resultado(n, true, 200, r.servidor,
              'Usuario ${n == 1 ? "A" : "B"}: guardó precio ${r.datos.precioVenta} (v${r.datos.version})');
        } on ApiException catch (e) {
          return _Resultado(n, false, e.status, e.servidor,
              'Usuario ${n == 1 ? "A" : "B"}: ${e.mensaje}');
        }
      }

      final res = await Future.wait([enviar(1, 0.10), enviar(2, 0.20)]);
      final fin = await _refrescar(m.id);
      final ganadores = res.where((r) => r.ok).length;
      setState(() {
        _resultados = res;
        _resumen = '${ganadores == 1 ? "✅ CORRECTO" : "❌ INCONSISTENTE"}: '
            '$ganadores guardó, ${2 - ganadores} recibió 409\n'
            'Versión leída: v${m.version}  →  versión final: v${fin.version}\n'
            'Precio final: ${fin.precioVenta}';
      });
    } on ApiException catch (e) {
      setState(() => _resumen = e.mensaje);
    } finally {
      if (mounted) setState(() => _corriendo = false);
    }
  }

  // ----------------------- PRUEBA 3 ---------------------------------
  Future<void> _controlesServidor() async {
    setState(() {
      _corriendo = true;
      _resultados = [];
      _resumen = '';
    });
    final base = {
      'codigo': 'MED-0999',
      'nombre_comercial': 'Producto Prueba',
      'principio_activo': 'Paracetamol',
      'laboratorio': 'Genfar',
      'concentracion': '500 mg',
      'forma_farmaceutica': 'TABLETA',
      'registro_sanitario': '9999-PRB-01',
      'lote': 'LPRB01',
      'fecha_fabricacion': '2026-01-01',
      'fecha_vencimiento': '2029-01-01',
      'stock': 5,
      'precio_compra': 1.0,
      'precio_venta': 2.0,
    };
    final casos = <String, Map<String, dynamic>>{
      'Stock negativo (-5)': {...base, 'stock': -5},
      'Stock con texto ("diez")': {...base, 'stock': 'diez'},
      'Stock decimal (2.5)': {...base, 'stock': 2.5},
      'Nombre con números': {...base, 'nombre_comercial': 'Paracetamol 500'},
      'Nombre con símbolos': {...base, 'nombre_comercial': 'Para<script>'},
      'Nombre DUPLICADO (mayúsc./tildes)': {...base, 'nombre_comercial': '  PARACETÁMOL   genfar '},
      'Precio con letras': {...base, 'precio_venta': '12abc'},
      'Precio 0': {...base, 'precio_compra': 0},
      'Venta menor que compra': {...base, 'precio_compra': 5.0, 'precio_venta': 1.0},
      'Código inválido': {...base, 'codigo': 'ABC'},
      'Medicamento vencido': {...base, 'fecha_vencimiento': '2020-01-01'},
      'Campo extra (inyección)': {...base, 'version': 999},
    };
    final res = <_Resultado>[];
    var i = 0;
    for (final e in casos.entries) {
      i++;
      try {
        final r = await ApiService.crearCrudo(e.value);
        res.add(_Resultado(i, false, 201, r.servidor, '${e.key}: ⚠ ACEPTADO (no debería)'));
      } on ApiException catch (ex) {
        final detalle = ex.errores.isEmpty ? ex.mensaje : ex.errores.values.first;
        res.add(_Resultado(i, true, ex.status, ex.servidor, '${e.key}: $detalle'));
      }
    }
    final bloqueados = res.where((r) => r.ok).length;
    setState(() {
      _resultados = res;
      _resumen = '${bloqueados == casos.length ? "✅" : "❌"} '
          '$bloqueados de ${casos.length} datos inválidos fueron RECHAZADOS por el servidor';
      _corriendo = false;
    });
  }

  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pruebas de concurrencia y controles')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<int>(
          initialValue: _sel?.id,
          key: ValueKey(_sel?.id),
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Medicamento', border: OutlineInputBorder()),
          items: _meds
              .map((m) => DropdownMenuItem(
                  value: m.id, child: Text('${m.codigo} · ${m.nombreComercial} (stock ${m.stock})')))
              .toList(),
          onChanged: (id) => setState(() => _sel = _meds.firstWhere((m) => m.id == id)),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _num(_peticiones, 'Peticiones simultáneas')),
          const SizedBox(width: 8),
          Expanded(child: _num(_cantidad, 'Unidades c/u')),
          const SizedBox(width: 8),
          Expanded(child: _num(_demora, 'Demora ms')),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: _corriendo ? null : _despachoSimultaneo,
            icon: const Icon(Icons.bolt),
            label: const Text('1. Despacho simultáneo'),
          ),
          FilledButton.tonalIcon(
            onPressed: _corriendo ? null : _edicionSimultanea,
            icon: const Icon(Icons.people),
            label: const Text('2. Edición simultánea'),
          ),
          FilledButton.tonalIcon(
            onPressed: _corriendo ? null : _controlesServidor,
            icon: const Icon(Icons.shield),
            label: const Text('3. Controles del servidor'),
          ),
          OutlinedButton.icon(
            onPressed: _corriendo ? null : _reponer,
            icon: const Icon(Icons.restore),
            label: const Text('Reponer stock a 10'),
          ),
        ]),
        const SizedBox(height: 16),
        if (_corriendo) const LinearProgressIndicator(),
        if (_resumen.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_resumen, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ..._resultados.map((r) => ListTile(
              dense: true,
              leading: Icon(r.ok ? Icons.check_circle : Icons.block,
                  color: r.ok ? Colors.green : Colors.orange),
              title: Text(r.mensaje),
              subtitle: Text('#${r.n} · HTTP ${r.status} · ${r.servidor}'),
            )),
      ]),
    );
  }

  Widget _num(TextEditingController c, String etiqueta) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: Validadores.soloEnterosFmt,
        decoration: InputDecoration(labelText: etiqueta, border: const OutlineInputBorder(), isDense: true),
      );
}
