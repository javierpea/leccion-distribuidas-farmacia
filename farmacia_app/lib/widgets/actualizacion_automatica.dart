import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/api_service.dart';

/// Actualización en tiempo real: cada pocos segundos la pantalla vuelve a
/// pedir sus datos a la API (sin mostrar "cargando"), así los cambios que
/// hace otro usuario (stock, precios, usuarios...) aparecen solos.
///
///  - Solo actualiza la pantalla que está a la vista (si hay otra encima
///    o un diálogo abierto, espera).
///  - Si el sistema está en mantenimiento no consulta: esa pantalla ya
///    reintenta por su cuenta.
///  - Si una consulta falla, conserva los datos que ya se muestran.
mixin ActualizacionAutomatica<T extends StatefulWidget> on State<T> {
  static const intervalo = Duration(seconds: 4);
  Timer? _timerActualizacion;
  bool _actualizando = false;

  /// Cada pantalla vuelve a pedir sus datos aquí (sin spinner).
  Future<void> refrescarEnSegundoPlano();

  void iniciarActualizacionAutomatica() {
    _timerActualizacion?.cancel();
    _timerActualizacion = Timer.periodic(intervalo, (_) async {
      if (!mounted || _actualizando) return;
      if (ApiService.enMantenimiento.value) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _actualizando = true;
      try {
        await refrescarEnSegundoPlano();
      } catch (_) {
        // se intenta de nuevo en el siguiente ciclo
      } finally {
        _actualizando = false;
      }
    });
  }

  @override
  void dispose() {
    _timerActualizacion?.cancel();
    super.dispose();
  }
}
