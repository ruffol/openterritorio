import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

import '../data/app_state.dart';

/// Punto fijo del tablero (no depende del backend ni de la red).
class Landmark {
  const Landmark({
    required this.name,
    required this.lat,
    required this.lon,
    required this.emoji,
    required this.radiusM,
    required this.color,
  });

  final String name;
  final double lat;
  final double lon;
  final String emoji;
  final double radiusM;
  final Color color;
}

/// Referencias permanentes: se dibujan siempre, con su anillo de radio real.
const List<Landmark> kLandmarks = <Landmark>[
  // 19°18'53.9"N 103°45'31.6"W
  Landmark(
    name: 'UNIVERSIDAD',
    lat: 19.31497222,
    lon: -103.75877778,
    emoji: '🎓',
    radiusM: 50,
    color: Color(0xFF3DDC84),
  ),
  // 19°15'18.4"N 103°43'45.7"W
  Landmark(
    name: 'SANGRE',
    lat: 19.25511111,
    lon: -103.72936111,
    emoji: '🩸',
    radiusM: 500,
    color: Color(0xFFFF3B30),
  ),
];

/// Capas de mapa offline disponibles.
enum MapLayerId {
  oscuro('Oscuro (Esri)', 'assets/tiles/oscuro', '© Esri, HERE, Garmin, © OpenStreetMap'),
  osm('Calles (OpenStreetMap)', 'assets/tiles/osm', '© OpenStreetMap contributors'),
  inegi('INEGI (Mapa Digital)', 'assets/tiles/inegi', '© INEGI · Mapa Digital de México');

  const MapLayerId(this.label, this.assetDir, this.attribution);

  final String label;
  final String assetDir;
  final String attribution;
}

/// Estado de cámara del tablero: centro, zoom continuo y capa activa.
///
/// El zoom es la fuente de verdad del mapa (no el `InteractiveViewer`): así las
/// teselas se piden en el nivel correcto al acercarse y las calles aparecen.
class MapViewport extends ChangeNotifier {
  MapViewport({
    this.centerLat = 19.2433,
    this.centerLon = -103.7247,
    this.zoom = 15,
    this.layer = MapLayerId.oscuro,
  });

  static const double minZoom = 10;
  static const double maxZoom = 17;
  static const int tileSize = 256;

  double centerLat;
  double centerLon;
  double zoom;
  MapLayerId layer;

  /// Mientras el operador no mueva el mapa, la cámara sigue su GPS.
  bool follow = true;

  static double merc(double latDeg) =>
      math.log(math.tan(math.pi / 4 + latDeg * math.pi / 360));

  static double invMerc(double value) =>
      (2 * math.atan(math.exp(value)) - math.pi / 2) * 180 / math.pi;

  /// Píxeles por grado de longitud a un zoom dado.
  static double scaleFor(double zoom) =>
      tileSize * math.pow(2, zoom).toDouble() / 360;

  /// Píxeles por unidad Mercator (Y).
  static double mercScaleFor(double zoom) => scaleFor(zoom) * 180 / math.pi;

  double get metersPerPixel =>
      156543.03392 * math.cos(centerLat * math.pi / 180) / math.pow(2, zoom);

  void goTo(double lat, double lon, {double? zoom, bool takeControl = false}) {
    if (takeControl) follow = false;
    centerLat = lat;
    centerLon = lon;
    if (zoom != null) zoom = zoom.clamp(minZoom, maxZoom);
    notifyListeners();
  }

  void setLayer(MapLayerId id) {
    if (id == layer) return;
    layer = id;
    notifyListeners();
  }

  void setZoom(double zoom) {
    final next = zoom.clamp(minZoom, maxZoom);
    if (next == zoom) return;
    zoom = next;
    notifyListeners();
  }

  /// Desplaza la cámara `dx, dy` píxeles de pantalla (dedo).
  void panPixels(double dx, double dy, Size size) {
    follow = false;
    final scale = scaleFor(zoom);
    final mercScale = mercScaleFor(zoom);
    centerLon -= dx / scale;
    centerLat = invMerc(merc(centerLat) + dy / mercScale);
    notifyListeners();
  }

  /// Zoom multiplicativo manteniendo fijo el punto `focal` de la pantalla.
  void zoomAt(Offset focal, double factor, Size size) {
    if (!factor.isFinite || factor <= 0) return;
    follow = false;
    final before = geoAt(focal, size);
    final next = (zoom + math.log(factor) / math.ln2).clamp(minZoom, maxZoom);
    if (next == zoom) return;
    zoom = next;
    final after = geoAt(focal, size);
    centerLon += before.lon - after.lon;
    centerLat = invMerc(merc(centerLat) + (merc(before.lat) - merc(after.lat)));
    notifyListeners();
  }

