import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:openterritorio/data/app_state.dart';
import 'package:openterritorio/data/landmarks.dart';
import 'package:openterritorio/ui/board.dart';

/// Fuente real para la previsualización: en `flutter test` el motor usa una
/// fuente de prueba que dibuja cada glifo como un rectángulo sólido.
const String _previewFont = 'BoardPreview';

const String _tileDir = 'assets/tiles';

Future<void> _loadPreviewFont() async {
  const candidates = <String>[
    r'C:\Windows\Fonts\segoeui.ttf',
    r'C:\Windows\Fonts\arial.ttf',
    '/System/Library/Fonts/Supplemental/Arial.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader(_previewFont)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
}

int _tileX(double lon, int z) => ((lon + 180) / 360 * (1 << z)).floor();
int _tileY(double lat, int z) {
  final rad = lat * math.pi / 180;
  return ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * (1 << z)).floor();
}

Future<ui.Image> _decodeFile(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  return (await codec.getNextFrame()).image;
}

/// Carga en la caché las teselas reales alrededor de un punto, por capa.
Future<int> _seedTiles(MapLayerId layer, double lat, double lon, {int radius = 3}) async {
  var seeded = 0;
  for (final z in <int>[13, 14, 15, 16]) {
    final xc = _tileX(lon, z);
    final yc = _tileY(lat, z);
    for (var dx = -radius; dx <= radius; dx++) {
      for (var dy = -radius; dy <= radius; dy++) {
        final file = File('$_tileDir/${layer.name}/colima_${z}_${xc + dx}_${yc + dy}.jpg');
        if (!file.existsSync()) continue;
        OfflineTiles.seedForTest(layer, z, xc + dx, yc + dy, await _decodeFile(file.path));
        seeded++;
      }
    }
  }
  return seeded;
}

Future<(ui.Image, List<int>)> _paintBoard(AppState state, MapViewport viewport, Size size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  BoardPainter(state, viewport, fontFamily: _previewFont).paint(canvas, size);
  final image = await (recorder.endRecording()).toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (image, data!.buffer.asUint8List());
}

double _nonBackgroundRatio(List<int> rgba) {
  var painted = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    final delta = (rgba[i] - 0x0B).abs() + (rgba[i + 1] - 0x0F).abs() + (rgba[i + 2] - 0x14).abs();
    if (delta > 12) painted++;
  }
  return painted / (rgba.length / 4);
}

Future<void> _save(ui.Image image, String name) async {
  Directory('build/preview').createSync(recursive: true);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('build/preview/$name').writeAsBytesSync(png!.buffer.asUint8List());
}

