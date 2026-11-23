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
              Icon(Icons.circle, size: 8, color: linkColor(state.link)),
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