  ({double lat, double lon}) geoAt(Offset point, Size size) {
    final scale = scaleFor(zoom);
    final mercScale = mercScaleFor(zoom);
    return (
      lat: invMerc(merc(centerLat) - (point.dy - size.height / 2) / mercScale),
      lon: centerLon + (point.dx - size.width / 2) / scale,
    );
  }

  Offset project(double lat, double lon, Size size) => Offset(
    size.width / 2 + (lon - centerLon) * scaleFor(zoom),
    size.height / 2 - (merc(lat) - merc(centerLat)) * mercScaleFor(zoom),
  );
}

/// Pirámide de teselas por capa, con caché LRU (memoria acotada).
class OfflineTiles {
  OfflineTiles._();

  static const int minZoom = 10;
  static const int maxZoom = 17;

  /// Teselas decodificadas que se conservan (96 × 256² ≈ 25 MB).
  static int capacity = 96;

  static final LinkedHashMap<String, ui.Image> _images = LinkedHashMap();
  static final Set<String> _loading = <String>{};
  static final Set<String> _missing = <String>{};

  /// Cambia cuando entra una tesela nueva (el tablero se repinta).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String assetPath(MapLayerId layer, int z, int x, int y) =>
      '${layer.assetDir}/colima_${z}_${x}_$y.jpg';

  static String _key(MapLayerId layer, int z, int x, int y) => '${layer.name}:$z:$x:$y';

  static ui.Image? get(MapLayerId layer, int z, int x, int y) =>
      _images[_key(layer, z, x, y)];

  static void request(MapLayerId layer, int z, int x, int y) {
    if (z < minZoom || z > maxZoom) return;
    final key = _key(layer, z, x, y);
    if (_images.containsKey(key) || _loading.contains(key) || _missing.contains(key)) {
      return;
    }
    _loading.add(key);
    rootBundle
        .load(assetPath(layer, z, x, y))
        .then((data) async {
          final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
          final frame = await codec.getNextFrame();
          put(layer, z, x, y, frame.image);
        })
        .catchError((Object _) {
          // Fuera de cobertura en esa capa/nivel: no se vuelve a intentar.
          _missing.add(key);
        })
        .whenComplete(() => _loading.remove(key));
  }

  static void put(MapLayerId layer, int z, int x, int y, ui.Image image) {
    final key = _key(layer, z, x, y);
    _images.remove(key)?.dispose();
    _images[key] = image;
    while (_images.length > capacity) {
      _images.remove(_images.keys.first)?.dispose();
    }
    revision.value++;
  }

  /// Tesela del mismo punto en un nivel inferior ya cargado.
  static ui.Image? fallback(MapLayerId layer, int z, int x, int y, {int levels = 4}) {
    for (var dz = 1; dz <= levels; dz++) {
      final zz = z - dz;
      if (zz < minZoom) break;
      final factor = 1 << dz;
      final img = get(layer, zz, x ~/ factor, y ~/ factor);
      if (img != null) return img;
    }
    return null;
  }

  static void seedForTest(MapLayerId layer, int z, int x, int y, ui.Image image) =>
      put(layer, z, x, y, image);
}

class TacticalBoard extends StatefulWidget {
  const TacticalBoard({super.key, required this.state, required this.viewport});

  final AppState state;
  final MapViewport viewport;

  @override
  State<TacticalBoard> createState() => _TacticalBoardState();
}

class _TacticalBoardState extends State<TacticalBoard> {
  Offset _lastFocal = Offset.zero;
  double _lastScale = 1;

  @override
  void initState() {
    super.initState();
    OfflineTiles.revision.addListener(_refresh);
    widget.viewport.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    OfflineTiles.revision.removeListener(_refresh);
    widget.viewport.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (details) {
            _lastFocal = details.localFocalPoint;
            _lastScale = 1;
          },
          onScaleUpdate: (details) {
            final delta = details.localFocalPoint - _lastFocal;
            if (delta.distance > 0.2) {
              widget.viewport.panPixels(delta.dx, delta.dy, size);
            }
            final factor = details.scale / _lastScale;
            if ((factor - 1).abs() > 0.002) {
              widget.viewport.zoomAt(details.localFocalPoint, factor, size);
            }
            _lastFocal = details.localFocalPoint;
            _lastScale = details.scale;
          },
          onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
          onDoubleTap: () {
            final at = _doubleTapAt ?? size.center(Offset.zero);
            widget.viewport.zoomAt(at, 2.0, size);
          },
          child: CustomPaint(
            painter: BoardPainter(widget.state, widget.viewport),
            child: SizedBox(width: size.width, height: size.height),
          ),
        );
      },
    );
  }

  Offset? _doubleTapAt;
}

