import 'package:flutter/material.dart';

import 'navegacion.dart';
import 'screens/login_page.dart';
import 'screens/mantenimiento_page.dart';
import 'services/api_service.dart';

void main() => runApp(const FarmaciaApp());

class FarmaciaApp extends StatelessWidget {
  const FarmaciaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Farmacia G3',
      debugShowCheckedModeBanner: false,
      navigatorKey: navegador, // para volver al login desde cualquier pantalla
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
      // Si los 3 servidores caen (o NGINX no encuentra ninguna API), la
      // pantalla de mantenimiento tapa TODA la app (cualquier pantalla,
      // incluso el login) hasta que alguno vuelva. El usuario no ve errores
      // técnicos y al volver el servicio sigue donde estaba.
      builder: (context, hijo) => ValueListenableBuilder<bool>(
        valueListenable: ApiService.enMantenimiento,
        builder: (context, caido, _) => Stack(children: [
          hijo!,
          if (caido) const Positioned.fill(child: MantenimientoPage()),
        ]),
      ),
      home: const LoginPage(),
    );
  }
}
