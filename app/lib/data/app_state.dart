import 'package:flutter/foundation.dart';

import '../protocol/tactical_packet.dart';

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

/// Estado del enlace con el backend, tal como lo muestra la barra de estado.
enum LinkState {
  noToken('sin token'),
  connecting('conectando'),
  connected('conectado'),
  disconnected('desconectado');

  const LinkState(this.label);

  /// Texto para el operador.
  final String label;
}

/// Última posición conocida de otro dispositivo.
class Peer {
  const Peer({
    required this.senderId,
    required this.lat,
    required this.lon,
    this.headingDeg = 0,
    this.batteryPct = 0,
    this.speedKmh = 0,
    this.lastTs = 0,
  });

  final int senderId;
  final double lat;
  final double lon;
  final int headingDeg;
  final int batteryPct;
  final double speedKmh;
  final int lastTs;

  factory Peer.fromJson(Map<String, dynamic> json) {
    return Peer(
      senderId: _asInt(json['sender_id']),
      lat: _asDouble(json['lat']),
      lon: _asDouble(json['lon']),
      headingDeg: _asInt(json['heading_deg']).clamp(0, 359),
      batteryPct: _asInt(json['battery_pct']).clamp(0, 100),
      speedKmh: _asDouble(json['speed_kmh']),
      lastTs: _asInt(json['last_ts']),
    );
  }
}

/// Evento georreferenciado creado por un par o por el operador.
class EventMarker {
  const EventMarker({
    required this.id,
    required this.lat,
    required this.lon,
    this.categoryId = 0,
    this.note = '',
    this.ts = 0,
  });

  final String id;
  final double lat;
  final double lon;
  final int categoryId;
  final String note;
  final int ts;

  factory EventMarker.fromPacket(TacticalPacket packet, EventPayload payload) {
    return EventMarker(
      id: packet.packetIdHex,
      lat: payload.latitude,
      lon: payload.longitude,
      categoryId: payload.categoryId,
      note: payload.shortNote,
      ts: packet.timestamp,
    );
  }

  factory EventMarker.fromJson(Map<String, dynamic> json) {
    final id = json['packet_id']?.toString() ?? '';
    return EventMarker(
      id: id.isEmpty ? 'event-${json['id']}' : id,
      lat: _asDouble(json['lat']),
      lon: _asDouble(json['lon']),
      categoryId: _asInt(json['category_id']),
      note: json['short_note']?.toString() ?? '',
      ts: _asInt(json['ts']),
    );
  }
}

/// Alerta emitida por el servidor o por el panel de operador.
class AlertMarker {
  const AlertMarker({
    required this.id,
    required this.lat,
    required this.lon,
    this.severity = 1,
    this.radiusM = 0,
    this.title = '',
    this.ts = 0,
  });

  final String id;
  final double lat;
  final double lon;
  final int severity;
  final int radiusM;
  final String title;
  final int ts;

  factory AlertMarker.fromPacket(TacticalPacket packet, AlertPayload payload) {
    return AlertMarker(
      id: packet.packetIdHex,
      lat: payload.latitude,
      lon: payload.longitude,
      severity: payload.severity.clamp(1, 3),
      radiusM: payload.radiusM,
      title: payload.title,
      ts: packet.timestamp,
    );
  }

  factory AlertMarker.fromJson(Map<String, dynamic> json) {
    final id = json['packet_id']?.toString() ?? '';
    return AlertMarker(
      id: id.isEmpty ? 'alert-${json['id']}' : id,
      lat: _asDouble(json['lat']),
      lon: _asDouble(json['lon']),
      severity: _asInt(json['severity'], 1).clamp(1, 3),
      radiusM: _asInt(json['radius_m']),
      title: json['title']?.toString() ?? '',
      ts: _asInt(json['ts']),
    );
  }
}

/// Estado observable del tablero: enlace, posición propia y capas tácticas.
class AppState extends ChangeNotifier {
  static const int _maxEvents = 500;
  static const int _maxAlerts = 200;

  LinkState link = LinkState.disconnected;
  bool simulating = false;

  /// `sender_id` propio: se usa para no pintar el eco de la propia posición.
  int? selfId;

  bool knowsAlert(String id) => _alertIds.contains(id);

