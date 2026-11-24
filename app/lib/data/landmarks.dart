import 'package:material_ui/material_ui.dart';

/// Punto fijo del tablero (universidad, punto de sangre, etc.).
///
/// Los sirve el backend en `GET /api/landmarks`, así que se pueden cambiar sin
/// recompilar la app; [kLandmarks] es solo el respaldo cuando no hay enlace.
class Landmark {
  const Landmark({
    required this.name,
    required this.lat,
    required this.lon,
    required this.emoji,
    required this.radiusM,
    required this.colors,
  });

  final String name;
  final double lat;
  final double lon;
  final String emoji;
  final double radiusM;

  /// Uno o varios colores; con dos o más el anillo se dibuja a franjas.
  final List<Color> colors;

  Color get color => colors.isEmpty ? const Color(0xFF35C2FF) : colors.first;

  static Color? _parseColor(Object? value) {
    final text = value?.toString().replaceFirst('#', '') ?? '';
    if (text.length != 6) return null;
    final rgb = int.tryParse(text, radix: 16);
    if (rgb == null) return null;
    return Color(0xFF000000 | rgb);
  }

  factory Landmark.fromJson(Map<String, dynamic> json) {
    final radius = (json['radius_m'] ?? json['radiusM'] ?? 0) as num? ?? 0;
    final rawColors = json['colors'];
    final colors = <Color>[];
    if (rawColors is List) {
      for (final item in rawColors) {
        final color = _parseColor(item);
        if (color != null) colors.add(color);
      }
    }
    if (colors.isEmpty) {
      final single = _parseColor(json['color']);
      colors.add(single ?? const Color(0xFF35C2FF));
    }
    return Landmark(
      name: (json['name'] ?? 'Punto').toString(),
      lat: ((json['lat'] ?? 0) as num).toDouble(),
      lon: ((json['lon'] ?? 0) as num).toDouble(),
      emoji: (json['emoji'] ?? '📍').toString(),
      radiusM: radius.toDouble(),
      colors: colors,
    );
  }
}

/// Respaldo local: lo mismo que sirve el backend por defecto.
const List<Landmark> kLandmarks = <Landmark>[
  // 19°18'53.9"N 103°45'31.6"W
  Landmark(
    name: 'UNIVERSIDAD',
    lat: 19.31497222,
    lon: -103.75877778,
    emoji: '🎓',
    radiusM: 50,
    colors: <Color>[Color(0xFF3DDC84)],
  ),
  // 19°15'18.4"N 103°43'45.7"W
  Landmark(
    name: 'SANGRE',
    lat: 19.25511111,
    lon: -103.72936111,
    emoji: '🩸',
    radiusM: 500,
    colors: <Color>[Color(0xFFFF3B30), Color(0xFF1E90FF)],
  ),
  // 19°16'00.8"N 103°43'38.7"W
  Landmark(
    name: 'MARRÓN',
    lat: 19.26688889,
    lon: -103.72741667,
    emoji: '🟤',
    radiusM: 100,
    colors: <Color>[Color(0xFFA0522D)],
  ),
];
