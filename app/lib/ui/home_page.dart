import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_state.dart';
import '../data/backend_client.dart';
import '../data/connection_settings.dart';
import '../data/device_channel.dart';
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
  /// Corte guardado en disco de las marcas ya descartadas.
  static const String _marcasKey = 'marcas_limpiadas_hasta';

  final AppState _state = AppState();
  final math.Random _random = math.Random.secure();

  BackendClient? _client;
  StreamSubscription<TacticalPacket>? _packetSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _tickTimer;
  final MapViewport _viewport = MapViewport();

  /// Se sustituye en `_bootstrap` por la configuración persistida.
  ConnectionSettings _settings = ConnectionSettings.fallback();
  int _simStep = 0;
  bool _checkingUpdate = false;
  int _batteryPct = 100;
  int _ticks = 0;

  void _calibrate() {
    final lat = _state.ownLat;
    final lon = _state.ownLon;
    if (lat == null || lon == null) {
      _viewport.goTo(19.2433, -103.7247, zoom: 14);
      _viewport.follow = true;
      _showSnack('Sin GPS todavía: centrado en Colima. Pulsa SIM o activa la ubicación.');
      return;
    }
    _viewport.goTo(lat, lon, zoom: 16);
    _viewport.follow = true;
    _showSnack('Centrado en tu posición (${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})');
  }

  Future<void> _pickLayer() async {
    final chosen = await showDialog<MapLayerId>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Capa de mapa offline'),
        children: [
          for (final layer in kShippedLayers)
            ListTile(
              leading: Icon(
                layer == _viewport.layer
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(layer.label),
              subtitle: Text(layer.attribution, style: const TextStyle(fontSize: 10)),
              onTap: () => Navigator.pop(context, layer),
            ),
        ],
      ),
    );
    if (chosen != null) _viewport.setLayer(chosen);
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
    try {
      final prefs = await SharedPreferences.getInstance();
      _state.limpiadoHasta = prefs.getInt(_marcasKey) ?? 0;
    } on Object {
      // Sin preferencias: se muestran todas las marcas del servidor.
    }
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
    target
        .fetchLandmarks()
        .then((list) => _state.applyLandmarks(list))
        .catchError((Object _) {
          // Sin enlace se mantienen los puntos locales de respaldo.
        });
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
            // En modo SIM manda la posición simulada: el GPS real no la pisa.
            if (_state.simulating) return;
            _state.setOwn(
              position.latitude,
              position.longitude,
              heading: position.heading.round(),
              speedKmh: position.speed * 3.6,
              altitudeM: position.altitude,
            );
            if (_viewport.follow) {
              _viewport.goTo(position.latitude, position.longitude);
            }
          }, onError: (Object error) => _state.setError('GPS: $error'));
    } catch (error) {
      _state.setError('GPS: $error');
    }
  }

  void _tick() {
    _ticks += 1;
    if (_ticks % 6 == 1) unawaited(_refreshBattery());
    if (_state.simulating) {
      _simStep += 1;
      final lat = 19.2433 + math.sin(_simStep / 3) * 0.0009;
      final lon = -103.7247 + math.cos(_simStep / 4) * 0.0009;
      _state.setOwn(lat, lon, heading: (_simStep * 37) % 360, speedKmh: 15);
      if (_viewport.follow) _viewport.goTo(lat, lon);
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
          batteryPct: _batteryPct,
        ),
      ),
    );
  }

  Uint8List _randomPacketId() {
    return Uint8List.fromList(
      List<int>.generate(8, (_) => _random.nextInt(256)),
    );
  }

  /// Nivel de batería real del teléfono (vía BatteryManager).
  Future<void> _refreshBattery() async {
    final pct = await DeviceChannel.batteryPct();
    if (!mounted || pct == null || pct < 0) return;
    _batteryPct = pct.clamp(0, 100);
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
        if (!silent) _showSnack('Sin actualización publicada todavía.');
        return;
      }
      if (update.versionCode <= local.versionCode) {
        if (!silent) {
          _showSnack('Al día: v${local.versionName} (${local.versionCode}) · publicado v${update.version} (${update.versionCode})');
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

  /// Quita del mapa los avisos y pares anteriores a este momento y lo
  /// recuerda en disco para que no reaparezcan al reconectar.
  Future<void> _limpiarMarcas() async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quitar avisos del mapa'),
        content: const Text(
          'Se ocultan los avisos, alertas y equipos que ya había. '
          'Tus puntos fijos (universidad, sangre, marrón) no se tocan. '
          'Lo que llegue de ahora en adelante sí se muestra.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (confirmado != true) return;
    final corte = _state.limpiarMarcas();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_marcasKey, corte);
    } on Object {
      // Si falla el guardado, el corte vale solo para esta sesión.
    }
    if (mounted) _showSnack('Avisos anteriores quitados del mapa.');
  }

  /// Detalle de una nota al tocar su marcador: la cita completa y las fuentes.
  void _mostrarNota(EventMarker evento) {
    final cuando = evento.ts > 0
        ? DateTime.fromMillisecondsSinceEpoch(evento.ts * 1000)
            .toLocal()
            .toString()
            .substring(0, 16)
        : 'sin hora';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(evento.note.isEmpty ? 'Suceso' : evento.note),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cuando,
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 10),
              SelectableText(
                evento.texto.isEmpty
                    ? 'Sin cita guardada para este evento.'
                    : evento.texto,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
              if (evento.fuentes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  evento.fuentes.length > 1
                      ? 'Publicada por ${evento.fuentes.length} fuentes'
                      : 'Fuente',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                for (final fuente in evento.fuentes)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('· $fuente', style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
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
    _viewport.dispose();
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
            tooltip: 'Quitar avisos del mapa',
            onPressed: _limpiarMarcas,
            icon: const Icon(Icons.cleaning_services_outlined),
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
                child: TacticalBoard(
                  state: _state,
                  viewport: _viewport,
                  onEventTap: _mostrarNota,
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
            tooltip: 'Centrar en mi ubicación',
            onPressed: _calibrate,
            child: const Icon(Icons.my_location),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.small(
            heroTag: 'layers',
            tooltip: 'Capa de mapa',
            onPressed: _pickLayer,
            child: const Icon(Icons.layers_outlined),
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
