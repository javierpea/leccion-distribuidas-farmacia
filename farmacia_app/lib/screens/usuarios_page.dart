import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/usuario.dart';
import '../services/api_service.dart';
import '../utils/validadores.dart';
import '../widgets/actualizacion_automatica.dart';
import '../widgets/menu_usuario.dart';
import 'usuario_form_page.dart';

/// Administración de usuarios y roles (solo ADMIN).
class UsuariosPage extends StatefulWidget {
  const UsuariosPage({super.key});

  @override
  State<UsuariosPage> createState() => _UsuariosPageState();
}

class _UsuariosPageState extends State<UsuariosPage>
    with ActualizacionAutomatica<UsuariosPage> {
  final _busqueda = TextEditingController();
  Timer? _debounce;
  List<Usuario> _items = [];
  String? _rol;
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
    iniciarActualizacionAutomatica();
  }

  @override
  Future<void> refrescarEnSegundoPlano() async {
    final r = await ApiService.usuarios(q: _busqueda.text, rol: _rol);
    if (mounted) {
      setState(() {
        _items = r.datos;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _busqueda.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    if (!mounted) return;
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final r = await ApiService.usuarios(q: _busqueda.text, rol: _rol);
      if (mounted) setState(() => _items = r.datos);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.mensaje);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _abrir([Usuario? u]) async {
    final cambio = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => UsuarioFormPage(usuario: u)));
    if (cambio == true) _cargar();
  }

  Color _colorRol(String rol) => switch (rol) {
        'ADMIN' => Colors.deepPurple,
        'FARMACEUTICO' => Colors.teal,
        _ => Colors.blueGrey,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Usuarios y roles'),
        actions: const [MenuUsuario(), SizedBox(width: 8)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrir(),
        icon: const Icon(Icons.person_add),
        label: const Text('Nuevo usuario'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _busqueda,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-zÁÉÍÓÚÜÑáéíóúüñ0-9 ._@+\-]')),
                  LengthLimitingTextInputFormatter(50),
                ],
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar por usuario, nombre o correo',
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
              value: _rol,
              hint: const Text('Rol'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Todos')),
                ...Validadores.roles.map((r) => DropdownMenuItem(value: r, child: Text(r))),
              ],
              onChanged: (v) {
                setState(() => _rol = v);
                _cargar();
              },
            ),
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
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center)),
          FilledButton(onPressed: _cargar, child: const Text('Reintentar')),
        ]),
      );
    }
    if (_items.isEmpty) return const Center(child: Text('Sin usuarios'));
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final u = _items[i];
        final color = _colorRol(u.rol);
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(
                u.esAdmin
                    ? Icons.admin_panel_settings
                    : u.esFarmaceutico
                        ? Icons.medical_services
                        : Icons.person,
                color: color),
          ),
          title: Text(u.nombreCompleto,
              style: TextStyle(
                  decoration: u.estado ? null : TextDecoration.lineThrough)),
          subtitle: Text('${u.usuario}${u.email != null ? ' · ${u.email}' : ''}\n'
              '${u.rolLegible}'
              '${u.esSocial ? ' · ${u.proveedor == 'GOOGLE' ? 'Google' : 'Facebook'}' : ''}'
              '${u.estado ? '' : ' · DESACTIVADO'}'
              '${u.bloqueado ? ' · BLOQUEADO' : ''}'),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _abrir(u),
        );
      },
    );
  }
}
