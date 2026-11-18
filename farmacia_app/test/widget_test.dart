import 'package:farmacia_app/utils/validadores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Controles del cliente', () {
    test('nombre: solo letras', () {
      expect(Validadores.soloLetras('Paracetamol Genfar', 'N', 3, 100), isNull);
      expect(Validadores.soloLetras('Ácido Fólico', 'N', 3, 100), isNull);
      expect(Validadores.soloLetras('Paracetamol 500', 'N', 3, 100), isNotNull);
      expect(Validadores.soloLetras('Para@cetamol', 'N', 3, 100), isNotNull);
      expect(Validadores.soloLetras('ab', 'N', 3, 100), isNotNull);
    });

    test('stock: solo enteros no negativos', () {
      expect(Validadores.entero('10', 'S', 0, 100000), isNull);
      expect(Validadores.entero('0', 'S', 0, 100000), isNull);
      expect(Validadores.entero('-5', 'S', 0, 100000), contains('negativo'));
      expect(Validadores.entero('2.5', 'S', 0, 100000), isNotNull);
      expect(Validadores.entero('diez', 'S', 0, 100000), isNotNull);
    });

    test('precio: números con máx. 2 decimales y > 0', () {
      expect(Validadores.precio('12.50', 'P'), isNull);
      expect(Validadores.precio('0', 'P'), isNotNull);
      expect(Validadores.precio('-1', 'P'), isNotNull);
      expect(Validadores.precio('1.234', 'P'), isNotNull);
      expect(Validadores.precio('12abc', 'P'), isNotNull);
    });

    test('código, lote, registro, concentración', () {
      expect(Validadores.codigo('MED-0001'), isNull);
      expect(Validadores.codigo('med-0001'), isNull);
      expect(Validadores.codigo('ABC'), isNotNull);
      expect(Validadores.lote('L2026A01'), isNull);
      expect(Validadores.lote('L 2026'), isNotNull);
      expect(Validadores.registro('1234-MEE-0521'), isNull);
      expect(Validadores.concentracion('250 mg/5 ml'), isNull);
      expect(Validadores.concentracion('500 MG'), isNull);
      expect(Validadores.concentracion('mucho'), isNotNull);
    });

    test('usuario, correo y contraseña', () {
      expect(Validadores.usuario('juan.perez'), isNull);
      expect(Validadores.usuario('1juan'), isNotNull);
      expect(Validadores.usuario('abc'), isNotNull);
      expect(Validadores.email('juan@correo.com'), isNull);
      expect(Validadores.email(''), isNull); // opcional
      expect(Validadores.email('juan@'), isNotNull);
      expect(Validadores.password('Clave123'), isNull);
      expect(Validadores.password('soloLetras'), isNotNull);
      expect(Validadores.password('1234567'), isNotNull);
    });
  });

  group('Teclado (formatters)', () {
    TextEditingValue escribir(List<TextInputFormatter> fmts, String viejo, String nuevo) {
      var valor = TextEditingValue(
          text: nuevo, selection: TextSelection.collapsed(offset: nuevo.length));
      final anterior = TextEditingValue(
          text: viejo, selection: TextSelection.collapsed(offset: viejo.length));
      for (final f in fmts) {
        valor = f.formatEditUpdate(anterior, valor);
      }
      return valor;
    }

    test('decimal: la coma se convierte en punto', () {
      expect(escribir(Validadores.decimalFmt, '12', '12,').text, '12.');
      expect(escribir(Validadores.decimalFmt, '12', '12.').text, '12.');
    });

    test('decimal: un solo punto, máx. 2 decimales, sin letras ni signos', () {
      expect(escribir(Validadores.decimalFmt, '12.5', '12.5.').text, '12.5');
      expect(escribir(Validadores.decimalFmt, '12.5', '12.5,').text, '12.5');
      expect(escribir(Validadores.decimalFmt, '12.55', '12.555').text, '12.55');
      expect(escribir(Validadores.decimalFmt, '12', '12a').text, '12');
      expect(escribir(Validadores.decimalFmt, '12', '12-').text, '12');
      expect(escribir(Validadores.decimalFmt, '', ',').text, '0.');
    });

    test('enteros: solo dígitos', () {
      expect(escribir(Validadores.soloEnterosFmt, '1', '1a').text, '1');
      expect(escribir(Validadores.soloEnterosFmt, '1', '1.').text, '1');
      expect(escribir(Validadores.soloEnterosFmt, '1', '12').text, '12');
    });

    test('letras: sin números ni signos', () {
      expect(escribir(Validadores.soloLetrasFmt, 'Ana', 'Ana1').text, 'Ana');
      expect(escribir(Validadores.soloLetrasFmt, 'Ana', 'Ana@').text, 'Ana');
      expect(escribir(Validadores.soloLetrasFmt, 'Ana', 'Ana ñ').text, 'Ana Ñ');
    });

    test('nombres: primera letra de cada palabra en mayúscula', () {
      expect(escribir(Validadores.soloLetrasFmt, '', 'PARACETAMOL genfar').text,
          'Paracetamol Genfar');
      expect(escribir(Validadores.soloLetrasFmt, '', 'áCIDO ASCÓRBICO').text,
          'Ácido Ascórbico');
      expect(Validadores.nombrePropio('  jUAN   pÉREZ '), 'Juan Pérez');
    });

    test('códigos: siempre en mayúsculas', () {
      expect(escribir(Validadores.alfanumericoFmt, '', 'med-0099').text, 'MED-0099');
      expect(escribir(Validadores.alfanumericoFmt, '', 'l2026a01').text, 'L2026A01');
    });

    test('contraseña: no cambia mayúsculas ni minúsculas', () {
      expect(escribir(Validadores.passwordFmt, '', 'AbCd1234').text, 'AbCd1234');
    });
  });
}
