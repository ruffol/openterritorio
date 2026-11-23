import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_state.dart';
import '../data/backend_client.dart';
import '../data/ota_channel.dart';
import '../data/ota_service.dart';
import '../protocol/tactical_packet.dart';
import 'board.dart';
import 'update_dialog.dart';

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
  StreamSubscription<Position>? _positionSub;
  Timer? _tickTimer;

  String _baseUrl = _defaultUrl;
  String _token = _defaultToken;
  int _senderId = 2000 + math.Random().nextInt(7000);
  int _simStep = 0;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _tickTimer = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('op.url') ?? _defaultUrl;
    _token = prefs.getString('op.token') ?? _defaultToken;
    _senderId = prefs.getInt('op.sender') ?? _senderId;
    _state.selfId = _senderId;
    if (!mounted) return;
    setState(() {});
    _connect();
    unawaited(_startGps());
    if (_token.isNotEmpty) {
      // Comprobación de OTA en segundo plano, sin molestar al arrancar.
      unawaited(
        Future<void>.delayed(
          const Duration(seconds: 4),
          () => _checkUpdate(silent: true),
        ),
      );
    }
    if (_token.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openSettings(first: true),
      );
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
    _packetSub = client.packets.listen(_onPacket);
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

  /// Aplica el paquete y confirma las alertas nuevas con un ACK.
  void _onPacket(TacticalPacket packet) {
    final isNewAlert =
        packet.type == PacketType.serverAlert &&
        packet.alert != null &&
        !_state.knowsAlert(packet.packetIdHex);
    _state.applyPacket(packet);
    if (!isNewAlert) return;
    _client?.send(
      TacticalPacket(
        packetId: _randomPacketId(),
        senderId: _senderId,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        type: PacketType.ackConfirmation,
        ack: AckPayload(ackedPacketId: packet.packetId),
      ),
    );
  }

  Future<void> _startGps() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) return;
      _positionSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 2,
            ),
          ).listen((position) {
            _state.setOwn(
              position.latitude,
              position.longitude,
              heading: position.heading.round(),
              speedKmh: position.speed * 3.6,
              altitudeM: position.altitude,
            );
          }, onError: (Object error) => _state.setError('GPS: $error'));
    } catch (error) {
      _state.setError('GPS: $error');
    }
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
          altitudeM: _state.ownAltitudeM.round(),
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
                decoration: const InputDecoration(
                  labelText: 'ID de dispositivo',
                ),
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
      _state.selfId = _senderId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('op.url', _baseUrl);
      await prefs.setString('op.token', _token);
      await prefs.setInt('op.sender', _senderId);
      _connect();
    }

    urlController.dispose();
    tokenController.dispose();
    idController.dispose();
  }

  Future<void> _createEvent() async {
    final lat = _state.ownLat;
    final lon = _state.ownLon;
    if (lat == null || lon == null) {
      _showSnack('Sin posición: activa el GPS o pulsa SIM.');
      return;
    }

    final noteController = TextEditingController();
    var category = 0;
    final create = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nuevo evento'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'En ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteController,
                autofocus: true,
                maxLength: 64,
                decoration: const InputDecoration(labelText: 'Nota breve'),
              ),
              DropdownButtonFormField<int>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Categoría'),
                items: const <DropdownMenuItem<int>>[
                  DropdownMenuItem<int>(value: 0, child: Text('Genérico')),
                  DropdownMenuItem<int>(value: 1, child: Text('Peligro')),
                  DropdownMenuItem<int>(value: 2, child: Text('Recurso')),
                  DropdownMenuItem<int>(
                    value: 3,
                    child: Text('Punto de reunión'),
                  ),
                  DropdownMenuItem<int>(value: 4, child: Text('Control')),
                ],
                onChanged: (value) =>
                    setDialogState(() => category = value ?? 0),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Marcar'),
            ),
          ],
        ),
      ),
    );

    if (create == true) {
      final packet = TacticalPacket(
        packetId: _randomPacketId(),
        senderId: _senderId,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        type: PacketType.userEvent,
        event: EventPayload(
          categoryId: category,
          latitudeE7: (lat * 1e7).round(),
          longitudeE7: (lon * 1e7).round(),
          shortNote: _truncateUtf8(noteController.text.trim(), 64),
        ),
      );
      final client = _client;
      final delivered = client != null && client.send(packet);
      _state.applyPacket(packet);
      _showSnack(
        delivered
            ? 'Evento enviado.'
            : 'Evento guardado; se enviará al reconectar.',
      );
    }
    noteController.dispose();
  }

  /// Comprueba si el backend publica una versión nueva y, si el operador
  /// acepta, la descarga y lanza el instalador del sistema.
  Future<void> _checkUpdate({bool silent = false}) async {
    if (_checkingUpdate) return;
    final client = _client;
    if (client == null) {
      if (!silent) {
        _showSnack('Conecta con el backend para buscar actualizaciones.');
      }
      return;
    }
    _checkingUpdate = true;
    try {
      final local = await OtaChannel.currentVersion();
      final cachePath = await OtaChannel.cacheDirectory();
      final service = OtaService(
        client: client,
        cacheDir: Directory(cachePath ?? Directory.systemTemp.path),
        installer: OtaChannel.install,
      );
      final update = await service.check();
      if (!mounted) return;
      if (update == null) {
        if (!silent) _showSnack('No hay actualizaciones publicadas.');
        return;
      }
      if (update.versionCode <= local.versionCode) {
        if (!silent) {
          _showSnack('Ya tienes la última versión (v${local.versionName}).');
        }
        return;
      }

      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Actualización v${update.version}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Instalada: v${local.versionName} (${local.versionCode})'),
              const SizedBox(height: 4),
              Text(
                'Nueva: v${update.version} (${update.versionCode}) · '
                '${_formatBytes(update.sizeBytes)}',
              ),
              if (update.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(update.notes.trim()),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Ahora no'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Descargar e instalar'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;

      final result = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => OtaUpdateDialog(service: service, update: update),
      );
      if (!mounted || result == null) return;
      if (result == 'ok') {
        _showSnack('Instalador abierto: confirma la actualización.');
      } else if (result == 'permission') {
        _showSnack(
          'Activa "Instalar apps desconocidas" para OPENTERITORIO '
          'y vuelve a intentarlo.',
        );
      } else {
        _state.setError(
          result.startsWith('error:') ? result.substring(6) : result,
        );
      }
    } on Object catch (error) {
      _state.setError('Actualización: $error');
    } finally {
      _checkingUpdate = false;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return 'tamaño desconocido';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Recorta a [maxBytes] bytes UTF-8 sin partir un carácter.
  String _truncateUtf8(String value, int maxBytes) {
    final bytes = utf8.encode(value);
    if (bytes.length <= maxBytes) return value;
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end -= 1;
    }
    return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
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
    _positionSub?.cancel();
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
            tooltip: 'Buscar actualización',
            onPressed: () => _checkUpdate(),
            icon: const Icon(Icons.system_update_alt),
          ),
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
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'event',
            tooltip: 'Marcar evento en mi posición',
            onPressed: _createEvent,
            child: const Icon(Icons.add_location_alt_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'sim',
            onPressed: () => _state.setSimulating(!_state.simulating),
            icon: Icon(_state.simulating ? Icons.pause : Icons.play_arrow),
            label: Text(_state.simulating ? 'SIM ON' : 'SIM'),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    final location = _state.ownLat == null
        ? 'sin GPS (pulsa SIM)'
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
