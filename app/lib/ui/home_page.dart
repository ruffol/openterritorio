import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_state.dart';
import '../data/backend_client.dart';
import '../data/connection_settings.dart';
import '../data/ota_channel.dart';
import '../data/ota_service.dart';
import '../protocol/tactical_packet.dart';
import 'board.dart';
import 'connection_dialog.dart';
import 'event_dialog.dart';
import 'status_bar.dart';
import 'update_dialog.dart';

/// Pantalla principal: orquesta enlace, GPS, tablero, eventos y OTA.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AppState _state = AppState();
  final math.Random _random = math.Random.secure();

  BackendClient? _client;
  StreamSubscription<TacticalPacket>? _packetSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _tickTimer;
  final TransformationController _transformController = TransformationController();

  /// Se sustituye en `_bootstrap` por la configuración persistida.
  ConnectionSettings _settings = ConnectionSettings.fallback();
  int _simStep = 0;
  bool _checkingUpdate = false;

  void _calibrate() {
    _transformController.value = Matrix4.identity();
    _showSnack('Mapa calibrado y centrado en Colima');
  }

  int get _senderId => _settings.senderId;

  int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _tickTimer = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  Future<void> _bootstrap() async {
    try {
      _settings = await ConnectionSettings.load();
    } on Object {
      // Sin almacenamiento disponible se usan los valores de compilación.
    }
    if (!mounted) return;
    _state.selfId = _settings.senderId;
    setState(() {});
    _connect();
    unawaited(_startGps());

    if (_settings.hasToken) {
      // Comprobación de OTA en segundo plano, sin molestar al arrancar.
      unawaited(
        Future<void>.delayed(
          const Duration(seconds: 4),
          () => _checkUpdate(silent: true),
        ),
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openSettings(first: true),
      );
    }
  }

  void _connect() {
    _packetSub?.cancel();
    _statusSub?.cancel();
    _client?.dispose();
    _client = null;

    if (!_settings.hasToken) {
      _state.setLink(LinkState.noToken);
      return;
    }

    final client = BackendClient(
      baseUrl: _settings.baseUrl,
      token: _settings.token,
      senderId: _senderId,
    );
    _client = client;
    _packetSub = client.packets.listen(_onPacket);
    _statusSub = client.statuses.listen(_onStatus);
    client.connect();
    _refreshState(client);
  }

  void _onStatus(ConnectionStatus status) {
    _state.setLink(switch (status) {
      ConnectionStatus.connected => LinkState.connected,
      ConnectionStatus.connecting => LinkState.connecting,
      ConnectionStatus.disconnected => LinkState.disconnected,
    });
  }

  /// Pide la foto de `/api/state` al backend actual.
  void _refreshState([BackendClient? client]) {
    final target = client ?? _client;
    if (target == null) return;
    target
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
        timestamp: _nowSeconds,
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
        timestamp: _nowSeconds,
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
    final updated = await showDialog<ConnectionSettings>(
      context: context,
      builder: (_) => ConnectionDialog(initial: _settings, firstTime: first),
    );
    if (updated == null || !mounted) return;

    _settings = updated;
    _state.selfId = updated.senderId;
    try {
      await updated.save();
    } on Object catch (error) {
      _state.setError('No se pudo guardar la configuración: $error');
    }
    if (!mounted) return;
    setState(() {});
    _connect();
  }

  Future<void> _createEvent() async {
    final lat = _state.ownLat;
    final lon = _state.ownLon;
    if (lat == null || lon == null) {
      _showSnack('Sin posición: activa el GPS o pulsa SIM.');
      return;
    }

    final draft = await showDialog<EventDraft>(
      context: context,
      builder: (_) => EventDialog(latitude: lat, longitude: lon),
    );
    if (draft == null || !mounted) return;

    final packet = TacticalPacket(
      packetId: _randomPacketId(),
      senderId: _senderId,
      timestamp: _nowSeconds,
      type: PacketType.userEvent,
      event: EventPayload(
        categoryId: draft.categoryId,
        latitudeE7: (lat * 1e7).round(),
        longitudeE7: (lon * 1e7).round(),
        shortNote: draft.note,
      ),
    );
    final delivered = _client?.send(packet) ?? false;
    _state.applyPacket(packet);
    _showSnack(
      delivered
          ? 'Evento enviado.'
          : 'Evento guardado; se enviará al reconectar.',
    );
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

      final accepted = await confirmUpdate(
        context,
        update: update,
        local: local,
      );
      if (!accepted || !mounted) return;

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

  Future<void> _showAbout() async {
    final info = await OtaChannel.currentVersion();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('OPENTERITORIO'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Versión instalada: v${info.versionName} (código ${info.versionCode})'),
            const SizedBox(height: 12),
            const Text('Repositorio oficial:'),
            const SelectableText(
              'https://github.com/ruffol/openterritorio',
              style: TextStyle(color: Colors.blue),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _checkUpdate();
            },
            child: const Text('Comprobar OTA'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _packetSub?.cancel();
    _statusSub?.cancel();
    _positionSub?.cancel();
    _transformController.dispose();
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
            BlinkingDot(link: _state.link, size: 9),
            const SizedBox(width: 8),
            const Text('OPENTERITORIO'),
            const SizedBox(width: 8),
            Text(
              'ID ${_settings.senderId}',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Versión y Repositorio',
            onPressed: _showAbout,
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: 'Buscar actualización',
            onPressed: () => _checkUpdate(),
            icon: const Icon(Icons.system_update_alt),
          ),
          IconButton(
            tooltip: 'Refrescar estado',
            onPressed: _refreshState,
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
              Expanded(
                child: InteractiveViewer(
                  transformationController: _transformController,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  minScale: 0.5,
                  maxScale: 8.0,
                  child: TacticalBoard(state: _state),
                ),
              ),
              StatusBar(state: _state),
            ],
          );
        },
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'calibrate',
            tooltip: 'Calibrar / Centrar mapa',
            onPressed: _calibrate,
            child: const Icon(Icons.gps_fixed),
          ),
          const SizedBox(height: 12),
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
}