class BoardPainter extends CustomPainter {
  BoardPainter(this.state, this.viewport, {this.fontFamily});

  final AppState state;
  final MapViewport viewport;
  final String? fontFamily;

  static const _bg = Color(0xFF0B0F14);
  static const _grid = Color(0xFF1B2634);
  static const _muted = Color(0xFF9AAABF);
  static const _peerColor = Color(0xFF35C2FF);
  static const _ownColor = Color(0xFF3DDC84);
  static const _eventColor = Color(0xFFFFB020);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);

    final painted = _drawTiles(canvas, size);
    if (!painted) {
      _drawGrid(canvas, size);
      _text(
        canvas,
        'Sin mapa offline en esta zona',
        Offset(12, size.height * 0.5),
        _muted,
        size: 12,
        shadow: true,
      );
    }

    _drawPlaces(canvas, size);
    _drawLandmarks(canvas, size);

    for (final alert in state.alerts) {
      final center = viewport.project(alert.lat, alert.lon, size);
      final color = _severityColor(alert.severity);
      final radiusPx = math.max(8.0, alert.radiusM / viewport.metersPerPixel);
      canvas.drawCircle(center, radiusPx, Paint()..color = color.withValues(alpha: 0.10));
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
      final center = viewport.project(event.lat, event.lon, size);
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
      final center = viewport.project(peer.lat, peer.lon, size);
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
      final center = viewport.project(ownLat, ownLon, size);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _ownColor;
      canvas.drawCircle(center, 9, stroke);
      canvas.drawLine(center - const Offset(15, 0), center + const Offset(15, 0), stroke);
      canvas.drawLine(center - const Offset(0, 15), center + const Offset(0, 15), stroke);
      _text(canvas, 'YO', center + const Offset(11, -18), _ownColor, size: 12, chip: true);
    }

    _drawScale(canvas, size);
    _drawAttribution(canvas, size);
    _drawLayerBadge(canvas, size);
  }

  bool _drawTiles(Canvas canvas, Size size) {
    final zoom = viewport.zoom.round().clamp(OfflineTiles.minZoom, OfflineTiles.maxZoom);
    final layer = viewport.layer;
    final n = 1 << zoom;
    final lonPerTile = 360 / n;

    final northWest = viewport.geoAt(Offset.zero, size);
    final southEast = viewport.geoAt(Offset(size.width, size.height), size);

    int xFor(double lon) => ((lon + 180) / lonPerTile).floor().clamp(0, n - 1);
    int yFor(double lat) {
      final rad = lat * math.pi / 180;
      final y = (1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n;
      return y.floor().clamp(0, n - 1);
    }

    final x0 = xFor(northWest.lon);
    final x1 = xFor(southEast.lon);
    final y0 = yFor(northWest.lat);
    final y1 = yFor(southEast.lat);

    var painted = false;
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final tileWest = x * lonPerTile - 180;
        final tileEast = (x + 1) * lonPerTile - 180;
        final tileNorth = _tileLat(y, zoom);
        final tileSouth = _tileLat(y + 1, zoom);
        final dest = Rect.fromPoints(
          viewport.project(tileNorth, tileWest, size),
          viewport.project(tileSouth, tileEast, size),
        );

        final img = OfflineTiles.get(layer, zoom, x, y);
        if (img != null) {
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            dest,
            Paint()..filterQuality = FilterQuality.low,
          );
          painted = true;
          continue;
        }

        OfflineTiles.request(layer, zoom, x, y);

        final parent = OfflineTiles.fallback(layer, zoom, x, y);
        if (parent == null) continue;
        final dz = _fallbackDepth(layer, zoom, x, y, parent);
        if (dz <= 0) continue;
        final factor = 1 << dz;
        final subW = parent.width / factor;
        final subH = parent.height / factor;
        canvas.drawImageRect(
          parent,
          Rect.fromLTWH((x % factor) * subW, (y % factor) * subH, subW, subH),
          dest,
          Paint()..filterQuality = FilterQuality.low,
        );
        painted = true;
      }
    }
    return painted;
  }

  int _fallbackDepth(MapLayerId layer, int zoom, int x, int y, ui.Image image) {
    for (var dz = 1; dz <= 4; dz++) {
      final zz = zoom - dz;
      if (zz < OfflineTiles.minZoom) break;
      final factor = 1 << dz;
      if (identical(OfflineTiles.get(layer, zz, x ~/ factor, y ~/ factor), image)) {
        return dz;
      }
    }
    return 0;
  }

  double _tileLat(int y, int zoom) {
    final n = math.pi - 2 * math.pi * y / (1 << zoom);
    return (2 * math.atan(math.exp(n)) - math.pi / 2) * 180 / math.pi;
  }

  /// Puntos fijos con anillo de radio real y emoji.
  void _drawLandmarks(Canvas canvas, Size size) {
    for (final place in kLandmarks) {
      final center = viewport.project(place.lat, place.lon, size);
      if (center.dx < -80 || center.dx > size.width + 80) continue;
      if (center.dy < -80 || center.dy > size.height + 80) continue;

      final radiusPx = place.radiusM / viewport.metersPerPixel;
      if (radiusPx >= 3) {
        canvas.drawCircle(
          center,
          radiusPx,
          Paint()..color = place.color.withValues(alpha: 0.14),
        );
        canvas.drawCircle(
          center,
          radiusPx,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = place.color,
        );
      }

      _text(
        canvas,
        place.emoji,
        center + Offset(-11, -13),
        place.color,
        size: 20,
      );
      _text(
        canvas,
        place.name,
        center + const Offset(10, -6),
        place.color,
        size: 11,
        chip: true,
      );
    }
  }

  void _drawPlaces(Canvas canvas, Size size) {
    const places = <(String, double, double)>[
      ('COLIMA', 19.2433, -103.7247),
      ('VILLA DE ÁLVAREZ', 19.2647, -103.7444),
      ('COMALA', 19.3237, -103.7600),
      ('MANZANILLO', 19.1138, -104.3267),
      ('TECOMÁN', 18.9108, -103.8747),
      ('ARMERÍA', 18.9383, -103.9642),
      ('VOLCÁN DE COLIMA', 19.5144, -103.6186),
    ];
    for (final (name, lat, lon) in places) {
      final at = viewport.project(lat, lon, size);
      if (at.dx < -120 || at.dx > size.width + 120) continue;
      if (at.dy < -20 || at.dy > size.height + 20) continue;
      _text(canvas, name, at + const Offset(5, -5), _muted, size: 10, shadow: true);
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    const degrees = [0.5, 0.25, 0.1, 0.05, 0.02, 0.01, 0.005];
    final pxPerDegree = MapViewport.scaleFor(viewport.zoom);
    final step = degrees.firstWhere((d) => d * pxPerDegree > 60, orElse: () => 0.005);
    final paint = Paint()
      ..color = _grid
      ..strokeWidth = 1;

    final northWest = viewport.geoAt(Offset.zero, size);
    final southEast = viewport.geoAt(Offset(size.width, size.height), size);
    for (var lat = (southEast.lat / step).floorToDouble() * step;
        lat <= northWest.lat;
        lat += step) {
      final y = viewport.project(lat, viewport.centerLon, size).dy;
      if (y < 0 || y > size.height) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (var lon = (northWest.lon / step).floorToDouble() * step;
        lon <= southEast.lon;
        lon += step) {
      final x = viewport.project(viewport.centerLat, lon, size).dx;
      if (x < 0 || x > size.width) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    _text(canvas, 'Rejilla ${step.toStringAsFixed(3)}°', const Offset(8, 8), _muted, size: 10);
  }

  void _drawLayerBadge(Canvas canvas, Size size) {
    _text(
      canvas,
      viewport.layer.label,
      Offset(8, size.height - 64),
      _muted,
      size: 9,
      shadow: true,
    );
  }

  void _drawAttribution(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: viewport.layer.attribution,
        style: TextStyle(
          color: _muted,
          fontSize: 8,
          fontFamily: fontFamily,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(math.max(4, size.width - painter.width - 6), size.height - painter.height - 4),
    );
    painter.dispose();
  }

  void _drawScale(Canvas canvas, Size size) {
    final metersPerPixel = viewport.metersPerPixel;
    final candidates = <double>[
      25, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000,
    ];
    var meters = candidates.last;
    for (final candidate in candidates) {
      if (candidate / metersPerPixel >= 60) {
        meters = candidate;
        break;
      }
    }
    final px = meters / metersPerPixel;
    final origin = Offset(12, size.height - 22);
    final paint = Paint()
      ..color = _muted
      ..strokeWidth = 2;
    canvas.drawLine(origin, origin + Offset(px, 0), paint);
    canvas.drawLine(origin + Offset(0, -4), origin + Offset(0, 4), paint);
    canvas.drawLine(origin + Offset(px, -4), origin + Offset(px, 4), paint);
    final label = meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(meters % 1000 == 0 ? 0 : 1)} km'
        : '${meters.toStringAsFixed(0)} m';
    _text(canvas, label, origin + const Offset(0, -16), _muted, size: 10);
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
            fontFamily: fontFamily,
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
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(at.dx - 3, at.dy - 2, painter.width + 6, painter.height + 4),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0xD9080C12),
      );
    }
    painter.paint(canvas, at);
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) =>
      oldDelegate.state != state ||
      oldDelegate.viewport != viewport ||
      oldDelegate.fontFamily != fontFamily;
}
