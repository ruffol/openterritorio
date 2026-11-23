import 'package:flutter_test/flutter_test.dart';
import 'package:openterritorio/util/utf8_truncate.dart';

void main() {
  group('truncateUtf8', () {
    test('deja intacto un texto dentro del límite', () {
      expect(truncateUtf8('abc', 10), 'abc');
    });

    test('recorta ASCII exacto', () {
      expect(truncateUtf8('abcdef', 3), 'abc');
    });

    test('no parte caracteres de dos bytes', () {
      // 'ñ' ocupa 2 bytes: el límite de 5 cae en medio del último carácter.
      expect(truncateUtf8('aaaañ', 5), 'aaaa');
      expect(truncateUtf8('ñññ', 4), 'ññ');
    });

    test('descarta un emoji que no cabe entero', () {
      expect(truncateUtf8('a🙂', 3), 'a');
      expect(truncateUtf8('🙂', 4), '🙂');
    });

    test('límite cero devuelve cadena vacía', () {
      expect(truncateUtf8('texto', 0), '');
    });
  });
}
