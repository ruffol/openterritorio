import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/tactical_packet.dart';

/// Estado del enlace con el backend táctico.
enum ConnectionStatus { connected, connecting, disconnected }

/// Error de transporte/REST con mensaje legible para el operador.
class BackendException implements Exception {
  BackendException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _QueuedPacket {
  _QueuedPacket(this.bytes, this.createdAt);

  final Uint8List bytes;
  final DateTime createdAt;
}

/// Cliente del backend del teléfono: WebSocket binario (paquetes Protobuf)
/// y REST (`/api/state`) para la foto inicial.
///
/// - Autenticación por token: `?token=` en el handshake y `Bearer` en REST.
/// - Reconexión exponencial con jitter (1 s … 30 s).
/// - Los paquetes que no se pueden enviar se encolan un tiempo acotado para no
///   inundar el servidor con posiciones viejas al recuperar cobertura.
class BackendClient {
  BackendClient({
    required String baseUrl,
    required this.token,
    required this.senderId,
  }) : origin = _normalize(baseUrl);

  /// Origen HTTP normalizado, sin barra final (p. ej. `http://127.0.0.1:3000`).
  final String origin;
  final String token;
  final int senderId;

  static const Duration _requestTimeout = Duration(seconds: 10);
  static const int _maxQueued = 60;
  static const Duration _maxQueueAge = Duration(seconds: 90);

  final StreamController<TacticalPacket> _packets =
      StreamController<TacticalPacket>.broadcast();
  final StreamController<ConnectionStatus> _statuses =
      StreamController<ConnectionStatus>.broadcast();

  final List<_QueuedPacket> _queue = <_QueuedPacket>[];
  final math.Random _random = math.Random();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  int _attempt = 0;
  int _generation = 0;
  bool _connected = false;
  bool _disposed = false;

  /// Paquetes recibidos del servidor y de otros pares.
  Stream<TacticalPacket> get packets => _packets.stream;

  /// Cambios de estado del enlace (para la barra de estado de la app).
  Stream<ConnectionStatus> get statuses => _statuses.stream;

  ConnectionStatus get status => _status;

  Uri get _wsUri {
    final base = Uri.parse(origin);
    final secure = base.scheme == 'https' || base.scheme == 'wss';
    final path = '${base.path}/ws'.replaceAll(RegExp(r'/+'), '/');
    return Uri(
      scheme: secure ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: path,
      queryParameters: {'token': token, 'transport': 'app'},
    );
  }

  Uri _restUri(String path) => Uri.parse('$origin$path');

  static String _normalize(String value) {
    var v = value.trim();
    if (v.isEmpty) return 'http://127.0.0.1:3000';
    if (!v.contains('://')) v = 'http://$v';
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  /// Abre el WebSocket; si falla, reintenta en segundo plano.
  void connect() {
    if (_disposed) return;
    _attempt = 0;
    unawaited(_open());
  }

  Future<void> _open() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final generation = ++_generation;
    _emitStatus(ConnectionStatus.connecting);

    if (token.isEmpty) {
      _emitStatus(ConnectionStatus.disconnected);
      return;
    }

    final channel = WebSocketChannel.connect(_wsUri);
    _channel = channel;
    try {
      await channel.ready;
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _emitStatus(ConnectionStatus.disconnected);
        _scheduleReconnect();
      }
      return;
    }

    if (_disposed || generation != _generation) {
      unawaited(channel.sink.close());
      return;
    }

    _connected = true;
    _attempt = 0;
    _emitStatus(ConnectionStatus.connected);
    _flushQueue();
    _subscription = channel.stream.listen(
      _handleFrame,
      onError: (Object _) => _handleDisconnect(generation),
      onDone: () => _handleDisconnect(generation),
      cancelOnError: true,
    );
  }

  void _handleFrame(dynamic data) {
    if (data is! List<int>) return; // el servidor solo envía frames binarios
    try {
      _packets.add(TacticalPacket.decode(Uint8List.fromList(data)));
    } on FormatException {
      // Frame corrupto: se descarta; el protocolo no debe producirlos.
    }
  }

  void _handleDisconnect(int generation) {
    if (generation != _generation) return;
    _connected = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.sink.close());
    _emitStatus(ConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final attempt = _attempt++;
    final ceiling = math.min(30000, 1000 * math.pow(1.7, attempt)).toInt();
    final jitter = (ceiling * 0.2 * _random.nextDouble()).toInt();
    _reconnectTimer = Timer(Duration(milliseconds: ceiling + jitter), _open);
  }

  /// Envía un paquete. Devuelve `true` si salió por el socket en ese momento o
  /// `false` si quedó en cola esperando reconexión.
  bool send(TacticalPacket packet) {
    if (_disposed) return false;
    final bytes = packet.encode();
    final channel = _channel;
    if (_connected && channel != null) {
      channel.sink.add(bytes);
      return true;
    }
    _pruneQueue();
    if (_queue.length >= _maxQueued) _queue.removeAt(0);
    _queue.add(_QueuedPacket(bytes, DateTime.now()));
    return false;
  }

  void _pruneQueue() {
    final now = DateTime.now();
    _queue.removeWhere((item) => now.difference(item.createdAt) > _maxQueueAge);
  }

  void _flushQueue() {
    _pruneQueue();
    final channel = _channel;
    if (channel == null) return;
    for (final item in _queue) {
      channel.sink.add(item.bytes);
    }
    _queue.clear();
  }

  /// Foto del estado guardado en el servidor (pares, eventos y alertas).
  Future<Map<String, dynamic>> fetchState() async {
    final response = await http
        .get(
          _restUri('/api/state'),
          headers: <String, String>{'Authorization': 'Bearer $token'},
        )
        .timeout(_requestTimeout);
    if (response.statusCode == 401) {
      throw BackendException('token rechazado (401)');
    }
    if (response.statusCode != 200) {
      throw BackendException('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw BackendException('respuesta inesperada de /api/state');
    }
    return decoded;
  }

  /// Última versión publicada para OTA, o `null` si no hay ninguna.
  Future<Map<String, dynamic>?> fetchAppVersion() async {
    final response = await http
        .get(
          _restUri('/api/app/latest'),
          headers: <String, String>{'Authorization': 'Bearer $token'},
        )
        .timeout(_requestTimeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode == 401) {
      throw BackendException('token rechazado (401)');
    }
    if (response.statusCode != 200) {
      throw BackendException('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw BackendException('respuesta inesperada de /api/app/latest');
    }
    return decoded;
  }

  void _emitStatus(ConnectionStatus next) {
    if (_status == next || _statuses.isClosed) return;
    _status = next;
    _statuses.add(next);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_channel?.sink.close());
    _channel = null;
    unawaited(_packets.close());
    unawaited(_statuses.close());
  }
}
