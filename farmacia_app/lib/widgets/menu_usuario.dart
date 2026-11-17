import 'package:flutter/material.dart';

import '../navegacion.dart';
import '../services/api_service.dart';
import '../services/sesion.dart';

/// Botón de la barra superior con el usuario conectado, su rol, el tiempo
/// que le queda a la sesión y "Cerrar sesión".
class MenuUsuario extends StatelessWidget {
  const MenuUsuario({super.key});

  Future<void> _salir() async {
    await ApiService.logout();
    irAlLogin('Sesión cerrada');
  }

  @override
  Widget build(BuildContext context) {
    final u = Sesion.actual;
    if (u == null) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: '${u.nombreCompleto} · ${u.rolLegible}',
      icon: CircleAvatar(
        radius: 16,
        child: Text(u.nombreCompleto.characters.first.toUpperCase()),
      ),
      onSelected: (op) {
        if (op == 'salir') _salir();
      },
      itemBuilder: (_) {
        final min = Sesion.restante.inMinutes;
        final seg = Sesion.restante.inSeconds % 60;
        return [
          PopupMenuItem<String>(
            enabled: false,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(u.esAdmin
                  ? Icons.admin_panel_settings
                  : u.esFarmaceutico
                      ? Icons.medical_services
                      : Icons.person),
              title: Text(u.nombreCompleto),
              subtitle: Text('${u.usuario} · ${u.rolLegible}\n'
                  'Sesión: ${min}m ${seg.toString().padLeft(2, '0')}s'),
              isThreeLine: true,
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'salir',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout),
              title: Text('Cerrar sesión'),
            ),
          ),
        ];
      },
    );
  }
}
