import 'dart:async';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/medicamento.dart';
import '../services/api_service.dart';
import '../utils/validadores.dart';
import 'concurrencia_page.dart';
import 'form_page.dart';

class ListaPage extends StatefulWidget {
  const ListaPage({super.key});

  @override
  State<ListaPage> createState() => _ListaPageState();
}

class _ListaPageState extends State<ListaPage> {
  final _busqueda = TextEditingController();
  Timer? _debounce;
  List<Medicamento> _items = [];
  bool _cargando = true;
  bool _soloAlertas = false;
  String? _estado;
  String? _error;
  String _servidor = '-';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _busqueda.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final r = _soloAlertas
          ? await ApiService.alertas()
          : await ApiService.listar(q: _busqueda.text, estado: _estado);
      setState(() {
        _items = r.datos;
        _servidor = r.servidor;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.mensaje);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _snack(String texto, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(texto),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  Future<void> _abrirForm([Medicamento? m]) async {
    final cambio = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => FormPage(medicamento: m)));
    if (cambio == true) _cargar();
  }

  Future<void> _movimiento(Medicamento m, String operacion) async {
    final ctrl = TextEditingController();
    final clave = GlobalKey<FormState>();
    final cantidad = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(operacion == 'SALIDA' ? 'Despachar' : 'Ingresar stock'),
        content: Form(
          key: clave,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${m.nombreComercial}\nStock actual: ${m.stock}'),
            const SizedBox(height: 12),
            TextFormField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: Validadores.soloEnterosFmt,
              decoration: const InputDecoration(
                  labelText: 'Cantidad', border: OutlineInputBorder()),
              validator: (v) {
                final e = Validadores.entero(v, 'Cantidad', 1, 10000);
                if (e != null) return e;
                if (operacion == 'SALIDA' && int.parse(v!) > m.stock) {
                  return 'Solo hay ${m.stock} unidades';
                }
                return null;
              },
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              if (clave.currentState!.validate()) {
                Navigator.pop(context, int.parse(ctrl.text));
              }
            },
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
    if (cantidad == null) return;
    try {
      final r = await ApiService.moverStock(m.id, operacion, cantidad);
      _snack('${r.mensaje}. Stock: ${r.datos.stockAnterior} → '
          '${r.datos.medicamento.stock}  ·  ${r.servidor}');
    } on ApiException catch (e) {
      // 409 stock: otro usuario despachó antes (el stock que vimos ya no existe)
      _snack('${e.mensaje}  (${e.servidor})', error: true);
    }
    _cargar();
  }

  Future<void> _eliminar(Medicamento m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Dar de baja'),
        content: Text('¿Marcar "${m.nombreComercial}" como INACTIVO?\n'
            '(Solo es posible si el stock es 0)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sí')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await ApiService.eliminar(m.id, m.version);
      _snack('${r.mensaje}  ·  ${r.servidor}');
    } on ApiException catch (e) {
      _snack('${e.mensaje}  (${e.servidor})', error: true);
    }
    _cargar();
  }

  Future<void> _configurarUrl() async {
    final ctrl = TextEditingController(text: AppConfig.baseUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('URL de la API'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, decoration: const InputDecoration(border: OutlineInputBorder())),
          const SizedBox(height: 8),
          const Text('Use la IP VIRTUAL. Solo para pruebas apunte directo a un Flask.',
              style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, AppConfig.ipVirtualPorDefecto),
              child: const Text('IP virtual')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Usar')),
        ],
      ),
    );
    if (url != null && Uri.tryParse(url)?.hasScheme == true) {
      AppConfig.baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
      _cargar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Farmacia · Medicamentos'),
        actions: [
          IconButton(
            tooltip: 'Alertas (stock bajo / por vencer)',
            icon: Icon(_soloAlertas ? Icons.notifications_active : Icons.notifications_none),
            onPressed: () {
              setState(() => _soloAlertas = !_soloAlertas);
              _cargar();
            },
          ),
          IconButton(
            tooltip: 'Pruebas de concurrencia',
            icon: const Icon(Icons.bolt),
            onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ConcurrenciaPage()))
                .then((_) => _cargar()),
          ),
          IconButton(tooltip: 'Servidor', icon: const Icon(Icons.settings), onPressed: _configurarUrl),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirForm(),
        icon: const Icon(Icons.add),
        label: const Text('Nuevo'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _busqueda,
                inputFormatters: Validadores.busquedaFmt,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar por nombre, principio o código',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 400), _cargar);
                },
              ),
            ),
            const SizedBox(width: 8),
            DropdownButton<String?>(
              value: _estado,
              hint: const Text('Estado'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Todos')),
                ...Validadores.estados.map((e) => DropdownMenuItem(value: e, child: Text(e))),
              ],
              onChanged: (v) {
                setState(() => _estado = v);
                _cargar();
              },
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            const Icon(Icons.dns, size: 14),
            const SizedBox(width: 4),
            Text('Atendido por: $_servidor  ·  ${AppConfig.baseUrl}',
                style: const TextStyle(fontSize: 12)),
          ]),
        ),
        const Divider(),
        Expanded(child: _contenido()),
      ]),
    );
  }

  Widget _contenido() {
    if (_cargando) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off, size: 48),
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center)),
          FilledButton(onPressed: _cargar, child: const Text('Reintentar')),
        ]),
      );
    }
    if (_items.isEmpty) return const Center(child: Text('Sin resultados'));
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final m = _items[i];
          final colorStock = m.stock == 0
              ? Colors.red
              : m.stockBajo
                  ? Colors.orange
                  : Colors.green;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: colorStock.withValues(alpha: 0.15),
              child: Text('${m.stock}',
                  style: TextStyle(color: colorStock, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            title: Text(m.nombreComercial),
            subtitle: Text('${m.codigo} · ${m.concentracion} · ${m.formaFarmaceutica}\n'
                'Vence ${fechaIso(m.fechaVencimiento)}${m.porVencer ? " ⚠" : ""}'
                ' · ${m.estado}${m.requiereReceta ? " · Rx" : ""} · v${m.version}'),
            isThreeLine: true,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('\$${m.precioVenta.toStringAsFixed(2)}'),
              PopupMenuButton<String>(
                onSelected: (op) {
                  switch (op) {
                    case 'editar':
                      _abrirForm(m);
                    case 'salida':
                      _movimiento(m, 'SALIDA');
                    case 'entrada':
                      _movimiento(m, 'ENTRADA');
                    case 'eliminar':
                      _eliminar(m);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'editar', child: Text('Editar')),
                  PopupMenuItem(value: 'salida', child: Text('Despachar (−)')),
                  PopupMenuItem(value: 'entrada', child: Text('Ingresar stock (+)')),
                  PopupMenuItem(value: 'eliminar', child: Text('Dar de baja')),
                ],
              ),
            ]),
            onTap: () => _abrirForm(m),
          );
        },
      ),
    );
  }
}
