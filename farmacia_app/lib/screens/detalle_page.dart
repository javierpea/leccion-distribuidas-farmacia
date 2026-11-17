import 'package:flutter/material.dart';

import '../models/catalogo.dart';
import '../models/medicamento.dart';
import '../services/api_service.dart';
import '../widgets/actualizacion_automatica.dart';
import '../widgets/menu_usuario.dart';

/// Detalle de un medicamento.
///  - completo = false (CLIENTE, desde el catálogo): datos públicos de
///    dbo.vw_catalogo (sin precio de compra, lote, registro ni stock exacto).
///  - completo = true (ADMIN / FARMACEUTICO): todos los campos de
///    dbo.vw_medicamentos + los últimos movimientos de stock.
class DetallePage extends StatefulWidget {
  final int id;
  final bool completo;
  const DetallePage({super.key, required this.id, this.completo = false});

  @override
  State<DetallePage> createState() => _DetallePageState();
}

class _DetallePageState extends State<DetallePage>
    with ActualizacionAutomatica<DetallePage> {
  ItemCatalogo? _item;
  Medicamento? _med;
  List<Movimiento> _movs = [];
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
    iniciarActualizacionAutomatica(); // stock y precio cambian en vivo
  }

  @override
  Future<void> refrescarEnSegundoPlano() async {
    if (widget.completo) {
      final r = await ApiService.obtener(widget.id);
      final m = await ApiService.movimientos(widget.id);
      if (mounted) {
        setState(() {
          _med = r.datos;
          _movs = m.datos;
          _error = null;
        });
      }
    } else {
      final r = await ApiService.detalleCatalogo(widget.id);
      if (mounted) {
        setState(() {
          _item = r.datos;
          _error = null;
        });
      }
    }
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      if (widget.completo) {
        final r = await ApiService.obtener(widget.id);
        final m = await ApiService.movimientos(widget.id);
        if (mounted) {
          setState(() {
            _med = r.datos;
            _movs = m.datos;
          });
        }
      } else {
        final r = await ApiService.detalleCatalogo(widget.id);
        if (mounted) setState(() => _item = r.datos);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detalle del medicamento'),
        actions: const [MenuUsuario(), SizedBox(width: 8)],
      ),
      body: _cuerpo(),
    );
  }

  Widget _cuerpo() {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.info_outline, size: 48),
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center)),
          FilledButton(onPressed: _cargar, child: const Text('Reintentar')),
        ]),
      );
    }
    final hijos = widget.completo ? _detalleCompleto(_med!) : _detalleCliente(_item!);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(padding: const EdgeInsets.all(16), children: hijos),
      ),
    );
  }

  // ------------------------------------------------------------------
  Widget _encabezado(String nombre, String subtitulo, double precio) {
    final esquema = Theme.of(context).colorScheme;
    return Card(
      color: esquema.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Icon(Icons.medication_liquid, size: 56, color: esquema.onPrimaryContainer),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(nombre, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(subtitulo),
              const SizedBox(height: 8),
              Text('\$${precio.toStringAsFixed(2)}',
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold, color: esquema.primary)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _dato(IconData icono, String etiqueta, String valor) => ListTile(
        leading: Icon(icono),
        title: Text(etiqueta, style: const TextStyle(fontSize: 13)),
        subtitle: Text(valor, style: const TextStyle(fontSize: 16)),
        dense: true,
      );

  Widget _chip(String texto, Color color, IconData icono) => Chip(
        avatar: Icon(icono, size: 18, color: color),
        label: Text(texto),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      );

  String _fecha(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  List<Widget> _detalleCliente(ItemCatalogo m) => [
        _encabezado(m.nombreComercial, '${m.principioActivo} · ${m.concentracion}', m.precioVenta),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          m.disponible
              ? _chip('Disponible', Colors.green, Icons.check_circle)
              : _chip('Agotado', Colors.red, Icons.remove_shopping_cart),
          m.requiereReceta
              ? _chip('Requiere receta médica', Colors.orange, Icons.receipt_long)
              : _chip('Venta libre', Colors.teal, Icons.storefront),
        ]),
        const SizedBox(height: 8),
        Card(
          child: Column(children: [
            _dato(Icons.science, 'Principio activo', m.principioActivo),
            _dato(Icons.straighten, 'Concentración', m.concentracion),
            _dato(Icons.category, 'Presentación', m.formaFarmaceutica),
            _dato(Icons.factory, 'Laboratorio', m.laboratorio),
            _dato(Icons.event, 'Vence', _fecha(m.fechaVencimiento)),
            _dato(Icons.qr_code, 'Código', m.codigo),
          ]),
        ),
        if (m.requiereReceta)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Para adquirir este medicamento debe presentar la receta en la farmacia.',
                style: TextStyle(fontSize: 12)),
          ),
      ];

  List<Widget> _detalleCompleto(Medicamento m) => [
        _encabezado(m.nombreComercial, '${m.codigo} · ${m.principioActivo} · ${m.concentracion}',
            m.precioVenta),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _chip('Stock: ${m.stock}', m.stockBajo ? Colors.orange : Colors.green, Icons.inventory_2),
          _chip(m.estado, m.estado == 'ACTIVO' ? Colors.green : Colors.grey, Icons.flag),
          if (m.porVencer) _chip('Por vencer', Colors.orange, Icons.warning_amber),
          if (m.requiereReceta) _chip('Requiere receta', Colors.orange, Icons.receipt_long),
          _chip('Versión ${m.version}', Colors.blueGrey, Icons.history),
        ]),
        const SizedBox(height: 8),
        Card(
          child: Column(children: [
            _dato(Icons.factory, 'Laboratorio', m.laboratorio),
            _dato(Icons.category, 'Forma farmacéutica', m.formaFarmaceutica),
            _dato(Icons.verified, 'Registro sanitario', m.registroSanitario),
            _dato(Icons.tag, 'Lote', m.lote),
            _dato(Icons.precision_manufacturing, 'Fabricación', _fecha(m.fechaFabricacion)),
            _dato(Icons.event, 'Vencimiento', _fecha(m.fechaVencimiento)),
            _dato(Icons.inventory, 'Stock mínimo', '${m.stockMinimo}'),
            _dato(Icons.payments, 'Precio de compra', '\$${m.precioCompra.toStringAsFixed(2)}'),
          ]),
        ),
        const SizedBox(height: 8),
        Text('Últimos movimientos de stock', style: Theme.of(context).textTheme.titleMedium),
        if (_movs.isEmpty)
          const Padding(padding: EdgeInsets.all(12), child: Text('Sin movimientos registrados')),
        ..._movs.map((mv) => ListTile(
              dense: true,
              leading: Icon(mv.operacion == 'SALIDA' ? Icons.remove_circle : Icons.add_circle,
                  color: mv.operacion == 'SALIDA' ? Colors.red : Colors.green),
              title: Text('${mv.operacion} de ${mv.cantidad} · ${mv.stockAnterior} → ${mv.stockNuevo}'),
              subtitle: Text('${_fecha(mv.fecha)} ${mv.fecha.hour.toString().padLeft(2, '0')}:'
                  '${mv.fecha.minute.toString().padLeft(2, '0')} · ${mv.usuario}'),
            )),
      ];
}
