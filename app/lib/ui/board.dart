import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

import '../data/app_state.dart';

/// Capa raster georreferenciada del mapa offline.
///
/// Cada capa es un mosaico de teselas ya unido y empaquetado como asset, con
/// sus límites geográficos: se dibuja con `drawImageRect` bajo la misma
/// proyección que los pares y eventos, sin depender de la red.
class MapLayer {
  MapLayer({
    required this.asset,
    required this.west,
    required this.east,
    required this.north,
    required this.south,
    required this.image,
  });

  final String asset;
  final double west;
  final double east;
  final double north;
  final double south;
  final ui.Image image;

  double get spanLon => east - west;
  double get spanLat => north - south;

  bool intersects(double n, double s, double w, double e) =>
      n > south && s < north && e > west && w < east;

  static Future<MapLayer> load({
    required String asset,
    required double west,
    required double east,
    required double north,
    required double south,
  }) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return MapLayer(
      asset: asset,
      west: west,
      east: east,
      north: north,
      south: south,
      image: frame.image,
    );
  }
}

/// Capas del mapa offline (se cargan una sola vez por proceso).
class OfflineMap {
  OfflineMap._();

  static const String attribution = '© Esri, HERE, Garmin, © OpenStreetMap';

  /// Detalle urbano: Colima centro + Villa de Álvarez (z15, ~6.9 km).
  static const String nearAsset = 'assets/map/colima_z15.jpg';
  static const double nearWest = -103.76586914;
  static const double nearEast = -103.69995117;
  static const double nearNorth = 19.28003580;
  static const double nearSouth = 19.21780296;

  /// Contexto regional (z13, ~18.5 km).
  static const String farAsset = 'assets/map/colima_z13.jpg';
  static const double farWest = -103.84277344;
  static const double farEast = -103.66699219;
  static const double farNorth = 19.35261089;
  static const double farSouth = 19.18667770;

  static MapLayer? near;
  static MapLayer? far;

  /// `true` cuando ya se intentó cargar (con o sin éxito).
  static final ValueNotifier<bool> loaded = ValueNotifier<bool>(false);

  static bool _started = false;

  static Future<void> ensureLoaded() async {
    if (_started) return;
    _started = true;
    try {
      near = await MapLayer.load(
        asset: nearAsset,
        west: nearWest,
        east: nearEast,
        north: nearNorth,
        south: nearSouth,
      );
    } on Object {
      near = null;
    }
    try {
      far = await MapLayer.load(
        asset: farAsset,
        west: farWest,
        east: farEast,
        north: farNorth,
        south: farSouth,
      );
    } on Object {
      far = null;
    }
    loaded.value = true;
  }
}

class TacticalBoard extends StatefulWidget {
  const TacticalBoard({super.key, required this.state});

  final AppState state;

  @override
  State<TacticalBoard> createState() => _TacticalBoardState();
}