  double? ownLat;
  double? ownLon;
  int ownHeading = 0;
  double ownSpeedKmh = 0;
  double ownAltitudeM = 0;

  final Map<int, Peer> peers = <int, Peer>{};
  final List<EventMarker> events = <EventMarker>[];
  final List<AlertMarker> alerts = <AlertMarker>[];

  String? lastError;

  final Set<String> _eventIds = <String>{};
  final Set<String> _alertIds = <String>{};

  void setLink(LinkState value) {
    if (link == value) return;
    link = value;
    notifyListeners();
  }

  void setSimulating(bool value) {
    if (simulating == value) return;
    simulating = value;
    notifyListeners();
  }

  void setError(String message) {
    lastError = message;
    notifyListeners();
  }

  void clearError() {
    if (lastError == null) return;
    lastError = null;
    notifyListeners();
  }

  void setOwn(
    double lat,
    double lon, {
    int? heading,
    double? speedKmh,
    double? altitudeM,
  }) {
    ownLat = lat;
    ownLon = lon;
    if (heading != null) ownHeading = heading % 360;
    if (speedKmh != null) ownSpeedKmh = speedKmh;
    if (altitudeM != null) ownAltitudeM = altitudeM;
    notifyListeners();
  }

  /// Aplica un paquete recibido por WebSocket (o, en el futuro, por radio).
  void applyPacket(TacticalPacket packet) {
    // Solo se descarta el eco de la propia posición; un evento propio sí se
    // pinta en el tablero al instante (el servidor no lo reenvía al emisor).
    if (packet.senderId != 0 &&
        packet.senderId == selfId &&
        packet.type == PacketType.positionUpdate) {
      return;
    }

    switch (packet.type) {
      case PacketType.positionUpdate:
        final position = packet.position;
        if (position == null) return;
        _upsertPeer(
          Peer(
            senderId: packet.senderId,
            lat: position.latitude,
            lon: position.longitude,
            headingDeg: position.headingDeg.clamp(0, 359),
            batteryPct: position.batteryPct.clamp(0, 100),
            speedKmh: position.speedCms / 100 * 3.6,
            lastTs: packet.timestamp,
          ),
        );
        break;
      case PacketType.userEvent:
        final event = packet.event;
        if (event == null) return;
        _addEvent(EventMarker.fromPacket(packet, event));
        break;
      case PacketType.serverAlert:
        final alert = packet.alert;
        if (alert == null) return;
        _addAlert(AlertMarker.fromPacket(packet, alert));
        break;
      case PacketType.ackConfirmation:
        break;
    }
  }

  /// Carga la foto inicial de `/api/state`.
  void applySnapshot(Map<String, dynamic> json) {
    final peerList = json['peers'];
    if (peerList is List) {
      peers.clear();
      for (final item in peerList) {
        if (item is! Map) continue;
        final peer = Peer.fromJson(Map<String, dynamic>.from(item));
        if (peer.senderId == selfId) continue;
        peers[peer.senderId] = peer;
      }
    }

    final eventList = json['events'];
    if (eventList is List) {
      events.clear();
      _eventIds.clear();
      for (final item in eventList) {
        if (item is! Map) continue;
        _addEvent(EventMarker.fromJson(Map<String, dynamic>.from(item)));
      }
    }

    final alertList = json['alerts'];
    if (alertList is List) {
      alerts.clear();
      _alertIds.clear();
      for (final item in alertList) {
        if (item is! Map) continue;
        _addAlert(AlertMarker.fromJson(Map<String, dynamic>.from(item)));
      }
    }

    lastError = null;
    notifyListeners();
  }

  void _upsertPeer(Peer peer) {
    peers[peer.senderId] = peer;
    notifyListeners();
  }

  void _addEvent(EventMarker event) {
    if (!_eventIds.add(event.id)) return;
    events.insert(0, event);
    if (events.length > _maxEvents) {
      final removed = events.removeLast();
      _eventIds.remove(removed.id);
    }
    notifyListeners();
  }

  void _addAlert(AlertMarker alert) {
    if (!_alertIds.add(alert.id)) return;
    alerts.insert(0, alert);
    if (alerts.length > _maxAlerts) {
      final removed = alerts.removeLast();
      _alertIds.remove(removed.id);
    }
    notifyListeners();
  }
}
