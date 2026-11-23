import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/app_state.dart';

class TacticalBoard extends StatelessWidget {
  const TacticalBoard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: BoardPainter(state),
      child: const SizedBox.expand(),
    );
  }
}

class _Geo {
  const _Geo(this.lat, this.lon);
  final double lat;
  final double lon;
}

class BoardPainter extends CustomPainter {
  BoardPainter(this.state);

  final AppState state;

  static const _bg = Color(0xFF0B0F14);
  static const _grid = Color(0xFF1B2634);
  static const _muted = Color(0xFF8B9BB0);
  static const _peerColor = Color(0xFF35C2FF);
  static const _ownColor = Color(0xFF3DDC84);
  static const _eventColor = Color(0xFFFFB020);

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

    var centerLat = 19.2433;
    var centerLon = -103.7247;
    var spanLat = 0.02;
    var spanLon = 0.02;

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
      if (maxLat - minLat < 0.002) {
        final center = (maxLat + minLat) / 2;
        minLat = center - 0.001;
        maxLat = center + 0.001;
      }
      if (maxLon - minLon < 0.002) {
        final center = (maxLon + minLon) / 2;
        minLon = center - 0.001;
        maxLon = center + 0.001;
      }
      centerLat = (minLat + maxLat) / 2;
      centerLon = (minLon + maxLon) / 2;
      spanLat = maxLat - minLat;
      spanLon = maxLon - minLon;
    }

    final cosLat = math.cos(centerLat * math.pi / 180).clamp(0.15, 1.0);
    final spanX = spanLon * cosLat;
    final spanY = spanLat;
    final scale = math.min(size.width / (spanX * 1.35), size.height / (spanY * 1.35));

    Offset project(double lat, double lon) => Offset(
          size.width / 2 + (lon - centerLon) * cosLat * scale,
          size.height / 2 - (lat - centerLat) * scale,
        );

    _drawGrid(canvas, size, project, centerLat, centerLon, spanLat, spanLon);

    for (final alert in state.alerts) {
      final center = project(alert.lat, alert.lon);
      final color = _severityColor(alert.severity);
      final radiusPx = math.max(8.0, alert.radiusM / 111320.0 * scale);
      canvas.drawCircle(center, radiusPx, Paint()..color = color.withOpacity(0.10));
      canvas.drawCircle(
        center,
        radiusPx,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color,
      );
      _text(canvas, alert.title.isEmpty ? 'Alerta' : alert.title,
          center + Offset(radiusPx + 4, -8), color);
    }

    for (final event in state.events) {
      final center = project(event.lat, event.lon);
      final path = Path()
        ..moveTo(center.dx, center.dy - 7)
        ..lineTo(center.dx + 7, center.dy)
        ..lineTo(center.dx, center.dy + 7)
        ..lineTo(center.dx - 7, center.dy)
        ..close();
      canvas.drawPath(path, Paint()..color = _eventColor);
      _text(canvas, event.note.isEmpty ? 'Evento' : event.note,
          center + const Offset(9, -8), _eventColor);
    }

    for (final peer in state.peers.values) {
      final center = project(peer.lat, peer.lon);
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
      );
    }

    final ownLat = state.ownLat;
    final ownLon = state.ownLon;
    if (ownLat != null && ownLon != null) {
      final center = project(ownLat, ownLon);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _ownColor;
      canvas.drawCircle(center, 9, stroke);
      canvas.drawLine(center - const Offset(15, 0), center + const Offset(15, 0), stroke);
      canvas.drawLine(center - const Offset(0, 15), center + const Offset(0, 15), stroke);
      _text(canvas, 'YO', center + const Offset(11, -18), _ownColor);
    }

    _drawScale(canvas, size, scale, points.isEmpty);

    if (points.isEmpty) {
      _text(
        canvas,
        'Sin datos todavía. Conecta el backend o pulsa SIM.',
        Offset(size.width * 0.08, size.height * 0.48),
        _muted,
        size: 13,
      );
    }
  }

  void _drawGrid(
    Canvas canvas,
    Size size,
    Offset Function(double, double) project,
    double centerLat,
    double centerLon,
    double spanLat,
    double spanLon,
  ) {
    final step = spanLat > 0.5
        ? 0.1
        : spanLat > 0.1
            ? 0.02
            : spanLat > 0.02
                ? 0.005
                : 0.001;
    final paint = Paint()
      ..color = _grid
      ..strokeWidth = 1;

    final latMin = centerLat - spanLat * 0.7;
    final latMax = centerLat + spanLat * 0.7;
    for (var lat = (latMin / step).floorToDouble() * step;
        lat <= latMax;
        lat += step) {
      final y = project(lat, centerLon).dy;
      if (y < 0 || y > size.height) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    final lonMin = centerLon - spanLon * 0.7;
    final lonMax = centerLon + spanLon * 0.7;
    for (var lon = (lonMin / step).floorToDouble() * step;
        lon <= lonMax;
        lon += step) {
      final x = project(centerLat, lon).dx;
      if (x < 0 || x > size.width) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    _text(canvas, 'rejilla ${step.toStringAsFixed(3)}°', const Offset(8, 8),
        _muted, size: 10);
  }

  void _drawScale(Canvas canvas, Size size, double scale, bool empty) {
    if (empty) return;
    final meters = scale > 150 ? 1000 : (scale > 60 ? 500 : 200);
    final px = meters / 111320.0 * scale;
    final origin = Offset(12, size.height - 22);
    final paint = Paint()
      ..color = _muted
      ..strokeWidth = 2;
    canvas.drawLine(origin, origin + Offset(px, 0), paint);
    canvas.drawLine(origin + Offset(0, -4), origin + Offset(0, 4), paint);
    canvas.drawLine(origin + Offset(px, -4), origin + Offset(px, 4), paint);
    _text(canvas, '$meters m', origin + const Offset(0, -16), _muted, size: 10);
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

  void _text(Canvas canvas, String value, Offset at, Color color,
      {double size = 11}) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) => true;
}
