import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openterritorio/data/backend_client.dart';
import 'package:openterritorio/protocol/tactical_packet.dart';

Uint8List _hex(String value) {
  final clean = value.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList(<int>[
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('tiempo de espera agotado');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Ejercita el cliente contra un backend real de mentira: handshake con token,
/// frames binarios en ambos sentidos y REST con Bearer.
void main() {
  late HttpServer server;
  late int port;
  final received = <Uint8List>[];
  WebSocket? socket;

  setUp(() async {
    received.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((HttpRequest request) async {
      switch (request.uri.path) {
        case '/ws':
          if (request.uri.queryParameters['token'] != 'secret') {
            request.response.statusCode = HttpStatus.unauthorized;
            await request.response.close();
            return;
          }
          final ws = await WebSocketTransformer.upgrade(request);
          socket = ws;
          ws.listen((dynamic data) {
            if (data is! List<int>) return;
            received.add(Uint8List.fromList(data));
            // Eco: el servidor responde con una alerta para probar la recepción.
            ws.add(
              TacticalPacket(
                packetId: _hex('0101010101010101'),
                senderId: 0,
                timestamp: 1764100000,
                type: PacketType.serverAlert,
                alert: const AlertPayload(
                  severity: 2,
                  latitudeE7: 192430000,
                  longitudeE7: -1037247000,
                  radiusM: 100,
                  title: 'eco',
                ),
              ).encode(),
            );
          }, onDone: () => socket?.close());
          break;
        case '/api/state':
          final auth = request.headers.value(HttpHeaders.authorizationHeader);
          if (auth != 'Bearer secret') {
            request.response.statusCode = HttpStatus.unauthorized;
            await request.response.close();
            return;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'peers': <Map<String, dynamic>>[
                <String, dynamic>{
                  'sender_id': 7,
                  'lat': 19.2433,
                  'lon': -103.7247,
                  'heading_deg': 10,
                  'battery_pct': 50,
                  'speed_kmh': 5.0,
                  'last_ts': 1764100000,
                },
              ],
              'events': <Map<String, dynamic>>[],
              'alerts': <Map<String, dynamic>>[],
            }),
          );
          await request.response.close();
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    });
  });

  tearDown(() async {
    await socket?.close();
    socket = null;
    await server.close(force: true);
  });

  test('conecta, envía y recibe paquetes binarios', () async {
    final client = BackendClient(
      baseUrl: 'http://127.0.0.1:$port',
      token: 'secret',
      senderId: 5,
    );
    final statuses = <ConnectionStatus>[];
    final packets = <TacticalPacket>[];
    final statusSub = client.statuses.listen(statuses.add);
    final packetSub = client.packets.listen(packets.add);

    client.connect();
    await _waitFor(() => statuses.contains(ConnectionStatus.connected));

    final sent = client.send(
      TacticalPacket(
        packetId: _hex('0202020202020202'),
        senderId: 5,
        timestamp: 1764100000,
        type: PacketType.positionUpdate,
        position: const PositionPayload(
          latitudeE7: 192433000,
          longitudeE7: -1037247000,
          headingDeg: 45,
          batteryPct: 90,
        ),
      ),
    );
    expect(sent, isTrue);

    await _waitFor(() => received.isNotEmpty);
    final decoded = TacticalPacket.decode(received.single);
    expect(decoded.senderId, 5);
    expect(decoded.type, PacketType.positionUpdate);

    await _waitFor(() => packets.isNotEmpty);
    expect(packets.single.type, PacketType.serverAlert);
    expect(packets.single.alert!.title, 'eco');

    final snapshot = await client.fetchState();
    expect((snapshot['peers'] as List<dynamic>), hasLength(1));

    client.dispose();
    await statusSub.cancel();
    await packetSub.cancel();
  });

  test('un token rechazado en REST lanza BackendException', () async {
    final client = BackendClient(
      baseUrl: 'http://127.0.0.1:$port',
      token: 'malo',
      senderId: 5,
    );
    await expectLater(client.fetchState(), throwsA(isA<BackendException>()));
    client.dispose();
  });
}
