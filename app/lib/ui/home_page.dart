import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/backend_client.dart';
import '../protocol/tactical_packet.dart';
import 'board.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _defaultUrl = String.fromEnvironment(
    'OPENTERITORIO_URL',
    defaultValue: 'http://127.0.0.1:3000',
  );
  static const String _defaultToken = String.fromEnvironment(
    'OPENTERITORIO_TOKEN',
    defaultValue: '',
  );

  final AppState _state = AppState();
  final math.Random _random = math.Random.secure();

  BackendClient? _client;
  StreamSubscription<TacticalPacket>? _packetSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  Timer? _tickTimer;

  String _baseUrl = _defaultUrl;
  String _token = _defaultToken;
  int _senderId = 2000 + math.Random().nextInt(7000);
  int _simStep = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _tickTimer = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  void _bootstrap() {
    setState(() {});
    _connect();
    if (_token.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings(first: true));
    }
  }

  void _connect() {
    _packetSub?.cancel();
    _statusSub?.cancel();
    _client?.dispose();

    if (_token.isEmpty) {
      _state.setConnection('sin token');
      return;
    }

    final client = BackendClient(
      baseUrl: _baseUrl,
      token: _token,
      senderId: _senderId,
    );
    _client = client;
    _packetSub = client.packets.listen(_state.applyPacket);
    _statusSub = client.statuses.listen((status) {
      switch (status) {
        case ConnectionStatus.connected:
          _state.setConnection('conectado');
          break;
        case ConnectionStatus.connecting:
          _state.setConnection('conectando');
          break;
        case ConnectionStatus.disconnected:
          _state.setConnection('desconectado');
          break;
      }
    });
    client.connect();
    client
        .fetchState()
        .then((json) => _state.applySnapshot(json))
        .catchError((Object error) => _state.setError('$error'));
  }

  void _tick() {
    if (_state.simulating) {
      _simStep += 1;
      final lat = 19.2433 + math.sin(_simStep / 3) * 0.0009;
      final lon = -103.7247 + math.cos(_simStep / 4) * 0.0009;
      _state.setOwn(lat, lon, heading: (_simStep * 37) % 360, speedKmh: 15);
    }

    final lat = _state.ownLat;
    final lon = _state.ownLon;
    final client = _client;
    if (lat == null || lon == null || client == null) return;

    client.send(
      TacticalPacket(
        packetId: _randomPacketId(),
        senderId: _senderId,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        type: PacketType.positionUpdate,
        position: PositionPayload(
          latitudeE7: (lat * 1e7).round(),
          longitudeE7: (lon * 1e7).round(),
          altitudeM: 500,
          speedCms: (_state.ownSpeedKmh / 3.6 * 100).round(),
          headingDeg: _state.ownHeading,
          batteryPct: 100,
        ),
      ),
    );
  }

  Uint8List _randomPacketId() {
    return Uint8List.fromList(
      List<int>.generate(8, (_) => _random.nextInt(256)),
    );
  }

  Future<void> _openSettings({bool first = false}) async {
    final urlController = TextEditingController(text: _baseUrl);
    final tokenController = TextEditingController(text: _token);
    final idController = TextEditingController(text: '$_senderId');

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Conexión'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Servidor',
                  hintText: 'http://192.168.100.3:3000',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(labelText: 'Token'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: idController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'ID de dispositivo'),
              ),
              if (first)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Introduce la URL y el token del backend.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (saved == true) {
      _baseUrl = urlController.text.trim();
      _token = tokenController.text.trim();
      _senderId = int.tryParse(idController.text.trim()) ?? _senderId;
      _connect();
    }

    urlController.dispose();
    tokenController.dispose();
    idController.dispose();
  }

  Color get _connectionColor {
    switch (_state.connection) {
      case 'conectado':
        return const Color(0xFF3DDC84);
      case 'conectando':
        return const Color(0xFFFFB020);
      default:
        return const Color(0xFFFF5C6C);
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _packetSub?.cancel();
    _statusSub?.cancel();
    _client?.dispose();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.circle, size: 9, color: _connectionColor),
            const SizedBox(width: 8),
            const Text('OPENTERITORIO'),
            const SizedBox(width: 8),
            Text(
              'ID $_senderId',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refrescar estado',
            onPressed: () {
              _client
                  ?.fetchState()
                  .then((json) => _state.applySnapshot(json))
                  .catchError((Object error) => _state.setError('$error'));
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Conexión',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          return Column(
            children: [
              Expanded(child: TacticalBoard(state: _state)),
              _statusBar(),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _state.setSimulating(!_state.simulating),
        icon: Icon(_state.simulating ? Icons.pause : Icons.play_arrow),
        label: Text(_state.simulating ? 'SIM ON' : 'SIM'),
      ),
    );
  }

  Widget _statusBar() {
    final location = _state.ownLat == null
        ? 'sin posición (pulsa SIM)'
        : '${_state.ownLat!.toStringAsFixed(5)}, ${_state.ownLon!.toStringAsFixed(5)}';
    return Container(
      width: double.infinity,
      color: const Color(0xFF101722),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: _connectionColor),
              const SizedBox(width: 6),
              Text(
                _state.connection,
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
            '${_state.peers.length} pares · ${_state.events.length} eventos · '
            '${_state.alerts.length} alertas',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          if (_state.lastError != null)
            Text(
              _state.lastError!,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF5C6C)),
            ),
        ],
      ),
    );
  }
}