int? _maxZoomNear(MapLayerId layer, double lat, double lon) {
  for (var z = 16; z >= OfflineTiles.minZoom; z--) {
    final file = File('$_tileDir/${layer.name}/colima_${z}_${_tileX(lon, z)}_${_tileY(lat, z)}.jpg');
    if (file.existsSync()) return z;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _loadPreviewFont();
    // En pruebas se siembran varios niveles: la caché debe aguantarlos todos.
    OfflineTiles.capacity = 4000;
  });

  for (final layer in MapLayerId.values) {
    test('la capa ${layer.name} pinta el mapa', () async {
      const size = Size(400, 700);
      final maxZoom = _maxZoomNear(layer, 19.2433, -103.7247);
      if (maxZoom == null) {
        markTestSkipped('teselas de ${layer.name} todavía no descargadas en $_tileDir');
        return;
      }
      final seeded = await _seedTiles(layer, 19.2433, -103.7247, radius: 5);
      expect(seeded, greaterThan(4));

      final viewport = MapViewport(zoom: maxZoom.toDouble(), layer: layer);
      final state = AppState()
        ..selfId = 2001
        ..setOwn(19.2433, -103.7247, heading: 90, speedKmh: 12);

      final (image, rgba) = await _paintBoard(state, viewport, size);
      final ratio = _nonBackgroundRatio(rgba);
      expect(ratio, greaterThan(0.5), reason: 'el mapa debe cubrir el lienzo (fue $ratio)');
      await _save(image, 'board_${layer.name}.png');
    });
  }

  test('el zoom cambia el nivel de tesela (z13 país vs z16 calles)', () async {
    const size = Size(400, 700);
    await _seedTiles(MapLayerId.oscuro, 19.2433, -103.7247, radius: 5);

    final zoomedOut = MapViewport(zoom: 13);
    final zoomedIn = MapViewport(zoom: 16);
    final state = AppState()..selfId = 2001;

    final (imgOut, rgbaOut) = await _paintBoard(state, zoomedOut, size);
    final (imgIn, rgbaIn) = await _paintBoard(state, zoomedIn, size);
    expect(_nonBackgroundRatio(rgbaOut), greaterThan(0.5));
    expect(_nonBackgroundRatio(rgbaIn), greaterThan(0.5));
    await _save(imgOut, 'board_zoom13.png');
    await _save(imgIn, 'board_zoom16.png');
  });

  test('centrar en la posición propia deja el marcador en el centro', () async {
    const size = Size(400, 700);
    await _seedTiles(MapLayerId.oscuro, 19.1138, -104.3267, radius: 3);

    final viewport = MapViewport(layer: MapLayerId.oscuro)
      ..goTo(19.1138, -104.3267, zoom: 16);
    final center = viewport.project(19.1138, -104.3267, size);
    expect(center.dx, closeTo(size.width / 2, 0.5));
    expect(center.dy, closeTo(size.height / 2, 0.5));

    final state = AppState()
      ..selfId = 2002
      ..setOwn(19.1138, -104.3267);
    final (image, rgba) = await _paintBoard(state, viewport, size);
    expect(_nonBackgroundRatio(rgba), greaterThan(0.5));
    await _save(image, 'board_centrado.png');
  });

  test('el punto de la universidad lleva anillo verde de 50 m y emoji', () async {
    const size = Size(400, 700);
    const lat = 19.31497222;
    const lon = -103.75877778;
    final seeded = await _seedTiles(MapLayerId.oscuro, lat, lon, radius: 3);
    expect(seeded, greaterThan(4));

    final viewport = MapViewport(centerLat: lat, centerLon: lon, zoom: 16);
    final state = AppState()..selfId = 2001;
    final (image, rgba) = await _paintBoard(state, viewport, size);
    await _save(image, 'board_universidad.png');

    // El anillo de 50 m debe estar donde toca: 50 m a la derecha del centro.
    final radiusPx = 50 / viewport.metersPerPixel;
    expect(radiusPx, greaterThan(4));
    final cx = size.width / 2;
    final cy = size.height / 2;
    int pixelAt(double dx) {
      final x = (cx + dx).round().clamp(0, size.width.toInt() - 1);
      final y = cy.round().clamp(0, size.height.toInt() - 1);
      final i = (y * size.width.toInt() + x) * 4;
      return (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
    }

    // Busca un píxel verde (G dominante) sobre el borde del anillo.
    var foundGreen = false;
    for (var dx = radiusPx - 2; dx <= radiusPx + 2; dx++) {
      for (final dy in <double>[-1, 0, 1]) {
        final x = (cx + dx).round().clamp(0, size.width.toInt() - 1);
        final y = (cy + dy).round().clamp(0, size.height.toInt() - 1);
        final i = (y * size.width.toInt() + x) * 4;
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        if (g > 120 && g > r + 30 && g > b + 30) foundGreen = true;
      }
    }
    expect(foundGreen, isTrue, reason: 'no se encontró el anillo verde de 50 m');
    expect(pixelAt(0), isNot(0x0B0F14));
  });

  test('el punto de SANGRE lleva emoji y anillo rojo de 500 m', () async {
    expect(kLandmarks.length, greaterThanOrEqualTo(2));
    final sangre = kLandmarks.firstWhere((l) => l.name == 'SANGRE');
    expect(sangre.radiusM, 500);
    expect(sangre.emoji, '🩸');
    expect(sangre.lat, closeTo(19.25511111, 1e-8));
    expect(sangre.lon, closeTo(-103.72936111, 1e-8));

    const size = Size(400, 700);
    final seeded = await _seedTiles(MapLayerId.oscuro, sangre.lat, sangre.lon, radius: 3);
    expect(seeded, greaterThan(4));

    final viewport = MapViewport(
      centerLat: sangre.lat,
      centerLon: sangre.lon,
      zoom: 15,
    );
    final state = AppState()..selfId = 2001;
    final (image, rgba) = await _paintBoard(state, viewport, size);
    await _save(image, 'board_sangre.png');

    final radiusPx = 500 / viewport.metersPerPixel;
    expect(radiusPx, greaterThan(40));
    expect(sangre.colors.length, 2, reason: 'anillo bicolor (rojo y azul)');

    // Recorre la circunferencia: las franjas alternan rojo y azul.
    var foundRed = false;
    var foundBlue = false;
    final cx = size.width / 2;
    final cy = size.height / 2;
    for (var step = 0; step < 32; step++) {
      final angle = 2 * math.pi * step / 32;
      final x = (cx + math.cos(angle) * radiusPx).round().clamp(0, size.width.toInt() - 1);
      final y = (cy + math.sin(angle) * radiusPx).round().clamp(0, size.height.toInt() - 1);
      final i = (y * size.width.toInt() + x) * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      if (r > 150 && r > g + 50 && r > b + 50) foundRed = true;
      if (b > 170 && b > r + 70 && b > g + 20) foundBlue = true;
    }
    expect(foundRed, isTrue, reason: 'falta la franja roja');
    expect(foundBlue, isTrue, reason: 'falta la franja azul');
  });

  test('el punto MARRÓN lleva emoji y anillo café de 100 m', () async {
    final marron = kLandmarks.firstWhere((l) => l.name == 'MARRÓN');
    expect(marron.radiusM, 100);
    expect(marron.emoji, '🟤');
    expect(marron.lat, closeTo(19.26688889, 1e-8));
    expect(marron.lon, closeTo(-103.72741667, 1e-8));
    expect(marron.colors.first.toARGB32(), 0xFFA0522D);

    const size = Size(400, 700);
    final seeded = await _seedTiles(MapLayerId.oscuro, marron.lat, marron.lon, radius: 3);
    expect(seeded, greaterThan(4));

    final viewport = MapViewport(
      centerLat: marron.lat,
      centerLon: marron.lon,
      zoom: 16,
    );
    final state = AppState()..selfId = 2001;
    final (image, rgba) = await _paintBoard(state, viewport, size);
    await _save(image, 'board_marron.png');

    final radiusPx = 100 / viewport.metersPerPixel;
    expect(radiusPx, greaterThan(20));
    var foundBrown = false;
    final cx = size.width / 2;
    final cy = size.height / 2;
    for (var step = 0; step < 32; step++) {
      final angle = 2 * math.pi * step / 32;
      final x = (cx + math.cos(angle) * radiusPx).round().clamp(0, size.width.toInt() - 1);
      final y = (cy + math.sin(angle) * radiusPx).round().clamp(0, size.height.toInt() - 1);
      final i = (y * size.width.toInt() + x) * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      if (r > 110 && r > g + 35 && g > b + 15 && b < 110) foundBrown = true;
    }
    expect(foundBrown, isTrue, reason: 'no se encontró el anillo café de 100 m');
  });

  test('dibuja pares, eventos y alertas encima del mapa', () async {
    const size = Size(400, 700);
    await _seedTiles(MapLayerId.oscuro, 19.2433, -103.7247);

    final viewport = MapViewport(zoom: 15);
    final state = AppState()..selfId = 2001;
    state.applySnapshot(<String, dynamic>{
      'peers': [
        {'sender_id': 3001, 'lat': 19.2470, 'lon': -103.7210, 'heading_deg': 45, 'battery_pct': 73, 'speed_kmh': 8.2},
        {'sender_id': 3002, 'lat': 19.2400, 'lon': -103.7290, 'heading_deg': 200, 'battery_pct': 51, 'speed_kmh': 0},
      ],
      'events': [
        {'id': 1, 'packet_id': 'aa11bb22cc33dd44', 'lat': 19.2455, 'lon': -103.7180, 'category_id': 1, 'short_note': 'Punto de reunion'},
      ],
      'alerts': [
        {'id': 1, 'packet_id': 'ee55ff66aa77bb88', 'lat': 19.2485, 'lon': -103.7270, 'severity': 3, 'radius_m': 120, 'title': 'Derrumbe'},
      ],
    });

    final (image, rgba) = await _paintBoard(state, viewport, size);
    expect(_nonBackgroundRatio(rgba), greaterThan(0.5));
    await _save(image, 'board_operativo.png');
  });
}
