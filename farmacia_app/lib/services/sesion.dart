import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/usuario.dart';
import '../navegacion.dart';

/// Sesión actual (Unidad 3: "Flutter almacena el token").
///
/// El token vive solo en memoria: al cerrar la app hay que volver a
/// iniciar sesión. Dura lo que diga la API (TOKEN_MINUTOS, 5 por defecto);
/// cuando vence, la app vuelve al login con "Sesión expirada".
class Sesion {
  static String? _token;
  static DateTime? _expira;
  static Timer? _timer;

  /// Usuario conectado (null = sin sesión). Las pantallas lo escuchan.
  static final ValueNotifier<Usuario?> usuario = ValueNotifier(null);

  static String? get token => _token;
  static bool get activa => _token != null;
  static Usuario? get actual => usuario.value;

  /// Tiempo que le queda al token (para mostrarlo en la app).
  static Duration get restante {
    if (_expira == null) return Duration.zero;
    final d = _expira!.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  /// [json] = respuesta de /api/auth/login, /registro o /social
  static void iniciar(Map<String, dynamic> json) {
    _token = json['token'] as String;
    // Se usa la duración en minutos (no la hora del servidor) para no
    // depender de que los relojes del cliente y del servidor coincidan.
    final minutos = (json['minutos'] as num?)?.toInt() ?? 5;
    _expira = DateTime.now().add(Duration(minutes: minutos));
    usuario.value = Usuario.fromJson(json['usuario'] as Map<String, dynamic>);

    _timer?.cancel();
    _timer = Timer(Duration(minutes: minutos), () {
      if (activa) {
        cerrar();
        irAlLogin('Sesión expirada. Inicie sesión de nuevo.');
      }
    });
  }

  static void cerrar() {
    _timer?.cancel();
    _timer = null;
    _token = null;
    _expira = null;
    usuario.value = null;
  }
}
