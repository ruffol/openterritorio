import 'dart:convert';
import 'dart:io' show GZipCodec;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/services.dart' show rootBundle;

/// Vías y topónimos del INEGI (conjunto vectorial 1:50 000, serie III).
///
/// Se dibujan como vectores en vez de píxeles: los nombres y las líneas se
/// mantienen nítidos a cualquier zoom, que es justo lo que el mapa ráster no
/// puede dar cuando se amplía más allá de la última tesela disponible.
class VectorData {
  VectorData._();

  /// clase de vía: 0 calle, 1 carretera, 2 camino/vereda
  static List<Via> _vias = const [];
  static List<Localidad> _localidades = const [];
  static final Map<String, List<int>> _indice = {};
  static const double _cell = 0.05; // ~5.5 km
  static bool ready = false;

  static List<Via> get vias => _vias;
  static List<Localidad> get localidades => _localidades;

  static Future<void> load() async {
    if (ready) return;
    try {
      final raw = await rootBundle.load('assets/vector/vias.json.gz');
      final decoded = jsonDecode(
        utf8.decode(GZipCodec().decode(raw.buffer.asUint8List())),
      ) as Map<String, dynamic>;
      final vias = <Via>[];
      for (final item in (decoded['vias'] as List)) {
        final map = item as Map<String, dynamic>;
        final pts = (map['p'] as List);
        final flat = Float32List(pts.length * 2);
        var i = 0;
        for (final p in pts) {
          flat[i++] = (p[0] as num).toDouble();
          flat[i++] = (p[1] as num).toDouble();
        }
        if (flat.length < 4) continue;
        vias.add(Via((map['k'] as num).toInt(), (map['n'] as String?) ?? '', flat));
      }
      _vias = vias;

      final rawLoc = await rootBundle.load('assets/vector/localidades.json.gz');
      final decodedLoc = jsonDecode(
        utf8.decode(GZipCodec().decode(rawLoc.buffer.asUint8List())),
      ) as Map<String, dynamic>;
      _localidades = [
        for (final item in (decodedLoc['localidades'] as List))
          Localidad(
            (item[0] as num).toDouble(),
            (item[1] as num).toDouble(),
            item[2] as String,
            (item[3] as num).toInt(),
          ),
      ];

      _index();
      ready = true;
    } catch (_) {
      ready = false; // sin vectores la app sigue mostrando el ráster
    }
  }

  static void _index() {
    _indice.clear();
    for (var i = 0; i < _vias.length; i++) {
      final via = _vias[i];
      final key = _key(via.minLon, via.minLat);
      _indice.putIfAbsent(key, () => <int>[]).add(i);
      // Las vías largas entran también en las celdas vecinas.
      final key2 = _key(via.maxLon, via.maxLat);
      if (key2 != key) _indice.putIfAbsent(key2, () => <int>[]).add(i);
    }
  }

  static String _key(double lon, double lat) =>
      '${(lon / _cell).floor()}:${(lat / _cell).floor()}';

  /// Vías que pueden tocar el recuadro pedido (índice por celdas).
  static Iterable<Via> viasIn(double west, double south, double east, double north) sync* {
    if (!ready) return;
    final visto = <int>{};
    for (var x = (west / _cell).floor(); x <= (east / _cell).floor(); x++) {
      for (var y = (south / _cell).floor(); y <= (north / _cell).floor(); y++) {
        final ids = _indice['$x:$y'];
        if (ids == null) continue;
        for (final id in ids) {
          if (!visto.add(id)) continue;
          final via = _vias[id];
          if (via.maxLon < west || via.minLon > east) continue;
          if (via.maxLat < south || via.minLat > north) continue;
          yield via;
        }
      }
    }
  }

  static List<Localidad> localidadesIn(
    double west,
    double south,
    double east,
    double north,
  ) =>
      [
        for (final l in _localidades)
          if (l.lon >= west && l.lon <= east && l.lat >= south && l.lat <= north) l,
      ];
}

class Via {
  Via(this.kind, this.name, this.flat) {
    var minLon = double.infinity, minLat = double.infinity;
    var maxLon = -double.infinity, maxLat = -double.infinity;
    for (var i = 0; i < flat.length; i += 2) {
      final lon = flat[i], lat = flat[i + 1];
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
    }
    minLon_ = minLon;
    minLat_ = minLat;
    maxLon_ = maxLon;
    maxLat_ = maxLat;
  }

  final int kind; // 0 calle, 1 carretera, 2 camino
  final String name;
  final Float32List flat;
  late final double minLon_, minLat_, maxLon_, maxLat_;

  double get minLon => minLon_;
  double get minLat => minLat_;
  double get maxLon => maxLon_;
  double get maxLat => maxLat_;

  int get points => flat.length ~/ 2;

  Offset pointAt(int i) => Offset(flat[i * 2], flat[i * 2 + 1]);

  /// Punto medio geométrico aproximado (para colocar la etiqueta).
  Offset get midLabel {
    final mid = points ~/ 2;
    return pointAt(mid);
  }
}

class Localidad {
  const Localidad(this.lon, this.lat, this.name, this.habitantes);

  final double lon;
  final double lat;
  final String name;
  final int habitantes;

  bool get urbana => habitantes >= 2500;
}
