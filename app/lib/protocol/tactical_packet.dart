import 'dart:convert';
import 'dart:typed_data';

/// Tipos del paquete tactico (seccion 5 del PDF).
enum PacketType { positionUpdate, userEvent, serverAlert, ackConfirmation }

class PositionPayload {
  const PositionPayload({
    required this.latitudeE7,
    required this.longitudeE7,
    this.altitudeM = 0,
    this.speedCms = 0,
    this.headingDeg = 0,
    this.batteryPct = 0,
  });

  final int latitudeE7;
  final int longitudeE7;
  final int altitudeM;
  final int speedCms;
  final int headingDeg;
  final int batteryPct;

  double get latitude => latitudeE7 / 1e7;
  double get longitude => longitudeE7 / 1e7;

  Uint8List encode() {
    final w = _Writer();
    w.sint32(1, latitudeE7);
    w.sint32(2, longitudeE7);
    w.int32(3, altitudeM);
    w.uint32(4, speedCms);
    w.uint32(5, headingDeg);
    w.uint32(6, batteryPct);
    return w.toBytes();
  }

  static PositionPayload decode(Uint8List bytes) {
    final r = _Reader(bytes);
    var lat = 0, lon = 0, alt = 0, speed = 0, heading = 0, battery = 0;
    while (!r.isDone) {
      final tag = r.uvarint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (wire != 0) {
        r.skip(wire);
        continue;
      }
      final v = r.uvarint();
      switch (field) {
        case 1:
          lat = _zigzag(v);
          break;
        case 2:
          lon = _zigzag(v);
          break;
        case 3:
          alt = v.toSigned(32);
          break;
        case 4:
          speed = v;
          break;
        case 5:
          heading = v;
          break;
        case 6:
          battery = v;
          break;
        default:
          break;
      }
    }
    return PositionPayload(
      latitudeE7: lat,
      longitudeE7: lon,
      altitudeM: alt,
      speedCms: speed,
      headingDeg: heading,
      batteryPct: battery,
    );
  }
}

class EventPayload {
  const EventPayload({
    this.categoryId = 0,
    required this.latitudeE7,
    required this.longitudeE7,
    this.shortNote = '',
  });

  final int categoryId;
  final int latitudeE7;
  final int longitudeE7;
  final String shortNote;

  double get latitude => latitudeE7 / 1e7;
  double get longitude => longitudeE7 / 1e7;

  Uint8List encode() {
    final w = _Writer();
    w.uint32(1, categoryId);
    w.sint32(2, latitudeE7);
    w.sint32(3, longitudeE7);
    w.string(4, shortNote);
    return w.toBytes();
  }

  static EventPayload decode(Uint8List bytes) {
    final r = _Reader(bytes);
    var category = 0, lat = 0, lon = 0;
    var note = '';
    while (!r.isDone) {
      final tag = r.uvarint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (wire == 0) {
        final v = r.uvarint();
        switch (field) {
          case 1:
            category = v;
            break;
          case 2:
            lat = _zigzag(v);
            break;
          case 3:
            lon = _zigzag(v);
            break;
        }
      } else if (wire == 2) {
        final data = r.bytes();
        if (field == 4) note = utf8.decode(data, allowMalformed: true);
      } else {
        r.skip(wire);
      }
    }
    return EventPayload(
      categoryId: category,
      latitudeE7: lat,
      longitudeE7: lon,
      shortNote: note,
    );
  }
}

class AlertPayload {
  const AlertPayload({
    this.severity = 1,
    required this.latitudeE7,
    required this.longitudeE7,
    this.radiusM = 0,
    this.title = '',
  });

  final int severity;
  final int latitudeE7;
  final int longitudeE7;
  final int radiusM;
  final String title;

  double get latitude => latitudeE7 / 1e7;
  double get longitude => longitudeE7 / 1e7;

  Uint8List encode() {
    final w = _Writer();
    w.uint32(1, severity);
    w.sint32(2, latitudeE7);
    w.sint32(3, longitudeE7);
    w.uint32(4, radiusM);
    w.string(5, title);
    return w.toBytes();
  }

  static AlertPayload decode(Uint8List bytes) {
    final r = _Reader(bytes);
    var severity = 1, lat = 0, lon = 0, radius = 0;
    var title = '';
    while (!r.isDone) {
      final tag = r.uvarint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (wire == 0) {
        final v = r.uvarint();
        switch (field) {
          case 1:
            severity = v;
            break;
          case 2:
            lat = _zigzag(v);
            break;
          case 3:
            lon = _zigzag(v);
            break;
          case 4:
            radius = v;
            break;
        }
      } else if (wire == 2) {
        final data = r.bytes();
        if (field == 5) title = utf8.decode(data, allowMalformed: true);
      } else {
        r.skip(wire);
      }
    }
    return AlertPayload(
      severity: severity,
      latitudeE7: lat,
      longitudeE7: lon,
      radiusM: radius,
      title: title,
    );
  }
}

class AckPayload {
  const AckPayload({required this.ackedPacketId});
  final Uint8List ackedPacketId;

  Uint8List encode() {
    final w = _Writer();
    w.bytes(1, ackedPacketId);
    return w.toBytes();
  }

