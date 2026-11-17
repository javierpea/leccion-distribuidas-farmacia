import 'package:flutter/material.dart';

import 'models/usuario.dart';
import 'screens/catalogo_page.dart';
import 'screens/lista_page.dart';
import 'screens/login_page.dart';

/// Permite navegar desde cualquier parte (por ejemplo, cuando la API
/// responde 401 "Sesión expirada" en medio de cualquier pantalla).
final GlobalKey<NavigatorState> navegador = GlobalKey<NavigatorState>();

/// Pantalla de inicio según el rol:
///   CLIENTE                -> catálogo
///   ADMIN / FARMACEUTICO   -> inventario completo
Widget inicioSegunRol(Usuario u) =>
    u.esPersonal ? const ListaPage() : const CatalogoPage();

void irAInicio(Usuario u) {
  navegador.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => inicioSegunRol(u)), (_) => false);
}

void irAlLogin([String? mensaje]) {
  navegador.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginPage(mensaje: mensaje)),
      (_) => false);
}
