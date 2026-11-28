/// Noticias guardadas en el servidor y celdas del mapa de calor.
///
/// Se consultan en línea (`/api/news`, `/api/heat`): así la app puede ver los
/// sucesos de días pasados aunque ya no estén en el tablero en vivo.
library;

/// Una nota tal como la guardó el monitor.
class Noticia {
  const Noticia({
    required this.id,
    required this.tipo,
    required this.etiqueta,
    required this.lugar,
    required this.municipio,
    required this.lat,
    required this.lon,
    required this.precision,
    required this.cuando,
    required this.texto,
    required this.url,
    required this.imagen,
    required this.fuentes,
  });

  final String id;
  final String tipo;
  final String etiqueta;
  final String lugar;
  final String municipio;
  final double? lat;
  final double? lon;
  final String precision;
  final DateTime? cuando;
  final String texto;
  final String url;
  final String imagen;
  final List<String> fuentes;

  bool get aproximada =>
      precision.contains('aprox') || precision.startsWith('municipio');

  factory Noticia.fromJson(Map<String, dynamic> json) {
    double? numero(Object? v) {
      if (v is num) return v.toDouble();
      return double.tryParse('$v');
    }

    return Noticia(
      id: '${json['id'] ?? ''}',
      tipo: '${json['tipo'] ?? ''}',
      etiqueta: '${json['etiqueta'] ?? ''}',
      lugar: '${json['lugar'] ?? ''}',
      municipio: '${json['municipio'] ?? ''}',
      lat: numero(json['lat']),
      lon: numero(json['lon']),
      precision: '${json['precision'] ?? ''}',
      cuando: DateTime.tryParse('${json['cuando'] ?? ''}')?.toLocal(),
      texto: '${json['texto'] ?? ''}',
      url: '${json['url'] ?? ''}',
      imagen: '${json['imagen'] ?? ''}',
      fuentes: <String>[
        for (final f in (json['fuentes'] is List ? json['fuentes'] as List : const []))
          if (f is String && f.isNotEmpty) f,
      ],
    );
  }
}

/// Celda de la rejilla de incidencias (~500 m).
class CeldaCalor {
  const CeldaCalor({required this.lat, required this.lon, required this.n});

  final double lat;
  final double lon;
  final int n;

  factory CeldaCalor.fromJson(Map<String, dynamic> json) {
    double numero(Object? v) {
      if (v is num) return v.toDouble();
      return double.tryParse('$v') ?? 0;
    }

    return CeldaCalor(
      lat: numero(json['lat']),
      lon: numero(json['lon']),
      n: (json['n'] is num) ? (json['n'] as num).toInt() : int.tryParse('${json['n']}') ?? 0,
    );
  }
}
