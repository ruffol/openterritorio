import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

import '../data/app_state.dart';

/// Pirámide de teselas del mapa offline (todo el estado de Colima).
///
/// Se guardan como assets planos (`assets/tiles/colima_<z>_<x>_<y>.jpg`) y se
/// cargan bajo demanda con una caché LRU: el mapa puede pesar cientos de MB en
/// disco sin que el teléfono tenga que decodificarlo entero en memoria.
class OfflineTiles {
  OfflineTiles._();

  static const int minZoom = 10;
  static const int maxZoom = 16;
  static const int tileSize = 256;
  static const int _capacity = 96;

  static const String attribution = '© Esri, HERE, Garmin, © OpenStreetMap';

  static final LinkedHashMap<String, ui.Image> _images =
      LinkedHashMap<String, ui.Image>();
  static final Set<String> _loading = <String>{};

  /// Cambia cada vez que entra una tesela nueva (el tablero se repinta).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String assetPath(int z, int x, int y) =>
      'assets/tiles/colima_${z}_${x}_$y.jpg';

  static String _key(int z, int x, int y) => '$z:$x:$y';

  static ui.Image? get(int z, int x, int y) => _images[_key(z, x, y)];

  /// Pide una tesela una sola vez y avisa cuando llega.
  static void request(int z, int x, int y) {
    if (z < minZoom || z > maxZoom) return;
    final key = _key(z, x, y);
    if (_images.containsKey(key) || _loading.contains(key)) return;
    _loading.add(key);
    rootBundle
        .load(assetPath(z, x, y))
        .then((data) async {
          final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
          final frame = await codec.getNextFrame();
          put(z, x, y, frame.image);
        })
        .catchError((Object _) {
          // Fuera de cobertura: no hay asset para esa tesela.
        })
        .whenComplete(() => _loading.remove(key));
  }

  /// Inserta una tesela en la caché (también lo usa la prueba de render).
  static void put(int z, int x, int y, ui.Image image) {
    final key = _key(z, x, y);
    _images.remove(key)?.dispose();
    _images[key] = image;
    while (_images.length > _capacity) {
      final oldest = _images.keys.first;
      _images.remove(oldest)?.dispose();
    }
    revision.value++;
  }

  /// Tesela ya cargada de la misma zona en un nivel inferior (respaldo mientras
  /// llega la definitiva, o donde no hay nivel alto).
  static ui.Image? fallback(int z, int x, int y, {int levels = 3}) {
    for (var dz = 1; dz <= levels; dz++) {
      final zz = z - dz;
      if (zz < minZoom) break;
      final factor = 1 << dz;
      final img = get(zz, x ~/ factor, y ~/ factor);
      if (img != null) return img;
    }
    return null;
  }

  static void seedForTest(int z, int x, int y, ui.Image image) => put(z, x, y, image);
}

/// Proyección Web Mercator (la misma de las teselas) y ventana visible.
class _View {
  _View({
    required this.centerLat,
    required this.centerLon,
    required this.scale,
    required this.size,
  });

  /// Centro geográfico del tablero.
  final double centerLat;
  final double centerLon;

  /// Píxeles por grado de longitud en el centro.
  final double scale;
  final Size size;

  static double _merc(double latDeg) =>
      math.log(math.tan(math.pi / 4 + latDeg * math.pi / 360));

  static double _invMerc(double value) =>
      (2 * math.atan(math.exp(value)) - math.pi / 2) * 180 / math.pi;

  /// Píxeles por unidad Mercator (la Y crece hacia el norte).
  double get mercScale => scale * 180 / math.pi;

  Offset project(double lat, double lon) => Offset(
    size.width / 2 + (lon - centerLon) * scale,
    size.height / 2 - (_merc(lat) - _merc(centerLat)) * mercScale,
  );

  double lonAt(double x) => centerLon + (x - size.width / 2) / scale;

  double latAt(double y) => _invMerc(_merc(centerLat) - (y - size.height / 2) / mercScale);

  /// Zoom de teselas que mejor coincide con la escala actual.
  int get zoom =>
      (math.log(scale * 360 / OfflineTiles.tileSize) / math.ln2).round().clamp(
        OfflineTiles.minZoom,
        OfflineTiles.maxZoom,
      );

  double metersPerPixel(int zoom) =>
      156543.03392 * math.cos(centerLat * math.pi / 180) / (1 << zoom);
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
    OfflineTiles.revision.addListener(_onTiles);
  }

  void _onTiles() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    OfflineTiles.revision.removeListener(_onTiles);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: BoardPainter(widget.state),
      child: const SizedBox.expand(),
    );
  }
}

class BoardPainter extends CustomPainter {
  BoardPainter(this.state, {this.fontFamily});

  final AppState state;

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

  /// Ventana mínima del tablero (~2 km): por debajo se pierde el contexto.
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

    final view = _View(
      centerLat: centerLat,
      centerLon: centerLon,
      scale: math.min(size.width / (spanLon * 1.15), size.height / (spanLat * 1.15)),
      size: size,
    );
    final zoom = view.zoom;

    final painted = _drawTiles(canvas, size, view, zoom);

    if (!painted) {
      _drawGrid(canvas, size, view);
      _text(
        canvas,
        'Sin mapa offline en esta zona',
        Offset(12, size.height * 0.5),
        _muted,
        size: 12,
        shadow: true,
      );
    }

    _drawPlaces(canvas, size, view);

