import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/usuario.dart';
import 'api_service.dart';

/// Resultado del navegador: el "code" que la API canjea con Google/Facebook.
class ResultadoOAuth {
  final String code;
  final String? codeVerifier;
  ResultadoOAuth(this.code, this.codeVerifier);
}

/// Login con Google o Facebook (OAuth 2.0, flujo "authorization code").
///
///  1. Abre el navegador con la página de Google / Facebook.
///  2. El usuario acepta y el proveedor redirige a
///     http://localhost:8765/callback?code=...  (redirect_uri de la API).
///  3. Esta clase escucha ese puerto local, toma el code y se lo entrega a
///     la app, que lo manda a la API. El secreto de la aplicación NUNCA
///     está en la app: solo lo tiene la API (.env).
///
/// Funciona en Windows y Android. No funciona en Flutter Web.
class OAuthService {
  static final _azar = Random.secure();

  /// Inicia sesión (o crea la cuenta de CLIENTE si no existe) con Google o
  /// Facebook. Lanza Exception con un mensaje corto para el usuario.
  static Future<Usuario> iniciarSesion(String proveedor) async {
    final nombre = proveedor == 'GOOGLE' ? 'Google' : 'Facebook';
    final c = await ApiService.configLogin();
    final activo = proveedor == 'GOOGLE' ? c.google : c.facebook;
    if (!activo) {
      throw Exception('El ingreso con $nombre no está disponible por el momento.');
    }
    final r = await autorizar(
      proveedor: proveedor,
      clientId: proveedor == 'GOOGLE' ? c.googleClientId : c.facebookAppId,
      redirectUri: c.redirectUri,
    );
    return ApiService.loginSocial(proveedor, r.code, r.codeVerifier, c.redirectUri);
  }

  static String _aleatorio(int largo) {
    const letras =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(largo, (_) => letras[_azar.nextInt(letras.length)])
        .join();
  }

  static Future<ResultadoOAuth> autorizar({
    required String proveedor, // GOOGLE | FACEBOOK
    required String clientId,
    required String redirectUri,
  }) async {
    if (kIsWeb) {
      throw Exception('El ingreso con ${proveedor == 'GOOGLE' ? 'Google' : 'Facebook'} no está disponible en la versión web.');
    }
    final redireccion = Uri.parse(redirectUri);
    final estado = _aleatorio(32); // evita que otra página inyecte un code
    final verificador = _aleatorio(64); // PKCE (Google)
    final desafio = base64UrlEncode(sha256.convert(ascii.encode(verificador)).bytes)
        .replaceAll('=', '');

    final url = proveedor == 'GOOGLE'
        ? Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'response_type': 'code',
            'scope': 'openid email profile',
            'code_challenge': desafio,
            'code_challenge_method': 'S256',
            'state': estado,
            'prompt': 'select_account',
          })
        : Uri.https('www.facebook.com', '/dialog/oauth', {
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'response_type': 'code',
            'scope': 'public_profile,email',
            'state': estado,
          });

    // Escucha en localhost (IPv4 e IPv6: el navegador puede usar cualquiera)
    final servidores = <HttpServer>[];
    try {
      servidores.add(
          await HttpServer.bind(InternetAddress.loopbackIPv4, redireccion.port));
    } on SocketException {
      throw Exception('Cierre otras ventanas de inicio de sesión e intente de nuevo.');
    }
    try {
      servidores.add(
          await HttpServer.bind(InternetAddress.loopbackIPv6, redireccion.port));
    } on SocketException {
      // sin IPv6: basta con IPv4
    }

    final respuesta = Completer<Uri>();
    for (final s in servidores) {
      s.listen((peticion) async {
        if (peticion.uri.path != redireccion.path) {
          peticion.response.statusCode = 404;
          await peticion.response.close();
          return;
        }
        peticion.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        peticion.response.write('<!DOCTYPE html><html><head><meta charset="utf-8">'
            '<title>Farmacia</title></head><body style="font-family:sans-serif;'
            'text-align:center;margin-top:15%"><h2>Listo</h2>'
            '<p>Ya puede cerrar esta ventana y volver a la aplicación.</p>'
            '</body></html>');
        await peticion.response.close();
        if (!respuesta.isCompleted) respuesta.complete(peticion.uri);
      });
    }

    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('No se pudo abrir el navegador.');
      }
      final uri = await respuesta.future.timeout(const Duration(minutes: 3),
          onTimeout: () => throw Exception('Se agotó el tiempo para iniciar sesión.'));
      final p = uri.queryParameters;
      if (p['error'] != null) throw Exception('Inicio de sesión cancelado.');
      if (p['state'] != estado) throw Exception('No se pudo iniciar sesión. Intente de nuevo.');
      final code = p['code'];
      if (code == null || code.isEmpty) throw Exception('No se pudo iniciar sesión. Intente de nuevo.');
      return ResultadoOAuth(code, proveedor == 'GOOGLE' ? verificador : null);
    } finally {
      for (final s in servidores) {
        await s.close(force: true);
      }
    }
  }
}
