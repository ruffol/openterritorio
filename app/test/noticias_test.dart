import 'package:flutter_test/flutter_test.dart';
import 'package:openterritorio/data/noticias.dart';

void main() {
  test('una noticia aproximada se marca como tal', () {
    final n = Noticia.fromJson(<String, dynamic>{
      'id': 'n1',
      'tipo': 'Homicidio',
      'etiqueta': 'Homicidio · Colima (aprox)',
      'lugar': 'Colima',
      'municipio': 'colima',
      'lat': 19.2433,
      'lon': -103.7247,
      'precision': 'municipio (aprox)',
      'cuando': '2026-11-26T03:00:00.000Z',
      'texto': 'cita',
      'fuentes': <String>['afmedios', 'meganoticias'],
    });
    expect(n.aproximada, isTrue);
    expect(n.fuentes.length, 2);
    expect(n.cuando, isNotNull);
    expect(n.lat, closeTo(19.2433, 1e-6));
  });

  test('una noticia con lugar exacto no es aproximada', () {
    final n = Noticia.fromJson(<String, dynamic>{
      'id': 'n2',
      'precision': 'vía (OSM)',
      'lat': 19.25,
      'lon': -103.75,
    });
    expect(n.aproximada, isFalse);
  });

  test('las celdas de calor leen el conteo', () {
    final c = CeldaCalor.fromJson(<String, dynamic>{'lat': 19.24, 'lon': -103.72, 'n': 5});
    expect(c.n, 5);
    expect(c.lat, closeTo(19.24, 1e-9));
  });
}
