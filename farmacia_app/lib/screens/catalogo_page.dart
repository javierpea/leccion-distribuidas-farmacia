import 'dart:async';

import 'package:flutter/material.dart';

import '../models/catalogo.dart';
import '../services/api_service.dart';
import '../services/sesion.dart';
import '../utils/validadores.dart';
import '../widgets/menu_usuario.dart';
import 'detalle_page.dart';

/// Catálogo completo para el CLIENTE (vista dbo.vw_catalogo):
/// solo medicamentos ACTIVOS, sin datos internos. Al tocar uno se abre
/// su detalle. El personal también puede abrirlo para ver lo que ve el cliente.
class CatalogoPage extends StatefulWidget {
  const CatalogoPage({super.key});

  @override
  State<CatalogoPage> createState() => _CatalogoPageState();
}

class _CatalogoPageState extends State<CatalogoPage> {
  final _busqueda = TextEditingController();
  Timer? _debounce;
  List<ItemCatalogo> _items = [];
  bool _cargando = true;
  String? _error;

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
      final r = await ApiService.catalogo(q: _busqueda.text);
      if (mounted) setState(() => _items = r.datos);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = Sesion.actual;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catálogo de medicamentos'),
        // El cliente no tiene "atrás": el catálogo es su pantalla principal
        automaticallyImplyLeading: u?.esPersonal ?? false,
        actions: const [MenuUsuario(), SizedBox(width: 8)],
      ),
      body: Column(children: [
        if (u != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Hola, ${u.nombreCompleto.split(' ').first}',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: TextField(
            controller: _busqueda,
            inputFormatters: Validadores.busquedaFmt,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar por nombre, principio activo o laboratorio',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 400), _cargar);
            },
          ),
        ),
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
    if (_items.isEmpty) return const Center(child: Text('No se encontraron medicamentos'));
    return RefreshIndicator(
      onRefresh: _cargar,
      child: LayoutBuilder(builder: (context, medidas) {
        final calculo = (medidas.maxWidth / 320).floor();
        final columnas = calculo < 1 ? 1 : (calculo > 4 ? 4 : calculo);
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columnas,
            mainAxisExtent: 150,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: _items.length,
          itemBuilder: (_, i) => _Tarjeta(
            item: _items[i],
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => DetallePage(id: _items[i].id))),
          ),
        );
      }),
    );
  }
}

class _Tarjeta extends StatelessWidget {
  final ItemCatalogo item;
  final VoidCallback onTap;
  const _Tarjeta({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.medication, color: esquema.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(item.nombreComercial,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: 4),
            Text('${item.principioActivo} · ${item.concentracion}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('${item.formaFarmaceutica} · ${item.laboratorio}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: esquema.outline, fontSize: 12)),
            const Spacer(),
            Row(children: [
              Text('\$${item.precioVenta.toStringAsFixed(2)}',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(color: esquema.primary, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (item.requiereReceta)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Tooltip(message: 'Requiere receta', child: Icon(Icons.receipt_long, size: 18)),
                ),
              _Disponibilidad(disponible: item.disponible),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Disponibilidad extends StatelessWidget {
  final bool disponible;
  const _Disponibilidad({required this.disponible});

  @override
  Widget build(BuildContext context) {
    final color = disponible ? Colors.green : Colors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(disponible ? 'Disponible' : 'Agotado',
          style: TextStyle(color: color.shade700, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
