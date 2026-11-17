import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/catalogo.dart';
import '../models/medicamento.dart';
import '../models/usuario.dart';
import '../navegacion.dart';
import 'sesion.dart';

/// Error devuelto por la API.
///  - 400 validacion / control_bd -> [errores] por campo
///  - 401 sin sesión o sesión expirada · 403 el rol no tiene permiso
///  - 409 concurrencia / stock / duplicado / estado / bloqueo
///  - 0   sin conexión con la IP virtual
class ApiException implements Exception {
  final int status;
  final String mensaje;
  final String motivo;
  final Map<String, String> errores;
  final Medicamento? medicamento; // estado ACTUAL en la BD (en 409)
  final Usuario? usuario; // estado ACTUAL del usuario (en 409)
  final String servidor;

  ApiException(this.status, this.mensaje,
      {this.motivo = '',
      this.errores = const {},
      this.medicamento,
      this.usuario,
      this.servidor = '?'});

  bool get esConflicto => status == 409;
  bool get esConcurrencia => status == 409 && motivo == 'concurrencia';

  @override
  String toString() => mensaje;
}

/// Respuesta exitosa + qué servidor Flask la atendió.
class Respuesta<T> {
  final T datos;
  final String servidor;
  final String mensaje;
  Respuesta(this.datos, this.servidor, [this.mensaje = '']);
}

class ResultadoStock {
  final Medicamento medicamento;
  final int stockAnterior;
  ResultadoStock(this.medicamento, this.stockAnterior);
}

/// Qué botones de login muestra la app (lo decide la API según su .env).
class ConfigLogin {
  final bool google;
  final bool facebook;
  final String googleClientId;
  final String facebookAppId;
  final String redirectUri;
  ConfigLogin(this.google, this.facebook, this.googleClientId,
      this.facebookAppId, this.redirectUri);
}

class ApiService {
  /// true cuando NINGÚN servidor responde (los 3 nodos caídos, o NGINX
  /// vivo pero sin Flask/BD). La app tapa todo con "Sistema en mantenimiento".
  static final ValueNotifier<bool> enMantenimiento = ValueNotifier(false);

  static bool _esCaida(int status) =>
      status == 0 || status == 502 || status == 503 || status == 504;

  /// Rutas donde un 401 NO significa "sesión expirada" (credenciales malas)
  static bool _esRutaLogin(String ruta) =>
      ruta.startsWith('/auth/login') ||
      ruta.startsWith('/auth/registro') ||
      ruta.startsWith('/auth/social');

