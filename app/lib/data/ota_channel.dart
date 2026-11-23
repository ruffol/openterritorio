import 'package:flutter/services.dart';

/// Versión instalada de la app, según el PackageManager de Android.
class AppVersionInfo {
  const AppVersionInfo({required this.versionName, required this.versionCode});

  final String versionName;
  final int versionCode;

  static const AppVersionInfo unknown = AppVersionInfo(
    versionName: '?',
    versionCode: 0,
  );
}

/// Puente con el código nativo de Android (PackageManager/PackageInstaller).
class OtaChannel {
  static const MethodChannel _channel = MethodChannel('openterritorio/ota');

  static Future<AppVersionInfo> currentVersion() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getVersion',
      );
      if (result == null) return AppVersionInfo.unknown;
      final code = result['version_code'];
      return AppVersionInfo(
        versionName: result['version_name']?.toString() ?? '?',
        versionCode: code is num ? code.toInt() : 0,
      );
    } on MissingPluginException {
      return AppVersionInfo.unknown;
    } on PlatformException {
      return AppVersionInfo.unknown;
    }
  }

  /// Directorio de caché de la app (para el APK descargado).
  static Future<String?> cacheDirectory() async {
    try {
      return await _channel.invokeMethod<String>('cacheDir');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Lanza el instalador del sistema.
  ///
  /// Devuelve `ok`, `permission` (hay que habilitar "instalar apps
  /// desconocidas"; se abre Ajustes) o `error:<mensaje>`.
  static Future<String> install(String apkPath) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'install',
        <String, dynamic>{'path': apkPath},
      );
      return result ?? 'error:sin respuesta del instalador';
    } on MissingPluginException {
      return 'error:canal OTA no disponible';
    } on PlatformException catch (error) {
      return 'error:${error.message ?? error.code}';
    }
  }
}
