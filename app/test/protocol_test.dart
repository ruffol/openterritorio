import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openterritorio/data/app_state.dart';
import 'package:openterritorio/protocol/tactical_packet.dart';

Uint8List _hex(String value) {
  final clean = value.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList(<int>[
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String _toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// Vectores generados con protobufjs 7 / `server/src/proto.js` a partir de
// proto/tactical_packet.proto. Si el encoder Dart se desvía, el backend
// rechazaría el paquete, así que se fija el byte exacto.
const String _positionHex =
    '0a08010203040506070810922118a08f98c90620033217'
    '08d0adc2b70110af8899dd0718800420dc0b288f023057';
const String _eventHex =
    '0a08a1a2a3a4a5a6a7a81007189b9098c90620032801'
    '3a1b080410e0fec1b701189fb799dd07220b7075656e746520726f746f';
const String _alertHex =
    '0a08b1b2b3b4b5b6b7b818e89298c90620032802'
    '421b080310809bc3b70118dffe96dd0720fa012a0864657272756d6265';
const String _ackHex =
    '0a08c1c2c3c4c5c6c7c8100918b59598c90620032803'
    '4a0a0a080102030405060708';

void main() {
  group('protocolo binario compatible con protobufjs', () {
    test('POSITION_UPDATE se codifica byte a byte', () {
      final packet = TacticalPacket(
        packetId: _hex('0102030405060708'),
        senderId: 4242,
        timestamp: 1764100000,
        hopLimit: 3,
        type: PacketType.positionUpdate,
        position: const PositionPayload(
          latitudeE7: 192433000,
          longitudeE7: -1037247000,
          altitudeM: 512,
          speedCms: 1500,
          headingDeg: 271,
          batteryPct: 87,
        ),
      );
      expect(_toHex(packet.encode()), _positionHex);
    });

    test('USER_EVENT se codifica byte a byte', () {
      final packet = TacticalPacket(
        packetId: _hex('a1a2a3a4a5a6a7a8'),
        senderId: 7,
        timestamp: 1764100123,
        hopLimit: 3,
        type: PacketType.userEvent,
        event: const EventPayload(
          categoryId: 4,
          latitudeE7: 192430000,
          longitudeE7: -1037250000,
          shortNote: 'puente roto',
        ),
      );
      expect(_toHex(packet.encode()), _eventHex);
    });

    test('SERVER_ALERT se codifica byte a byte', () {
      final packet = TacticalPacket(
        packetId: _hex('b1b2b3b4b5b6b7b8'),
        senderId: 0,
        timestamp: 1764100456,
        hopLimit: 3,
        type: PacketType.serverAlert,
        alert: const AlertPayload(
          severity: 3,
          latitudeE7: 192440000,
          longitudeE7: -1037230000,
          radiusM: 250,
          title: 'derrumbe',
        ),
      );
      expect(_toHex(packet.encode()), _alertHex);
    });

    test('ACK_CONFIRMATION se codifica byte a byte', () {
      final packet = TacticalPacket(
        packetId: _hex('c1c2c3c4c5c6c7c8'),
        senderId: 9,
        timestamp: 1764100789,
        hopLimit: 3,
        type: PacketType.ackConfirmation,
        ack: AckPayload(ackedPacketId: _hex('0102030405060708')),
      );
      expect(_toHex(packet.encode()), _ackHex);
    });

    test('decodifica los vectores del servidor', () {
      final position = TacticalPacket.decode(_hex(_positionHex));
      expect(position.type, PacketType.positionUpdate);
      expect(position.senderId, 4242);
      expect(position.timestamp, 1764100000);
      expect(position.hopLimit, 3);
      expect(position.packetIdHex, '0102030405060708');
      expect(position.position!.latitudeE7, 192433000);
      expect(position.position!.longitudeE7, -1037247000);
      expect(position.position!.altitudeM, 512);
      expect(position.position!.speedCms, 1500);
      expect(position.position!.headingDeg, 271);
      expect(position.position!.batteryPct, 87);

      final event = TacticalPacket.decode(_hex(_eventHex));
      expect(event.type, PacketType.userEvent);
      expect(event.event!.shortNote, 'puente roto');
      expect(event.event!.latitude, closeTo(19.243, 1e-9));

      final alert = TacticalPacket.decode(_hex(_alertHex));
      expect(alert.type, PacketType.serverAlert);
      expect(alert.alert!.severity, 3);
      expect(alert.alert!.radiusM, 250);
      expect(alert.alert!.title, 'derrumbe');

      final ack = TacticalPacket.decode(_hex(_ackHex));
      expect(ack.type, PacketType.ackConfirmation);
      expect(_toHex(ack.ack!.ackedPacketId), '0102030405060708');
    });

    test('coordenadas negativas y cero sobreviven al round-trip', () {
      final packet = TacticalPacket(
        packetId: _hex('ffffffffffffffff'),
        senderId: 1,
        timestamp: 1764100001,
        type: PacketType.positionUpdate,
        position: const PositionPayload(
          latitudeE7: -192433000,
          longitudeE7: -1037247000,
          altitudeM: -12,
          speedCms: 0,
          headingDeg: 0,
          batteryPct: 0,
        ),
      );
      final decoded = TacticalPacket.decode(packet.encode());
      expect(decoded.position!.latitudeE7, -192433000);
      expect(decoded.position!.longitudeE7, -1037247000);
      expect(decoded.position!.altitudeM, -12);
    });
  });

  group('AppState', () {
    test('aplica paquetes y deduplica por packet_id', () {
      final state = AppState();
      state.selfId = 99;

      final position = TacticalPacket(
        packetId: _hex('0000000000000001'),
        senderId: 7,
        timestamp: 1764100000,
        type: PacketType.positionUpdate,
        position: const PositionPayload(
          latitudeE7: 192433000,
          longitudeE7: -1037247000,
          headingDeg: 90,
          speedCms: 1000,
          batteryPct: 55,
        ),
      );
      state.applyPacket(position);
      expect(state.peers[7]!.batteryPct, 55);
      expect(state.peers[7]!.speedKmh, closeTo(36, 1e-6));

      final event = TacticalPacket(
        packetId: _hex('0000000000000002'),
        senderId: 7,
        timestamp: 1764100001,
        type: PacketType.userEvent,
        event: const EventPayload(
          latitudeE7: 192430000,
          longitudeE7: -1037250000,
          shortNote: 'refugio',
        ),
      );
      state.applyPacket(event);
      state.applyPacket(event);
      expect(state.events, hasLength(1));
      expect(state.events.first.note, 'refugio');

      final alert = TacticalPacket(
        packetId: _hex('0000000000000003'),
        senderId: 0,
        timestamp: 1764100002,
        type: PacketType.serverAlert,
        alert: const AlertPayload(
          severity: 3,
          latitudeE7: 192440000,
          longitudeE7: -1037230000,
          radiusM: 250,
          title: 'derrumbe',
        ),
      );
      state.applyPacket(alert);
      expect(state.alerts.single.severity, 3);
      expect(state.alerts.single.radiusM, 250);

      // El eco de la propia posición no se pinta como par.
      state.applyPacket(
        TacticalPacket(
          packetId: _hex('0000000000000004'),
          senderId: 99,
          timestamp: 1764100003,
          type: PacketType.positionUpdate,
          position: const PositionPayload(
            latitudeE7: 192433000,
            longitudeE7: -1037247000,
          ),
        ),
      );
      expect(state.peers.containsKey(99), isFalse);
    });

    test('carga la foto de /api/state', () {
      final state = AppState()..selfId = 42;
      state.applySnapshot(<String, dynamic>{
        'ok': true,
        'peers': <Map<String, dynamic>>[
          <String, dynamic>{
            'sender_id': 7,
            'lat': 19.2433,
            'lon': -103.7247,
            'heading_deg': 180,
            'battery_pct': 66,
            'speed_kmh': 12.5,
            'last_ts': 1764100000,
          },
          <String, dynamic>{
            'sender_id': 42,
            'lat': 19.24,
            'lon': -103.72,
            'heading_deg': 0,
            'battery_pct': 100,
            'speed_kmh': 0,
            'last_ts': 1764100000,
          },
        ],
        'events': <Map<String, dynamic>>[
          <String, dynamic>{
            'packet_id': 'aabbccddeeff0011',
            'category_id': 2,
            'lat': 19.243,
            'lon': -103.724,
            'short_note': 'control',
            'ts': 1764100000,
          },
        ],
        'alerts': <Map<String, dynamic>>[
          <String, dynamic>{
            'packet_id': '1122334455667788',
            'severity': 2,
            'lat': 19.244,
            'lon': -103.723,
            'radius_m': 120,
            'title': 'precaución',
            'ts': 1764100000,
          },
        ],
      });

      expect(state.peers.keys, <int>[7]);
      expect(state.peers[7]!.speedKmh, 12.5);
      expect(state.events.single.categoryId, 2);
      expect(state.alerts.single.title, 'precaución');
      expect(state.lastError, isNull);
    });
  });
}
