import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:openterritorio/data/app_state.dart';
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
  return ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * (1 << z))
      .floor();
}

Future<ui.Image> _decodeFile(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  return (await codec.getNextFrame()).image;
}

/// Carga en la caché las teselas reales alrededor de un punto.
Future<int> _seedTiles(double lat, double lon, {int radius = 3}) async {
  var seeded = 0;
  for (final z in <int>[13, 14, 15, 16]) {
    final xc = _tileX(lon, z);
    final yc = _tileY(lat, z);
    for (var dx = -radius; dx <= radius; dx++) {
      for (var dy = -radius; dy <= radius; dy++) {
        final file = File('$_tileDir/colima_${z}_${xc + dx}_${yc + dy}.jpg');
        if (!file.existsSync()) continue;
        OfflineTiles.seedForTest(z, xc + dx, yc + dy, await _decodeFile(file.path));
        seeded++;
      }
    }
  }
  return seeded;
}

Future<(ui.Image, List<int>)> _paintBoard(AppState state, Size size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  BoardPainter(state, fontFamily: _previewFont).paint(canvas, size);
  final image = await (recorder.endRecording())
      .toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (image, data!.buffer.asUint8List());
}

double _nonBackgroundRatio(List<int> rgba) {
  var painted = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    final delta = (rgba[i] - 0x0B).abs() +
        (rgba[i + 1] - 0x0F).abs() +
        (rgba[i + 2] - 0x14).abs();
    if (delta > 12) painted++;
  }
  return painted / (rgba.length / 4);
}

Future<void> _save(ui.Image image, String name) async {
  Directory('build/preview').createSync(recursive: true);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('build/preview/$name').writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadPreviewFont);

  test('el mapa offline del estado de Colima se pinta (no un rectángulo negro)', () async {
    const size = Size(400, 700);
    final seeded = await _seedTiles(19.2433, -103.7247);
    expect(seeded, greaterThan(4), reason: 'faltan teselas en $_tileDir');

    final state = AppState()
      ..selfId = 2001
      ..setOwn(19.2433, -103.7247, heading: 90, speedKmh: 12);

    final (image, rgba) = await _paintBoard(state, size);
    final ratio = _nonBackgroundRatio(rgba);
    expect(ratio, greaterThan(0.5), reason: 'el mapa debe cubrir el lienzo (fue $ratio)');
    await _save(image, 'board_mapa.png');
  });

  test('también pinta la costa (Manzanillo) con las teselas del estado', () async {
    const size = Size(400, 700);
    await _seedTiles(19.1138, -104.3267, radius: 2);

    final state = AppState()
      ..selfId = 2002
      ..setOwn(19.1138, -104.3267, heading: 0, speedKmh: 0);

    final (image, rgba) = await _paintBoard(state, size);
    expect(_nonBackgroundRatio(rgba), greaterThan(0.5));
    await _save(image, 'board_manzanillo.png');
  });

  test('dibuja pares, eventos y alertas encima del mapa', () async {
    const size = Size(400, 700);
    await _seedTiles(19.2433, -103.7247);

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

    final (image, rgba) = await _paintBoard(state, size);
    expect(_nonBackgroundRatio(rgba), greaterThan(0.5));
    await _save(image, 'board_operativo.png');
  });
}
