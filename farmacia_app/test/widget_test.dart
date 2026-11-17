import 'package:farmacia_app/utils/validadores.dart';
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
  });
}
