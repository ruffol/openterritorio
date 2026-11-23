// Comprobación de extremo a extremo del cliente Flutter contra un backend real.
//
//   dart run tool/wire_check.dart http://127.0.0.1:3000 TOKEN
//
// 1. Abre el WebSocket con token y envía un POSITION_UPDATE.
// 2. Comprueba que el servidor lo persiste (/api/state).
// 3. Publica una alerta por REST y espera a recibirla por WebSocket.
// 4. Responde con ACK_CONFIRMATION y verifica que el servidor la registra.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:openterritorio/data/backend_client.dart';
import 'package:openterritorio/data/ota_service.dart';
import 'package:openterritorio/protocol/tactical_packet.dart';

const int _senderId = 424242;

Uint8List _packetId() => Uint8List.fromList(
  List<int>.generate(
    8,
    (i) => (i * 37 + 11 + DateTime.now().microsecond) & 0xff,
  ),
);

Map<String, String> _auth(String token) => <String, String>{
  'Authorization': 'Bearer $token',
};

Future<void> main(List<String> args) async {
  final baseUrl = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3000';
  final token = args.length > 1
      ? args[1]
      : (Platform.environment['TOKEN'] ?? '');
  if (token.isEmpty) {
    stderr.writeln('uso: dart run tool/wire_check.dart <url> <token>');
    exitCode = 2;
    return;
  }

  final client = BackendClient(
    baseUrl: baseUrl,
    token: token,
    senderId: _senderId,
  );
  final connected = Completer<void>();
  final inbox = <TacticalPacket>[];
  final statusSub = client.statuses.listen((status) {
    if (status == ConnectionStatus.connected && !connected.isCompleted) {
      connected.complete();
    }
  });
  final packetSub = client.packets.listen(inbox.add);

  try {
    client.connect();
    await connected.future.timeout(const Duration(seconds: 10));
    stdout.writeln('WS conectado a $baseUrl');

    final position = TacticalPacket(
      packetId: _packetId(),
      senderId: _senderId,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      type: PacketType.positionUpdate,
      position: const PositionPayload(
        latitudeE7: 192433000,
        longitudeE7: -1037247000,
        altitudeM: 520,
        speedCms: 1200,
        headingDeg: 90,
        batteryPct: 77,
      ),
    );
    if (!client.send(position)) {
      throw StateError('el paquete no salió por el socket');
    }
    stdout.writeln(
      'POSITION_UPDATE enviado (${position.encode().length} bytes)',
    );

    await _waitUntil(() async {
      final state = await client.fetchState();
      final peers = (state['peers'] as List<dynamic>? ?? <dynamic>[])
          .cast<Map<String, dynamic>>();
      return peers.any((peer) => peer['sender_id'] == _senderId);
    }, 'el par $_senderId apareció en /api/state');
    stdout.writeln('OK: el backend persistió el par $_senderId');

    final title = 'wire_check ${DateTime.now().millisecondsSinceEpoch}';
    final response = await http.post(
      Uri.parse('$baseUrl/api/alerts'),
      headers: <String, String>{
        ..._auth(token),
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'severity': 2,
        'lat': 19.2433,
        'lon': -103.7247,
        'radius_m': 150,
        'title': title,
      }),
    );
    if (response.statusCode != 201) {
      throw StateError('POST /api/alerts → HTTP ${response.statusCode}');
    }
    final alertHex =
        (jsonDecode(response.body) as Map<String, dynamic>)['packet_id']
            as String;

    TacticalPacket? received;
    await _waitUntil(() async {
      received = inbox.cast<TacticalPacket?>().firstWhere(
        (packet) =>
            packet?.type == PacketType.serverAlert &&
            packet?.alert?.title == title,
        orElse: () => null,
      );
      return received != null;
    }, 'la alerta llegó por WebSocket');
    stdout.writeln('OK: alerta recibida por WS ($alertHex)');

    if (!client.send(
      TacticalPacket(
        packetId: _packetId(),
        senderId: _senderId,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        type: PacketType.ackConfirmation,
        ack: AckPayload(ackedPacketId: received!.packetId),
      ),
    )) {
      throw StateError('el ACK no salió por el socket');
    }

    await _waitUntil(() async {
      final ackResponse = await http.get(
        Uri.parse('$baseUrl/api/alerts/$alertHex/acks'),
        headers: _auth(token),
      );
      if (ackResponse.statusCode != 200) return false;
      final acks =
          (jsonDecode(ackResponse.body) as Map<String, dynamic>)['acks']
              as List<dynamic>? ??
          <dynamic>[];
      return acks.any(
        (ack) => (ack as Map<String, dynamic>)['acked_by'] == _senderId,
      );
    }, 'el servidor registró el ACK de $_senderId');
    stdout.writeln('OK: ACK registrado para la alerta $alertHex');

    // OTA: si hay APK publicado, descárgalo y verifica el sha256.
    final cache = await Directory.systemTemp.createTemp('openterritorio-apk-');
    final ota = OtaService(
      client: client,
      cacheDir: cache,
      installer: (path) async => 'skip',
    );
    final update = await ota.check();
    if (update == null) {
      stdout.writeln('OTA: sin APK publicado (se omite).');
    } else {
      final file = await ota.download(update);
      stdout.writeln(
        'OK: APK v${update.version} (${update.versionCode}) descargado, '
        '${file.lengthSync()} bytes, sha256 verificado',
      );
    }
    await cache.delete(recursive: true);
  } on Object catch (error) {
    stderr.writeln('FALLO: $error');
    exitCode = 1;
  } finally {
    client.dispose();
    await statusSub.cancel();
    await packetSub.cancel();
  }
}

Future<void> _waitUntil(
  Future<bool> Function() check,
  String description, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('tiempo agotado esperando: $description');
}
