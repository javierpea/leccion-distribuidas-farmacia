import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/medicamento.dart';

/// Error devuelto por la API.
///  - 400 validacion / control_bd -> [errores] por campo
///  - 409 concurrencia / stock / duplicado / estado / bloqueo
///  - 0   sin conexión con la IP virtual
class ApiException implements Exception {
  final int status;
  final String mensaje;
  final String motivo;
  final Map<String, String> errores;
  final Medicamento? medicamento; // estado ACTUAL en la BD (en 409)
  final String servidor;

  ApiException(this.status, this.mensaje,
      {this.motivo = '',
      this.errores = const {},
      this.medicamento,
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

class ApiService {
  /// true cuando NINGÚN servidor responde (los 3 nodos caídos, o Nginx
  /// vivo pero sin Flask/BD). La app muestra la pantalla de mantenimiento.
  static final ValueNotifier<bool> enMantenimiento = ValueNotifier(false);

  static bool _esCaida(int status) =>
      status == 0 || status == 502 || status == 503 || status == 504;

  static Uri _uri(String ruta, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.baseUrl}/api$ruta')
          .replace(queryParameters: query);

  static const _headers = {'Content-Type': 'application/json; charset=utf-8'};

  /// Ejecuta la petición y convierte errores a [ApiException].
  static Future<(Map<String, dynamic>, String)> _enviar(
      Future<http.Response> Function() peticion) async {
    try {
      final resultado = await _enviarInterno(peticion);
      enMantenimiento.value = false;
      return resultado;
    } on ApiException catch (e) {
      if (_esCaida(e.status)) {
        enMantenimiento.value = true;
      } else {
        enMantenimiento.value = false; // el servidor respondió (400/404/409)
      }
      rethrow;
    }
  }

  static Future<(Map<String, dynamic>, String)> _enviarInterno(
      Future<http.Response> Function() peticion) async {
    http.Response r;
    try {
      r = await peticion().timeout(AppConfig.timeout);
    } on TimeoutException {
      throw ApiException(0, 'Tiempo de espera agotado (${AppConfig.baseUrl})',
          motivo: 'red');
    } on http.ClientException catch (e) {
      // http 1.x envuelve SocketException en ClientException
      throw ApiException(
          0, 'Sin conexión con ${AppConfig.baseUrl} (${e.message})',
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
    throw ApiException(
      r.statusCode,
      cuerpo['error']?.toString() ?? 'Error ${r.statusCode}',
      motivo: cuerpo['motivo']?.toString() ?? '',
      errores: errores,
      medicamento:
          med is Map ? Medicamento.fromJson(med.cast<String, dynamic>()) : null,
      servidor: servidor,
    );
  }

  // ------------------------------------------------------------------
  /// Comprueba si algún servidor responde (lo usa la pantalla de mantenimiento).
  static Future<bool> health() async {
    try {
      await _enviar(() => http.get(_uri('/health')));
      return true;
    } on ApiException {
      return false;
    }
  }

  static Future<Respuesta<List<Medicamento>>> listar(
      {String? q, String? estado}) async {
    final query = <String, String>{'tam': '100'};
    if (q != null && q.trim().isNotEmpty) query['q'] = q.trim();
    if (estado != null) query['estado'] = estado;
    final (c, s) = await _enviar(() => http.get(_uri('/medicamentos', query)));
    final lista = (c['datos'] as List)
        .map((e) => Medicamento.fromJson(e as Map<String, dynamic>))
        .toList();
    return Respuesta(lista, s);
  }

  static Future<Respuesta<List<Medicamento>>> alertas() async {
    final (c, s) = await _enviar(() => http.get(_uri('/medicamentos/alertas')));
    final lista = (c['datos'] as List)
        .map((e) => Medicamento.fromJson(e as Map<String, dynamic>))
        .toList();
    return Respuesta(lista, s);
  }

  static Future<Respuesta<Medicamento>> obtener(int id) async {
    final (c, s) = await _enviar(() => http.get(_uri('/medicamentos/$id')));
    return Respuesta(Medicamento.fromJson(c['medicamento']), s);
  }

  static Future<Respuesta<Medicamento>> crear(Map<String, dynamic> datos) async {
    final (c, s) = await _enviar(() => http.post(_uri('/medicamentos'),
        headers: _headers, body: jsonEncode(datos)));
    return Respuesta(Medicamento.fromJson(c['medicamento']), s,
        c['mensaje']?.toString() ?? '');
  }

  /// [datos] debe incluir 'version' (la que se leyó).
  static Future<Respuesta<Medicamento>> actualizar(
      int id, Map<String, dynamic> datos) async {
    final (c, s) = await _enviar(() => http.put(_uri('/medicamentos/$id'),
        headers: _headers, body: jsonEncode(datos)));
    return Respuesta(Medicamento.fromJson(c['medicamento']), s,
        c['mensaje']?.toString() ?? '');
  }

  /// operacion: 'ENTRADA' | 'SALIDA'.  [demoraMs] solo para la demo.
  static Future<Respuesta<ResultadoStock>> moverStock(
      int id, String operacion, int cantidad,
      {int demoraMs = 0}) async {
    final (c, s) = await _enviar(() => http.patch(
        _uri('/medicamentos/$id/stock',
            demoraMs > 0 ? {'demora': '$demoraMs'} : null),
        headers: _headers,
        body: jsonEncode({'operacion': operacion, 'cantidad': cantidad})));
    return Respuesta(
        ResultadoStock(Medicamento.fromJson(c['medicamento']),
            (c['stock_anterior'] as num).toInt()),
        s,
        c['mensaje']?.toString() ?? '');
  }

  static Future<Respuesta<Medicamento>> eliminar(int id, int version) async {
    final (c, s) = await _enviar(() => http.delete(
        _uri('/medicamentos/$id', {'version': '$version'})));
    return Respuesta(Medicamento.fromJson(c['medicamento']), s,
        c['mensaje']?.toString() ?? '');
  }

  /// Envía un cuerpo "crudo" (para la demo de controles del servidor).
  static Future<Respuesta<Map<String, dynamic>>> crearCrudo(
      Map<String, dynamic> datos) async {
    final (c, s) = await _enviar(() => http.post(_uri('/medicamentos'),
        headers: _headers, body: jsonEncode(datos)));
    return Respuesta(c, s);
  }
}
