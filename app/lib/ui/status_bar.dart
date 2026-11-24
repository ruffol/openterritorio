import 'package:material_ui/material_ui.dart';

import '../data/app_state.dart';

/// Color del indicador de enlace (barra superior y barra de estado).
Color linkColor(LinkState link) {
  switch (link) {
    case LinkState.connected:
      return const Color(0xFF3DDC84);
    case LinkState.connecting:
      return const Color(0xFFFFB020);
    case LinkState.noToken:
    case LinkState.disconnected:
      return const Color(0xFFFF5C6C);
  }
}

/// Indicador de semáforo parpadeante cuando está en línea.
class BlinkingDot extends StatefulWidget {
  const BlinkingDot({super.key, required this.link, this.size = 9});

  final LinkState link;
  final double size;

  @override
  State<BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<BlinkingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = linkColor(widget.link);
    if (widget.link != LinkState.connected) {
      return Icon(Icons.circle, size: widget.size, color: color);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Icon(
          Icons.circle,
          size: widget.size,
          color: color.withValues(alpha: 0.25 + 0.75 * _controller.value),
        );
      },
    );
  }
}

/// Pie del tablero: enlace, posición propia, contadores y último error.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final lat = state.ownLat;
    final lon = state.ownLon;
    final location = lat == null || lon == null
        ? 'sin GPS (pulsa SIM)'
        : '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';

    return Container(
      width: double.infinity,
      color: const Color(0xFF101722),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BlinkingDot(link: state.link, size: 8),
              const SizedBox(width: 6),
              Text(
                state.link.label,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(width: 12),
              Text(
                location,
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${state.peers.length} pares · ${state.events.length} eventos · '
            '${state.alerts.length} alertas',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          if (state.lastError != null)
            Text(
              state.lastError!,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF5C6C)),
            ),
        ],
      ),
    );
  }
}
