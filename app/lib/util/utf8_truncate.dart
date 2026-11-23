import 'dart:convert';

/// Recorta [value] a [maxBytes] bytes UTF-8 sin partir un carácter.
///
/// El protocolo limita las notas a 64 bytes; `String.length` cuenta caracteres,
/// no bytes, así que un texto con acentos o emoji puede superar el límite.
String truncateUtf8(String value, int maxBytes) {
  assert(maxBytes >= 0, 'maxBytes no puede ser negativo');
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end -= 1;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}
