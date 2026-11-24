import 'dart:io';
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

/// Renderiza el tablero a un PNG real para comprobar que el mapa offline
/// se pinta (no basta con que el analizador esté contento).
Future<ui.Image> _decode(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<(ui.Image, List<int>)> _paintBoard(AppState state, Size size) async {
  final near = MapLayer(
    asset: 'assets/map/colima_z15.jpg',
    west: OfflineMap.nearWest,
    east: OfflineMap.nearEast,
    north: OfflineMap.nearNorth,
    south: OfflineMap.nearSouth,
    image: await _decode(File('assets/map/colima_z15.jpg').path),
  );
  final far = MapLayer(
    asset: 'assets/map/colima_z13.jpg',
    west: OfflineMap.farWest,
    east: OfflineMap.farEast,
    north: OfflineMap.farNorth,
    south: OfflineMap.farSouth,
    image: await _decode(File('assets/map/colima_z13.jpg').path),
  );

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  BoardPainter(state, near: near, far: far, fontFamily: _previewFont)
      .paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (image, data!.buffer.asUint8List());
}

double _nonBackgroundRatio(List<int> rgba, Size size) {
  var painted = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    final dr = (rgba[i] - 0x0B).abs();
    final dg = (rgba[i + 1] - 0x0F).abs();
    final db = (rgba[i + 2] - 0x14).abs();
    if (dr + dg + db > 12) painted++;
  }
  return painted / (size.width * size.height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadPreviewFont);

  test('el tablero pinta el mapa offline, no un rectángulo negro', () async {
    const size = Size(400, 700);
    final state = AppState()
      ..selfId = 2001
      ..setOwn(19.2433, -103.7247, heading: 90, speedKmh: 12);

    final (image, rgba) = await _paintBoard(state, size);
    final ratio = _nonBackgroundRatio(rgba, size);
    expect(
      ratio,
      greaterThan(0.5),
      reason: 'el mapa debe cubrir la mayor parte del lienzo (fue $ratio)',
    );

    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/preview').createSync(recursive: true);
    File('build/preview/board_mapa.png').writeAsBytesSync(
      png!.buffer.asUint8List(),
    );
  });

  test('el tablero dibuja pares, eventos y alertas sobre el mapa', () async {
    const size = Size(400, 700);
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
    expect(_nonBackgroundRatio(rgba, size), greaterThan(0.5));

    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/preview').createSync(recursive: true);
    File('build/preview/board_operativo.png').writeAsBytesSync(
      png!.buffer.asUint8List(),
    );
  });
}