  static Uri _uri(String ruta, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.baseUrl}/api$ruta')
          .replace(queryParameters: query);

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=utf-8',
        if (Sesion.token != null) 'Authorization': 'Bearer ${Sesion.token}',
      };

  // ------------------------------------------------------------------
  static Future<(Map<String, dynamic>, String)> _get(String ruta,
          [Map<String, String>? query]) =>
      _enviar(ruta, () => http.get(_uri(ruta, query), headers: _headers),
          reintentar: true);

  static Future<(Map<String, dynamic>, String)> _post(
          String ruta, Map<String, dynamic> cuerpo) =>
      _enviar(ruta,
          () => http.post(_uri(ruta), headers: _headers, body: jsonEncode(cuerpo)));

  static Future<(Map<String, dynamic>, String)> _put(
          String ruta, Map<String, dynamic> cuerpo) =>
      _enviar(ruta,
          () => http.put(_uri(ruta), headers: _headers, body: jsonEncode(cuerpo)));

  /// Ejecuta la petición, maneja mantenimiento y sesión expirada.
  static Future<(Map<String, dynamic>, String)> _enviar(
      String ruta, Future<http.Response> Function() peticion,
      {bool reintentar = false, Duration? limite}) async {
    // Las consultas (GET) se reintentan una vez: si la IP virtual está
    // pasando de un servidor a otro (failover ~3 s), el usuario no lo nota.
    final intentos = reintentar ? 2 : 1;
    for (var i = 1;; i++) {
      try {
        final resultado = await _enviarInterno(peticion, limite ?? AppConfig.timeout);
        enMantenimiento.value = false;
        return resultado;
      } on ApiException catch (e) {
        if (_esCaida(e.status) && i < intentos) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (_esCaida(e.status)) {
          // Solo se ve en la consola de "flutter run" (diagnóstico)
          debugPrint('[API] ${AppConfig.baseUrl}/api$ruta -> ${e.status} ${e.mensaje}');
        }
        enMantenimiento.value = _esCaida(e.status);
        if (e.status == 401 && !_esRutaLogin(ruta) && Sesion.activa) {
          Sesion.cerrar();
          irAlLogin(e.mensaje);
        }
        rethrow;
      }
    }
  }

  static Future<(Map<String, dynamic>, String)> _enviarInterno(
      Future<http.Response> Function() peticion, Duration limite) async {
    http.Response r;
    try {
      r = await peticion().timeout(limite);
    } on TimeoutException {
      throw ApiException(0, 'Tiempo de espera agotado (${AppConfig.baseUrl})',
          motivo: 'red');
    } on http.ClientException catch (e) {
      // http 1.x envuelve SocketException en ClientException
      throw ApiException(
          0, 'Sin conexión con ${AppConfig.baseUrl} (${e.message})',
          motivo: 'red');
    } on Exception catch (e) {
      // Cualquier otro fallo de red (conexión cortada, IP virtual cambiando
      // de servidor...) también cuenta como "sin conexión"
      throw ApiException(0, 'Sin conexión con ${AppConfig.baseUrl} ($e)',
          motivo: 'red');
    }

    final servidor = r.headers['x-server'] ?? '?';
    Map<String, dynamic> cuerpo;
    try {
      cuerpo = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(r.statusCode, 'Respuesta inválida (${r.statusCode})',
          servidor: servidor);
    }

    if (r.statusCode >= 200 && r.statusCode < 300) {
      return (cuerpo, servidor);
    }

    final errores = <String, String>{};
    final e = cuerpo['errores'];
    if (e is Map) {
      e.forEach((k, v) => errores[k.toString()] = v.toString());
    }
    final med = cuerpo['medicamento'];
    final usu = cuerpo['usuario'];
    throw ApiException(
      r.statusCode,
      cuerpo['error']?.toString() ?? 'Error ${r.statusCode}',
      motivo: cuerpo['motivo']?.toString() ?? '',
      errores: errores,
      medicamento:
          med is Map ? Medicamento.fromJson(med.cast<String, dynamic>()) : null,
      usuario: usu is Map ? Usuario.fromJson(usu.cast<String, dynamic>()) : null,
      servidor: servidor,
    );
  }

  static List<T> _lista<T>(
          Map<String, dynamic> c, T Function(Map<String, dynamic>) f) =>
      (c['datos'] as List).map((e) => f(e as Map<String, dynamic>)).toList();

  // ==================================================================
  // SALUD Y AUTENTICACIÓN
  // ==================================================================
  /// Comprueba si algún servidor responde (lo usa la pantalla de mantenimiento).
  static Future<bool> health() async {
    try {
      await _enviar('/health', () => http.get(_uri('/health')));
      return true;
    } catch (_) {
      return false; // nunca lanza: la pantalla de mantenimiento sigue reintentando
    }
  }

  static Future<ConfigLogin> configLogin() async {
    final (c, _) = await _get('/auth/config');
    return ConfigLogin(
      c['google'] == true,
      c['facebook'] == true,
      (c['google_client_id'] ?? '').toString(),
      (c['facebook_app_id'] ?? '').toString(),
      (c['redirect_uri'] ?? '').toString(),
    );
  }

  /// POST /api/auth/login -> guarda el token en [Sesion]
  static Future<Usuario> login(String usuario, String password) async {
    final (c, _) =
        await _post('/auth/login', {'usuario': usuario, 'password': password});
    Sesion.iniciar(c);
    return Sesion.actual!;
  }

  /// Registro público: siempre crea un CLIENTE y deja la sesión iniciada.
  static Future<Usuario> registro(Map<String, dynamic> datos) async {
    final (c, _) = await _post('/auth/registro', datos);
    Sesion.iniciar(c);
    return Sesion.actual!;
  }

  /// Google / Facebook: la API canjea el [code] y verifica la identidad.
  static Future<Usuario> loginSocial(String proveedor, String code,
      String? codeVerifier, String redirectUri) async {
    final (c, _) = await _post('/auth/social', {
      'proveedor': proveedor,
      'code': code,
      if (codeVerifier != null) 'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
    });
    Sesion.iniciar(c);
    return Sesion.actual!;
  }

  static Future<void> logout() async {
    try {
      if (Sesion.activa) await _post('/auth/logout', {});
    } on ApiException {
      // aunque falle (servidor caído), la sesión local se cierra igual
    } finally {
      Sesion.cerrar();
    }
  }

  // ==================================================================
  // CATÁLOGO (todos los roles)
  // ==================================================================
  static Future<Respuesta<List<ItemCatalogo>>> catalogo({String? q}) async {
    final query = <String, String>{'tam': '100'};
    if (q != null && q.trim().isNotEmpty) query['q'] = q.trim();
    final (c, s) = await _get('/catalogo', query);
    return Respuesta(_lista(c, ItemCatalogo.fromJson), s);
  }

  static Future<Respuesta<ItemCatalogo>> detalleCatalogo(int id) async {
    final (c, s) = await _get('/catalogo/$id');
    return Respuesta(ItemCatalogo.fromJson(c['medicamento']), s);
  }

  // ==================================================================
  // MEDICAMENTOS (ADMIN y FARMACEUTICO)
  // ==================================================================
  static Future<Respuesta<List<Medicamento>>> listar(
      {String? q, String? estado}) async {
    final query = <String, String>{'tam': '100'};
    if (q != null && q.trim().isNotEmpty) query['q'] = q.trim();
    if (estado != null) query['estado'] = estado;
    final (c, s) = await _get('/medicamentos', query);
    return Respuesta(_lista(c, Medicamento.fromJson), s);
  }

  static Future<Respuesta<List<Medicamento>>> alertas() async {
    final (c, s) = await _get('/medicamentos/alertas');
    return Respuesta(_lista(c, Medicamento.fromJson), s);
  }

  static Future<Respuesta<Medicamento>> obtener(int id) async {
    final (c, s) = await _get('/medicamentos/$id');
    return Respuesta(Medicamento.fromJson(c['medicamento']), s);
  }

  static Future<Respuesta<List<Movimiento>>> movimientos(int id) async {
    final (c, s) = await _get('/medicamentos/$id/movimientos');
    return Respuesta(_lista(c, Movimiento.fromJson), s);
  }

  static Future<Respuesta<Medicamento>> crear(Map<String, dynamic> datos) async {
    final (c, s) = await _post('/medicamentos', datos);
    return Respuesta(Medicamento.fromJson(c['medicamento']), s,
        c['mensaje']?.toString() ?? '');
  }

  /// [datos] debe incluir 'version' (la que se leyó).
  static Future<Respuesta<Medicamento>> actualizar(
      int id, Map<String, dynamic> datos) async {
    final (c, s) = await _put('/medicamentos/$id', datos);
    return Respuesta(Medicamento.fromJson(c['medicamento']), s,
        c['mensaje']?.toString() ?? '');
  }

  /// operacion: 'ENTRADA' | 'SALIDA'.  [demoraMs] solo para la demo.
  static Future<Respuesta<ResultadoStock>> moverStock(
      int id, String operacion, int cantidad,
      {int demoraMs = 0}) async {
    final ruta = '/medicamentos/$id/stock';
    final (c, s) = await _enviar(
        ruta,
        () => http.patch(_uri(ruta, demoraMs > 0 ? {'demora': '$demoraMs'} : null),
            headers: _headers,
            body: jsonEncode({'operacion': operacion, 'cantidad': cantidad})),
        // En la demo de concurrencia las peticiones esperan su turno en la BD
        limite: demoraMs > 0 ? const Duration(seconds: 90) : null);
    return Respuesta(
        ResultadoStock(Medicamento.fromJson(c['medicamento']),
            (c['stock_anterior'] as num).toInt()),
        s,
        c['mensaje']?.toString() ?? '');
  }

  static Future<Respuesta<Medicamento>> eliminar(int id, int version) async {
    final ruta = '/medicamentos/$id';
    final (c, s) = await _enviar(
        ruta,
        () => http.delete(_uri(ruta, {'version': '$version'}),
            headers: _headers));
    return Respuesta(Medicamento.fromJson(c['medicamento']), s,
        c['mensaje']?.toString() ?? '');
  }

  /// Envía un cuerpo "crudo" (para la demo de controles del servidor).
  static Future<Respuesta<Map<String, dynamic>>> crearCrudo(
      Map<String, dynamic> datos) async {
    final (c, s) = await _post('/medicamentos', datos);
    return Respuesta(c, s);
  }

  // ==================================================================
  // USUARIOS (solo ADMIN)
  // ==================================================================
  static Future<Respuesta<List<Usuario>>> usuarios({String? q, String? rol}) async {
    final query = <String, String>{};
    if (q != null && q.trim().isNotEmpty) query['q'] = q.trim();
    if (rol != null) query['rol'] = rol;
    final (c, s) = await _get('/usuarios', query);
    return Respuesta(_lista(c, Usuario.fromJson), s);
  }

  static Future<Respuesta<Usuario>> crearUsuario(Map<String, dynamic> datos) async {
    final (c, s) = await _post('/usuarios', datos);
    return Respuesta(Usuario.fromJson(c['usuario']), s, c['mensaje']?.toString() ?? '');
  }

  /// [datos] debe incluir 'version' (concurrencia entre administradores).
  static Future<Respuesta<Usuario>> actualizarUsuario(
      int id, Map<String, dynamic> datos) async {
    final (c, s) = await _put('/usuarios/$id', datos);
    return Respuesta(Usuario.fromJson(c['usuario']), s, c['mensaje']?.toString() ?? '');
  }
}
