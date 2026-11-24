import 'package:flutter/services.dart';

/// Puente con APIs de Android que la app necesita sin plugins de terceros.
class DeviceChannel {
  static const MethodChannel _channel = MethodChannel('openterritorio/device');

  /// Nivel de batería real (0–100), o `null` si no se puede leer.
  static Future<int?> batteryPct() async {
    try {
      final value = await _channel.invokeMethod<int>('batteryPct');
      if (value == null) return null;
      return value.clamp(0, 100);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Carga en el teléfono (0–100) o `null` si no está conectado.
  static Future<int?> batteryCharging() async {
    try {
      return await _channel.invokeMethod<int>('isCharging');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
