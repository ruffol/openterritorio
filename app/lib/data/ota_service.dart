import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'backend_client.dart';

/// Manifiesto publicado en el repositorio.
///
/// El APK se descarga de GitHub, no del tel\u00e9fono que hospeda el backend: ese
/// equipo suele estar con datos m\u00f3viles y solo debe atender eventos y datos
/// del mapa. El backend queda como respaldo cuando no hay internet pero el
/// tel\u00e9fono est\u00e1 cerca en la misma red.
const String kOtaManifestUrl =
    'https://raw.githubusercontent.com/ruffol/openterritorio/master/dist/app/latest.json';

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

/// Actualizaci\u00f3n publicada (GitHub o backend).
class OtaUpdate {
  const OtaUpdate({
    required this.version,
    required this.versionCode,
    required this.sizeBytes,
    required this.sha256,
    required this.notes,
    required this.downloadUrl,
    this.source = 'GitHub',
  });

  final String version;
  final int versionCode;
  final int sizeBytes;
  final String sha256;
  final String notes;
  final String downloadUrl;
  final String source;

  /// `manifestUri` es la URL del `latest.json`: los enlaces relativos del
  /// manifiesto (`url` o `apk`) se resuelven contra ella, as\u00ed sirve igual el
  /// repositorio que el backend.
  factory OtaUpdate.fromJson(
    Map<String, dynamic> json,
    Uri manifestUri, {
    String source = 'GitHub',
  }) {
    final rawUrl = json['url']?.toString();
    final apkName = json['apk']?.toString() ?? 'openterritorio.apk';
    final slash = manifestUri.path.lastIndexOf('/');
    final dir = manifestUri.replace(
      path: slash >= 0 ? manifestUri.path.substring(0, slash + 1) : '/',
    );
    var resolved = (rawUrl != null && rawUrl.isNotEmpty)
        ? manifestUri.resolve(rawUrl)
        : dir.resolve(apkName);
    // `?v=` cambia la URL en cada versión: sin esto el CDN de GitHub puede
    // devolver el APK anterior durante unos minutos y el sha256 no cuadraría.
    final code = _asInt(json['version_code']);
    if (code > 0 && !resolved.hasQuery) {
      resolved = resolved.replace(
        queryParameters: <String, String>{'v': '$code'},
      );
    }
    return OtaUpdate(
      version: json['version']?.toString() ?? '?',
      versionCode: code,
      sizeBytes: _asInt(json['size_bytes']),
      sha256: json['sha256']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      downloadUrl: resolved.toString(),
      source: source,
    );
  }
}

typedef ApkInstaller = Future<String> Function(String apkPath);

/// Comprueba, descarga y lanza la instalaci\u00f3n de una actualizaci\u00f3n (OTA).
class OtaService {
  OtaService({
    this.client,
    required this.cacheDir,
    required this.installer,
    this.manifestUrl = kOtaManifestUrl,
  });

  final BackendClient? client;
  final Directory cacheDir;
  final ApkInstaller installer;
  final String manifestUrl;

  Uri get _manifestUri => Uri.parse(manifestUrl);

  /// Devuelve la actualizaci\u00f3n publicada o `null` si no hay ninguna.
  ///
  /// Primero GitHub (no consume los datos del servidor); si no responde, el
  /// backend de la red local.
  Future<OtaUpdate?> check() async {
    Object? lastError;
    try {
      return await _fromManifest(_manifestUri, 'GitHub');
    } on Object catch (error) {
      lastError = error;
    }

    final local = client;
    final localManifest =
        local == null ? null : Uri.parse('${local.origin}/api/app/latest');
    if (local != null && localManifest != null && localManifest != _manifestUri) {
      try {
        final json = await local.fetchAppVersion();
        if (json == null) return null;
        return OtaUpdate.fromJson(json, localManifest, source: 'servidor local');
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw OtaException('no se pudo consultar la actualizaci\u00f3n ($lastError)');
  }

  Future<OtaUpdate?> _fromManifest(Uri uri, String source) async {
    // `t=` evita la cach\u00e9 de ~5 minutos de raw.githubusercontent.
    final cached = uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        't': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    final response = await http
        .get(cached, headers: <String, String>{'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw OtaException('$source respondi\u00f3 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw OtaException('manifiesto ilegible en $source');
    }
    return OtaUpdate.fromJson(decoded, uri, source: source);
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

    final headers = <String, String>{};
    // El token solo viaja al backend propio; GitHub es p\u00fablico.
    final local = client;
    if (local != null && update.downloadUrl.startsWith(local.origin)) {
      headers['Authorization'] = 'Bearer ${local.token}';
    }

    final httpClient = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(update.downloadUrl))
        ..headers.addAll(headers)
        ..followRedirects = true;
      final response = await httpClient.send(request);
      if (response.statusCode == 401) {
        throw OtaException('token rechazado (401)');
      }
      if (response.statusCode == 403) {
        throw OtaException('el repositorio rechaz\u00f3 la descarga (403)');
      }
      if (response.statusCode == 404) {
        throw OtaException('el APK no est\u00e1 publicado (404)');
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
      if (update.sizeBytes > 0 && received != update.sizeBytes) {
        await file.delete();
        throw OtaException(
          'descarga incompleta: $received de ${update.sizeBytes} bytes',
        );
      }
    } on SocketException {
      throw OtaException('sin conexi\u00f3n: revisa datos m\u00f3viles o WiFi');
    } on TimeoutException {
      throw OtaException('la descarga tard\u00f3 demasiado');
    } finally {
      httpClient.close();
    }

    if (update.sha256.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != update.sha256.toLowerCase()) {
        await file.delete();
        throw OtaException('el archivo lleg\u00f3 da\u00f1ado (sha256 no coincide)');
      }
    }
    return file;
  }

  Future<String> install(File apk) => installer(apk.path);
}