  static AckPayload decode(Uint8List bytes) {
    final r = _Reader(bytes);
    Uint8List id = Uint8List(0);
    while (!r.isDone) {
      final tag = r.uvarint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (wire == 2) {
        final data = r.bytes();
        if (field == 1) id = data;
      } else {
        r.skip(wire);
      }
    }
    return AckPayload(ackedPacketId: id);
  }
}

class TacticalPacket {
  const TacticalPacket({
    required this.packetId,
    required this.senderId,
    required this.timestamp,
    this.hopLimit = 3,
    required this.type,
    this.position,
    this.event,
    this.alert,
    this.ack,
  });

  final Uint8List packetId;
  final int senderId;
  final int timestamp;
  final int hopLimit;
  final PacketType type;
  final PositionPayload? position;
  final EventPayload? event;
  final AlertPayload? alert;
  final AckPayload? ack;

  Uint8List encode() {
    final w = _Writer();
    w.bytes(1, packetId);
    w.uint32(2, senderId);
    w.uint64(3, timestamp);
    w.uint32(4, hopLimit);
    w.uint32(5, type.index);
    switch (type) {
      case PacketType.positionUpdate:
        if (position != null) w.message(6, position!.encode());
        break;
      case PacketType.userEvent:
        if (event != null) w.message(7, event!.encode());
        break;
      case PacketType.serverAlert:
        if (alert != null) w.message(8, alert!.encode());
        break;
      case PacketType.ackConfirmation:
        if (ack != null) w.message(9, ack!.encode());
        break;
    }
    return w.toBytes();
  }

  static TacticalPacket decode(Uint8List bytes) {
    final r = _Reader(bytes);
    Uint8List packetId = Uint8List(0);
    var senderId = 0, timestamp = 0, hopLimit = 0, type = 0;
    PositionPayload? position;
    EventPayload? event;
    AlertPayload? alert;
    AckPayload? ack;

    while (!r.isDone) {
      final tag = r.uvarint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (wire == 0) {
        final v = r.uvarint();
        switch (field) {
          case 2:
            senderId = v;
            break;
          case 3:
            timestamp = v;
            break;
          case 4:
            hopLimit = v;
            break;
          case 5:
            type = v;
            break;
        }
      } else if (wire == 2) {
        final data = r.bytes();
        switch (field) {
          case 1:
            packetId = data;
            break;
          case 6:
            position = PositionPayload.decode(data);
            break;
          case 7:
            event = EventPayload.decode(data);
            break;
          case 8:
            alert = AlertPayload.decode(data);
            break;
          case 9:
            ack = AckPayload.decode(data);
            break;
        }
      } else {
        r.skip(wire);
      }
    }

    return TacticalPacket(
      packetId: packetId,
      senderId: senderId,
      timestamp: timestamp,
      hopLimit: hopLimit,
      type: PacketType.values[type.clamp(0, 3)],
      position: position,
      event: event,
      alert: alert,
      ack: ack,
    );
  }

  String get packetIdHex =>
      packetId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

int _zigzag(int v) => (v >> 1) ^ -(v & 1);

class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void _varint(BigInt value) {
    var v = value;
    final mask = BigInt.from(0x7f);
    final more = BigInt.from(0x80);
    while (v > mask) {
      _builder.addByte(((v & mask) | more).toInt());
      v = v >> 7;
    }
    _builder.addByte(v.toInt());
  }

  void _tag(int field, int wire) => _varint(BigInt.from((field << 3) | wire));

  void uint32(int field, int value) {
    if (value <= 0) return;
    _tag(field, 0);
    _varint(BigInt.from(value));
  }

  void uint64(int field, int value) {
    if (value <= 0) return;
    _tag(field, 0);
    _varint(BigInt.from(value));
  }

  void int32(int field, int value) {
    if (value == 0) return;
    _tag(field, 0);
    _varint(value < 0 ? BigInt.from(value).toUnsigned(64) : BigInt.from(value));
  }

  void sint32(int field, int value) {
    if (value == 0) return;
    final zz = (value << 1) ^ (value >> 31);
    _tag(field, 0);
    _varint(BigInt.from(zz));
  }

  void bytes(int field, Uint8List value) {
    if (value.isEmpty) return;
    _tag(field, 2);
    _varint(BigInt.from(value.length));
    _builder.add(value);
  }

  void string(int field, String value) {
    if (value.isEmpty) return;
    final data = Uint8List.fromList(utf8.encode(value));
    bytes(field, data);
  }

  void message(int field, Uint8List value) {
    _tag(field, 2);
    _varint(BigInt.from(value.length));
    _builder.add(value);
  }

  Uint8List toBytes() => _builder.toBytes();
}

class _Reader {
  _Reader(this.data);
  final Uint8List data;
  int pos = 0;

  bool get isDone => pos >= data.length;

  int uvarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= data.length) throw const FormatException('varint truncado');
      final byte = data[pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('varint demasiado largo');
    }
  }

  Uint8List bytes() {
    final length = uvarint();
    final end = pos + length;
    if (end > data.length) throw const FormatException('bytes truncados');
    final out = Uint8List.fromList(data.sublist(pos, end));
    pos = end;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        uvarint();
        break;
      case 1:
        pos += 8;
        break;
      case 2:
        pos += uvarint();
        break;
      case 5:
        pos += 4;
        break;
      default:
        throw FormatException('wire type desconocido: $wire');
    }
    if (pos > data.length) throw const FormatException('campo truncado');
  }
}