    for (final alert in state.alerts) {
      final center = view.project(alert.lat, alert.lon);
      final color = _severityColor(alert.severity);
      final metersPerPx = view.metersPerPixel(zoom);
      final radiusPx = math.max(8.0, alert.radiusM / metersPerPx);
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
      final center = view.project(event.lat, event.lon);
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
      final center = view.project(peer.lat, peer.lon);
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
      final center = view.project(ownLat, ownLon);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _ownColor;
      canvas.drawCircle(center, 9, stroke);
      canvas.drawLine(center - const Offset(15, 0), center + const Offset(15, 0), stroke);
      canvas.drawLine(center - const Offset(0, 15), center + const Offset(0, 15), stroke);
      _text(canvas, 'YO', center + const Offset(11, -18), _ownColor, size: 12, chip: true);
    }

    _drawScale(canvas, size, view.metersPerPixel(zoom));
    _drawAttribution(canvas, size);

    if (points.isEmpty) {
      _text(
        canvas,
        'Sin datos todavía. Conecta el backend o pulsa SIM.',
        Offset(size.width * 0.05, size.height - 64),
        _muted,
        size: 12,
        shadow: true,
      );
    }
  }

  /// Dibuja las teselas visibles del nivel elegido. Devuelve `false` si no hay
  /// ninguna disponible (ni siquiera de respaldo) para esta ventana.
  bool _drawTiles(Canvas canvas, Size size, _View view, int zoom) {
    final n = 1 << zoom;
    final lonPerTile = 360 / n;

    final west = view.lonAt(0);
    final east = view.lonAt(size.width);
    final north = view.latAt(0);
    final south = view.latAt(size.height);

    int xFor(double lon) => ((lon + 180) / lonPerTile).floor().clamp(0, n - 1);
    int yFor(double lat) {
      final rad = lat * math.pi / 180;
      final y = (1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n;
      return y.floor().clamp(0, n - 1);
    }

    final x0 = xFor(west);
    final x1 = xFor(east);
    final y0 = yFor(north);
    final y1 = yFor(south);

    var painted = false;
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final img = OfflineTiles.get(zoom, x, y);
        final tileNorth = _tileLat(y, zoom);
        final tileSouth = _tileLat(y + 1, zoom);
        final tileWest = x * lonPerTile - 180;
        final tileEast = (x + 1) * lonPerTile - 180;
        final topLeft = view.project(tileNorth, tileWest);
        final bottomRight = view.project(tileSouth, tileEast);
        final dest = Rect.fromLTRB(topLeft.dx, topLeft.dy, bottomRight.dx, bottomRight.dy);

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

        OfflineTiles.request(zoom, x, y);

        // Respaldo: la misma zona en un nivel inferior ya cargado.
        final parent = OfflineTiles.fallback(zoom, x, y);
        if (parent != null) {
          final dz = zoom - _levelOf(parent, zoom, x, y);
          final factor = 1 << dz;
          final subW = parent.width.toDouble() / factor;
          final subH = parent.height.toDouble() / factor;
          final src = Rect.fromLTWH((x % factor) * subW, (y % factor) * subH, subW, subH);
          canvas.drawImageRect(
            parent,
            src,
            dest,
            Paint()..filterQuality = FilterQuality.low,
          );
          painted = true;
        }
      }
    }
    return painted;
  }

  /// Nivel del que provino el respaldo (para recortar el cuadrante correcto).
  int _levelOf(ui.Image image, int zoom, int x, int y) {
    for (var dz = 1; dz <= 3; dz++) {
      final zz = zoom - dz;
      if (zz < OfflineTiles.minZoom) break;
      final factor = 1 << dz;
      if (identical(OfflineTiles.get(zz, x ~/ factor, y ~/ factor), image)) {
        return zz;
      }
    }
    return zoom;
  }

  double _tileLat(int y, int zoom) {
    final n = math.pi - 2 * math.pi * y / (1 << zoom);
    // atan(sinh(n)) sin depender de dart:math (que no expone sinh).
    return (2 * math.atan(math.exp(n)) - math.pi / 2) * 180 / math.pi;
  }

  /// Etiquetas propias: el raster no se lee en 480 px, estas sí.
  void _drawPlaces(Canvas canvas, Size size, _View view) {
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
      final at = view.project(lat, lon);
      if (at.dx < -120 || at.dx > size.width + 120) continue;
      if (at.dy < -20 || at.dy > size.height + 20) continue;
      _text(canvas, name, at + const Offset(5, -5), _muted, size: 10, shadow: true);
    }
  }

  void _drawGrid(Canvas canvas, Size size, _View view) {
    const degrees = [0.5, 0.25, 0.1, 0.05, 0.02, 0.01];
    final pxPerDegree = view.scale;
    final step = degrees.firstWhere(
      (d) => d * pxPerDegree > 60,
      orElse: () => 0.01,
    );
    final paint = Paint()
      ..color = _grid
      ..strokeWidth = 1;

    final north = view.latAt(0);
    final south = view.latAt(size.height);
    for (var lat = (south / step).floorToDouble() * step; lat <= north; lat += step) {
      final y = view.project(lat, view.centerLon).dy;
      if (y < 0 || y > size.height) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final west = view.lonAt(0);
    final east = view.lonAt(size.width);
    for (var lon = (west / step).floorToDouble() * step; lon <= east; lon += step) {
      final x = view.project(view.centerLat, lon).dx;
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

  /// Atribución alineada a la derecha y medida antes de dibujar: es una
  /// condición de la licencia, no puede quedar recortada.
  void _drawAttribution(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: OfflineTiles.attribution,
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

  void _drawScale(Canvas canvas, Size size, double metersPerPixel) {
    final candidates = <double>[
      50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000,
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
    final label = meters >= 1000 ? '${(meters / 1000).toStringAsFixed(0)} km' : '${meters.toStringAsFixed(0)} m';
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
      oldDelegate.state != state || oldDelegate.fontFamily != fontFamily;
}

class _Geo {
  const _Geo(this.lat, this.lon);
  final double lat;
  final double lon;
}
