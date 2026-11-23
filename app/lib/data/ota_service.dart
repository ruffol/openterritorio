import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'backend_client.dart';

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

class OtaException implements Exception {
  OtaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Actualización publicada por el backend en `/api/app/latest`.
class OtaUpdate {
  const OtaUpdate({
    required this.version,
    required this.versionCode,
    required this.sizeBytes,
    required this.sha256,
    required this.notes,
    required this.downloadUrl,
  });

  final String version;
  final int versionCode;
  final int sizeBytes;
  final String sha256;
  final String notes;
  final String downloadUrl;

  factory OtaUpdate.fromJson(Map<String, dynamic> json, String origin) {
    final rawUrl = json['url']?.toString() ?? '/api/app/download';
    return OtaUpdate(
      version: json['version']?.toString() ?? '?',
      versionCode: _asInt(json['version_code']),
      sizeBytes: _asInt(json['size_bytes']),
      sha256: json['sha256']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      downloadUrl: Uri.parse(origin).resolve(rawUrl).toString(),
    );
  }
}

typedef ApkInstaller = Future<String> Function(String apkPath);

/// Comprueba, descarga y lanza la instalación de una actualización (OTA).
class OtaService {
  OtaService({
    required this.client,
    required this.cacheDir,
    required this.installer,
  });

  final BackendClient client;
  final Directory cacheDir;
  final ApkInstaller installer;

  /// Devuelve la actualización publicada o `null` si no hay ninguna.
  Future<OtaUpdate?> check() async {
    final json = await client.fetchAppVersion();
    if (json == null) return null;
    return OtaUpdate.fromJson(json, client.origin);
  }

  /// Descarga el APK, comprueba el sha256 y devuelve el archivo listo.
  Future<File> download(
    OtaUpdate update, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    final file = File(
      '${cacheDir.path}${Platform.pathSeparator}'
      'openterritorio-${update.versionCode}.apk',
    );

    final httpClient = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(update.downloadUrl));
      request.headers['Authorization'] = 'Bearer ${client.token}';
      final response = await httpClient.send(request);
      if (response.statusCode == 401) {
        throw OtaException('token rechazado (401)');
      }
      if (response.statusCode != 200) {
        throw OtaException('descarga HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? update.sizeBytes;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } finally {
      httpClient.close();
    }

    if (update.sha256.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != update.sha256.toLowerCase()) {
        await file.delete();
        throw OtaException('sha256 no coincide');
      }
    }
    return file;
  }

  Future<String> install(File apk) => installer(apk.path);
}
