import 'dart:async';

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

  /// Resultados que Android envía al terminar la sesión de instalación.
  static final StreamController<Map<String, dynamic>> _results =
      StreamController<Map<String, dynamic>>.broadcast();
  static bool _handlerReady = false;

  static void _ensureHandler() {
    if (_handlerReady) return;
    _handlerReady = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'installResult' && call.arguments is Map) {
        _results.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
  }

  /// Lanza el instalador del sistema y **espera el resultado real**.
  ///
  /// Devuelve `ok` solo si Android confirmó la instalación, `permission` si hay
  /// que habilitar "instalar apps desconocidas" (se abre Ajustes), o
  /// `error:<motivo>` con el mensaje del instalador (firma distinta, versión
  /// no más nueva, sin espacio…).
  static Future<String> install(
    String apkPath, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    _ensureHandler();
    late final StreamSubscription<Map<String, dynamic>> sub;
    final completer = Completer<String>();
    sub = _results.stream.listen((data) {
      if (completer.isCompleted) return;
      if (data['success'] == true) {
        completer.complete('ok');
      } else {
        completer.complete('error:${explainInstallFailure(data)}');
      }
    });
    try {
      final result = await _channel.invokeMethod<String>(
        'install',
        <String, dynamic>{'path': apkPath},
      );
      if (result != 'ok') return result ?? 'error:sin respuesta del instalador';
      return await completer.future.timeout(
        timeout,
        onTimeout: () =>
            'error:el instalador del sistema no respondió (¿pantalla bloqueada?)',
      );
    } on MissingPluginException {
      return 'error:canal OTA no disponible';
    } on PlatformException catch (error) {
      return 'error:${error.message ?? error.code}';
    } finally {
      await sub.cancel();
    }
  }

  /// Traduce el estado de `PackageInstaller` a algo que el operador entienda.
  static String explainInstallFailure(Map<String, dynamic> data) {
    final message = (data['message'] as String?)?.trim() ?? '';
    final hint = switch (data['status']) {
      2 => 'Android bloqueó la instalación (revisa "instalar apps desconocidas")',
      3 => 'instalación cancelada',
      4 => 'el APK descargado no es válido',
      5 => 'conflicto con la app instalada',
      6 => 'sin espacio para instalar',
      7 => 'firma o versión incompatible: desinstala OPENTERITORIO e instálalo de nuevo',
      8 => 'error interno del instalador',
      _ => 'el instalador del sistema falló',
    };
    return message.isEmpty ? hint : '$hint ($message)';
  }
}