class _TacticalBoardState extends State<TacticalBoard> {
  @override
  void initState() {
    super.initState();
    OfflineMap.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: BoardPainter(
        widget.state,
        near: OfflineMap.near,
        far: OfflineMap.far,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class BoardPainter extends CustomPainter {
  BoardPainter(this.state, {this.near, this.far, this.fontFamily});

  final AppState state;
  final MapLayer? near;
  final MapLayer? far;

  /// Familia tipográfica opcional (en pruebas se usa una fuente real para que
  /// la previsualización sea legible; en el teléfono basta la del sistema).
  final String? fontFamily;

  static const _bg = Color(0xFF0B0F14);
  static const _grid = Color(0xFF1B2634);
  static const _muted = Color(0xFF9AAABF);
  static const _peerColor = Color(0xFF35C2FF);
  static const _ownColor = Color(0xFF3DDC84);
  static const _eventColor = Color(0xFFFFB020);

  /// Centro por defecto: Colima capital.
  static const double _defaultLat = 19.2433;
  static const double _defaultLon = -103.7247;

  /// Ventana mínima del tablero (~2 km): por debajo el mapa no da contexto.
  static const double _minSpanLat = 0.018;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);

    final points = <_Geo>[];
    for (final peer in state.peers.values) {
      points.add(_Geo(peer.lat, peer.lon));
    }
    for (final event in state.events) {
      points.add(_Geo(event.lat, event.lon));
    }
    for (final alert in state.alerts) {
      points.add(_Geo(alert.lat, alert.lon));
    }
    if (state.ownLat != null && state.ownLon != null) {
      points.add(_Geo(state.ownLat!, state.ownLon!));
    }

    var centerLat = _defaultLat;
    var centerLon = _defaultLon;
    var spanLat = _minSpanLat;
    var spanLon = _minSpanLat;

    if (points.isNotEmpty) {
      var minLat = points.first.lat;
      var maxLat = minLat;
      var minLon = points.first.lon;
      var maxLon = minLon;
      for (final point in points) {
        minLat = math.min(minLat, point.lat);
        maxLat = math.max(maxLat, point.lat);
        minLon = math.min(minLon, point.lon);
        maxLon = math.max(maxLon, point.lon);
      }
      centerLat = (minLat + maxLat) / 2;
      centerLon = (minLon + maxLon) / 2;
      spanLat = math.max(maxLat - minLat, _minSpanLat);
      spanLon = math.max(maxLon - minLon, _minSpanLat);
    }

    final cosLat = math.cos(centerLat * math.pi / 180).clamp(0.15, 1.0);
    final scale = math.min(
      size.width / (spanLon * cosLat * 1.15),
      size.height / (spanLat * 1.15),
    );

    Offset project(double lat, double lon) => Offset(
      size.width / 2 + (lon - centerLon) * cosLat * scale,
      size.height / 2 - (lat - centerLat) * scale,
    );

    // Ventana geográfica visible (para recortar las capas del mapa).
    final halfLat = size.height / 2 / scale;
    final halfLon = size.width / 2 / (cosLat * scale);
    final north = centerLat + halfLat;
    final south = centerLat - halfLat;
    final west = centerLon - halfLon;
    final east = centerLon + halfLon;

    _drawLayer(canvas, size, project, far, north, south, west, east);
    _drawLayer(canvas, size, project, near, north, south, west, east);

    final hasMap = (near?.intersects(north, south, west, east) ?? false) ||
        (far?.intersects(north, south, west, east) ?? false);
    if (!hasMap) {
      _drawGrid(canvas, size, project, centerLat, centerLon, spanLat, spanLon);
      _text(
        canvas,
        'Sin mapa offline en esta zona',
        Offset(12, size.height * 0.5),
        _muted,
        size: 12,
        shadow: true,
      );
    }

    _drawPlaces(canvas, size, project);

    for (final alert in state.alerts) {
      final center = project(alert.lat, alert.lon);
      final color = _severityColor(alert.severity);
      final radiusPx = math.max(8.0, alert.radiusM / 111320.0 * scale);
      canvas.drawCircle(
        center,
        radiusPx,
        Paint()..color = color.withValues(alpha: 0.10),
      );
      canvas.drawCircle(
        center,
        radiusPx,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color,
      );
      _text(
        canvas,
        alert.title.isEmpty ? 'Alerta' : alert.title,
        center + Offset(radiusPx + 4, -8),
        color,
        chip: true,
      );
    }

    for (final event in state.events) {
      final center = project(event.lat, event.lon);
      final path = Path()
        ..moveTo(center.dx, center.dy - 7)
        ..lineTo(center.dx + 7, center.dy)
        ..lineTo(center.dx, center.dy + 7)
        ..lineTo(center.dx - 7, center.dy)
        ..close();
      canvas.drawPath(path, Paint()..color = _eventColor);
      _text(
        canvas,
        event.note.isEmpty ? 'Evento' : event.note,
        center + const Offset(9, -8),
        _eventColor,
        chip: true,
      );
    }

    for (final peer in state.peers.values) {
      final center = project(peer.lat, peer.lon);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(peer.headingDeg * math.pi / 180);
      final path = Path()
        ..moveTo(0, -9)
        ..lineTo(6, 7)
        ..lineTo(0, 4)
        ..lineTo(-6, 7)
        ..close();
      canvas.drawPath(path, Paint()..color = _peerColor);
      canvas.restore();
      _text(
        canvas,
        '${peer.senderId} · ${peer.batteryPct}%',
        center + const Offset(9, 4),
        _peerColor,
        size: 12,
        chip: true,
      );
    }

    final ownLat = state.ownLat;
    final ownLon = state.ownLon;
    if (ownLat != null && ownLon != null) {
      final center = project(ownLat, ownLon);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _ownColor;
      canvas.drawCircle(center, 9, stroke);
      canvas.drawLine(
        center - const Offset(15, 0),
        center + const Offset(15, 0),
        stroke,
      );
      canvas.drawLine(
        center - const Offset(0, 15),
        center + const Offset(0, 15),
        stroke,
      );
      _text(
        canvas,
        'YO',
        center + const Offset(11, -18),
        _ownColor,
        size: 12,
        chip: true,
      );
    }

    _drawScale(canvas, size, scale, points.isEmpty);
    _text(
      canvas,
      OfflineMap.attribution,
      Offset(math.max(4, size.width - 210), size.height - 11),
      _muted,
      size: 8,
    );

    if (points.isEmpty) {
      _text(
        canvas,
        'Sin datos todavía. Conecta el backend o pulsa SIM.',
        Offset(size.width * 0.05, size.height - 42),
        _muted,
        size: 12,
        shadow: true,
      );
    }
  }

  /// Dibuja una capa raster recortada a su cobertura geográfica.
  void _drawLayer(
    Canvas canvas,
    Size size,
    Offset Function(double, double) project,
    MapLayer? layer,
    double north,
    double south,
    double west,
    double east,
  ) {
    if (layer == null) return;
    if (!layer.intersects(north, south, west, east)) return;

    final topLeft = project(layer.north, layer.west);
    final bottomRight = project(layer.south, layer.east);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(
      layer.image,
      Rect.fromLTWH(
        0,
        0,
        layer.image.width.toDouble(),
        layer.image.height.toDouble(),
      ),
      Rect.fromLTRB(topLeft.dx, topLeft.dy, bottomRight.dx, bottomRight.dy),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  /// Etiquetas propias: el raster no se lee en 480 px, estas sí.
  void _drawPlaces(
    Canvas canvas,
    Size size,
    Offset Function(double, double) project,
  ) {
    const places = <(String, double, double)>[
      ('COLIMA CENTRO', 19.2433, -103.7247),
      ('VILLA DE ÁLVAREZ', 19.2647, -103.7444),
      ('COMALA', 19.3237, -103.7600),
    ];
    for (final (name, lat, lon) in places) {
      final at = project(lat, lon);
      if (at.dx < -100 || at.dx > size.width + 100) continue;
      if (at.dy < -20 || at.dy > size.height + 20) continue;
      _text(
        canvas,
        name,
        at + const Offset(5, -5),
        _muted,
        size: 10,
        shadow: true,
      );
    }
  }

  void _drawGrid(
    Canvas canvas,
    Size size,
    Offset Function(double, double) project,
    double centerLat,
    double centerLon,
    double spanLat,
    double spanLon,
  ) {
    final step = spanLat > 0.5
        ? 0.1
        : spanLat > 0.1
        ? 0.02
        : spanLat > 0.02
        ? 0.005
        : 0.001;
    final paint = Paint()
      ..color = _grid
      ..strokeWidth = 1;

    final latMin = centerLat - spanLat * 0.7;
    final latMax = centerLat + spanLat * 0.7;
    for (
      var lat = (latMin / step).floorToDouble() * step;
      lat <= latMax;
      lat += step
    ) {
      final y = project(lat, centerLon).dy;
      if (y < 0 || y > size.height) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    final lonMin = centerLon - spanLon * 0.7;
    final lonMax = centerLon + spanLon * 0.7;
    for (
      var lon = (lonMin / step).floorToDouble() * step;
      lon <= lonMax;
      lon += step
    ) {
      final x = project(centerLat, lon).dx;
      if (x < 0 || x > size.width) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    _text(
      canvas,
      'Rejilla ${step.toStringAsFixed(3)}°',
      const Offset(8, 8),
      _muted,
      size: 10,
    );
  }

  void _drawScale(Canvas canvas, Size size, double scale, bool empty) {
    if (empty) return;
    final meters = scale > 150 ? 1000 : (scale > 60 ? 500 : 200);
    final px = meters / 111320.0 * scale;
    final origin = Offset(12, size.height - 22);
    final paint = Paint()
      ..color = _muted
      ..strokeWidth = 2;
    canvas.drawLine(origin, origin + Offset(px, 0), paint);
    canvas.drawLine(origin + Offset(0, -4), origin + Offset(0, 4), paint);
    canvas.drawLine(origin + Offset(px, -4), origin + Offset(px, 4), paint);
    _text(canvas, '$meters m', origin + const Offset(0, -16), _muted, size: 10);
  }

  Color _severityColor(int severity) {
    switch (severity) {
      case 3:
        return const Color(0xFFFF5C6C);
      case 2:
        return const Color(0xFFFFB020);
      default:
        return const Color(0xFF35C2FF);
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at,
    Color color, {
    double size = 11,
    bool shadow = false,
    bool chip = false,
  }) {
    if (shadow) {
      final halo = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            color: const Color(0xCC000000),
            fontSize: size,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      halo.paint(canvas, at + const Offset(1, 1));
      halo.dispose();
    }
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontFamily: fontFamily,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (chip) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          at.dx - 3,
          at.dy - 2,
          painter.width + 6,
          painter.height + 4,
        ),
        const Radius.circular(3),
      );
      canvas.drawRRect(rect, Paint()..color = const Color(0xD9080C12));
    }
    painter.paint(canvas, at);
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) =>
      oldDelegate.state != state ||
      oldDelegate.near != near ||
      oldDelegate.far != far;
}

class _Geo {
  const _Geo(this.lat, this.lon);
  final double lat;
  final double lon;
}
