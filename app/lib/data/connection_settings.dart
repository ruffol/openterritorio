import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// Configuración del enlace con el backend, persistida en `SharedPreferences`.
///
/// Mantiene el `sender_id` estable entre arranques (se genera una sola vez) y
/// centraliza las claves de almacenamiento para que la UI no las conozca.
class ConnectionSettings {
  const ConnectionSettings({
    required this.baseUrl,
    required this.token,
    required this.senderId,
  });

  /// URL por defecto: el backend corre en el mismo teléfono.
  static const String fallbackUrl = String.fromEnvironment(
    'OPENTERITORIO_URL',
    defaultValue: 'http://127.0.0.1:3000',
  );

  static const String _fallbackToken = String.fromEnvironment(
    'OPENTERITORIO_TOKEN',
    defaultValue: '',
  );

  static const String _urlKey = 'op.url';
  static const String _tokenKey = 'op.token';
  static const String _senderKey = 'op.sender';

  static const int _senderBase = 2000;
  static const int _senderRange = 7000;

  final String baseUrl;
  final String token;
  final int senderId;

  bool get hasToken => token.isNotEmpty;

  /// Configuración de compilación, sin tocar el almacenamiento.
  factory ConnectionSettings.fallback() {
    return ConnectionSettings(
      baseUrl: fallbackUrl,
      token: _fallbackToken,
      senderId: _newSenderId(),
    );
  }

  /// Lee la configuración persistida y garantiza un `sender_id` estable.
  static Future<ConnectionSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedSender = prefs.getInt(_senderKey);
    final senderId = storedSender ?? _newSenderId();
    if (storedSender == null) {
      await prefs.setInt(_senderKey, senderId);
    }
    return ConnectionSettings(
      baseUrl: prefs.getString(_urlKey) ?? fallbackUrl,
      token: prefs.getString(_tokenKey) ?? _fallbackToken,
      senderId: senderId,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, baseUrl);
    await prefs.setString(_tokenKey, token);
    await prefs.setInt(_senderKey, senderId);
  }

  static int _newSenderId() =>
      _senderBase + math.Random.secure().nextInt(_senderRange);
}
