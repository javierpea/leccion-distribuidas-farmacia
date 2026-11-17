import 'package:flutter/services.dart';

/// Controles del CLIENTE (tercera capa, la más cercana al usuario).
/// Son las MISMAS reglas que validators.py (backend) y 01_schema.sql (BD).
///
///  1) Los FORMATTERS impiden TECLEAR caracteres no permitidos.
///  2) Los VALIDADORES revisan el valor completo antes de enviar.
///  3) Si algo se escapa, el backend y la BD lo vuelven a rechazar.
class Validadores {
  static const _letra = 'A-Za-zÁÉÍÓÚÜÑáéíóúüñ';
  static final reSoloLetras = RegExp('^[$_letra]+( [$_letra]+)*\$');
  static final reCodigo = RegExp(r'^MED-[0-9]{4}$');
  static final reConcentracion = RegExp(
      r'^[0-9]{1,5}(\.[0-9]{1,3})? ?(mg|g|mcg|ml|UI|%)(/[0-9]{0,4} ?(ml|g))?$');
  static final reRegistro = RegExp(r'^[A-Z0-9]{2,8}(-[A-Z0-9]{2,8}){0,3}$');
  static final reLote = RegExp(r'^[A-Z0-9]{3,10}(-[A-Z0-9]{1,8})?$');
  static final reEntero = RegExp(r'^[0-9]+$');
  static final reDecimal = RegExp(r'^[0-9]{1,5}(\.[0-9]{1,2})?$');

  static const formas = [
    'TABLETA', 'CAPSULA', 'JARABE', 'SUSPENSION',
    'INYECTABLE', 'CREMA', 'GOTAS', 'POLVO'
  ];
  static const estados = ['ACTIVO', 'INACTIVO', 'VENCIDO', 'RETIRADO'];

  static String limpiar(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

  // ---------------- Validadores de campo ----------------
  static String? soloLetras(String? v, String campo, int min, int max) {
    final s = limpiar(v ?? '');
    if (s.isEmpty) return '$campo es obligatorio';
    if (RegExp(r'[0-9]').hasMatch(s)) return '$campo no puede contener números';
    if (!reSoloLetras.hasMatch(s)) return 'Solo letras y espacios';
    if (s.length < min || s.length > max) {
      return 'Debe tener entre $min y $max caracteres';
    }
    return null;
  }

  static String? codigo(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    if (s.isEmpty) return 'Código obligatorio';
    if (!reCodigo.hasMatch(s)) return 'Formato: MED-0001 (MED- y 4 números)';
    return null;
  }

  static String? concentracion(String? v) {
    final s = limpiar(v ?? '').toLowerCase().replaceAll('ui', 'UI');
    if (s.isEmpty) return 'Concentración obligatoria';
    if (!reConcentracion.hasMatch(s)) return 'Ej: 500 mg, 250 mg/5 ml, 1 %';
    return null;
  }

  static String? registro(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    if (s.isEmpty) return 'Registro sanitario obligatorio';
    if (!reRegistro.hasMatch(s)) return 'Letras y números separados por guion';
    return null;
  }

  static String? lote(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    if (s.isEmpty) return 'Lote obligatorio';
    if (!reLote.hasMatch(s)) return 'Ej: L2026A01 (letras y números)';
    return null;
  }

  static String? entero(String? v, String campo, int min, int max) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '$campo es obligatorio';
    if (s.startsWith('-')) return '$campo no puede ser negativo';
    if (!reEntero.hasMatch(s)) return 'Solo números enteros';
    final n = int.tryParse(s);
    if (n == null || n < min || n > max) return 'Debe estar entre $min y $max';
    return null;
  }

  static String? precio(String? v, String campo) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '$campo es obligatorio';
    if (s.startsWith('-')) return '$campo no puede ser negativo';
    if (!reDecimal.hasMatch(s)) return 'Solo números, máx. 2 decimales';
    final d = double.parse(s);
    if (d <= 0) return 'Debe ser mayor a 0';
    if (d > 99999.99) return 'Máximo 99999.99';
    return null;
  }

  // ---------------- Formatters (bloquean el teclado) ----------------
  static final soloLetrasFmt = [
    FilteringTextInputFormatter.allow(RegExp('[$_letra ]')),
    FilteringTextInputFormatter.deny(RegExp(r'  +'), replacementString: ' '),
  ];

  static final soloEnterosFmt = [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(6),
  ];

  /// Solo dígitos y un punto con máximo 2 decimales (convierte , en .)
  static final decimalFmt = [
    TextInputFormatter.withFunction((viejo, nuevo) {
      final texto = nuevo.text.replaceAll(',', '.');
      if (RegExp(r'^[0-9]{0,5}(\.[0-9]{0,2})?$').hasMatch(texto)) {
        return nuevo.copyWith(text: texto);
      }
      return viejo;
    }),
  ];

  /// Letras y números en MAYÚSCULAS + guion (código, registro, lote)
  static final alfanumericoFmt = [
    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
    TextInputFormatter.withFunction(
        (viejo, nuevo) => nuevo.copyWith(text: nuevo.text.toUpperCase())),
    LengthLimitingTextInputFormatter(20),
  ];

  static final concentracionFmt = [
    FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z .%/]')),
    LengthLimitingTextInputFormatter(30),
  ];

  static final busquedaFmt = [
    FilteringTextInputFormatter.allow(RegExp('[${_letra}0-9 \\-]')),
    LengthLimitingTextInputFormatter(50),
  ];
}
