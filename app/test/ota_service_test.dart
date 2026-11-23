import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openterritorio/data/backend_client.dart';
import 'package:openterritorio/data/ota_service.dart';

/// Verifica el flujo OTA del cliente contra un backend real de mentira:
/// metadata, descarga autenticada, verificación de sha256 e instalación.
void main() {
  late HttpServer server;
  late int port;
  late Directory cacheDir;
  late List<int> apk;
  late String apkSha;
  late Map<String, dynamic> manifest;
  late bool notFound;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('openterritorio-ota-');
    notFound = false;
    apk = List<int>.generate(4096, (i) => (i * 31 + 7) & 0xff);
    apkSha = sha256.convert(apk).toString();
    manifest = <String, dynamic>{
      'ok': true,
      'version': '0.2.0',
      'version_code': 2,
      'size_bytes': apk.length,
      'sha256': apkSha,
      'notes': 'corrige el tablero',
      'url': '/api/app/download',
    };

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((HttpRequest request) async {
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      if (auth != 'Bearer secret') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      if (notFound) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      switch (request.uri.path) {
        case '/api/app/latest':
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(manifest));
          break;
        case '/api/app/download':
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.android.package-archive',
          );
          request.response.add(apk);
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await cacheDir.delete(recursive: true);
  });

  OtaService serviceFor(String token) => OtaService(
    client: BackendClient(
      baseUrl: 'http://127.0.0.1:$port',
      token: token,
      senderId: 1,
    ),
    cacheDir: cacheDir,
    installer: (path) async => 'ok',
  );

  test('detecta la versión publicada', () async {
    final update = await serviceFor('secret').check();
    expect(update, isNotNull);
    expect(update!.version, '0.2.0');
    expect(update.versionCode, 2);
    expect(update.sizeBytes, apk.length);
    expect(update.sha256, apkSha);
    expect(update.notes, 'corrige el tablero');
    expect(update.downloadUrl, 'http://127.0.0.1:$port/api/app/download');
  });

  test('descarga, verifica sha256 e instala', () async {
    final progress = <double>[];
    final service = serviceFor('secret');
    final update = (await service.check())!;

    final file = await service.download(
      update,
      onProgress: (received, total) {
        if (total > 0) progress.add(received / total);
      },
    );
    expect(await file.readAsBytes(), apk);
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);

    String? installedPath;
    final withInstaller = OtaService(
      client: service.client,
      cacheDir: cacheDir,
      installer: (path) async {
        installedPath = path;
        return 'ok';
      },
    );
    expect(await withInstaller.install(file), 'ok');
    expect(installedPath, file.path);
  });

  test('rechaza un APK cuyo sha256 no coincide', () async {
    manifest['sha256'] = List<String>.filled(64, 'f').join();
    final service = serviceFor('secret');
    final update = (await service.check())!;
    await expectLater(service.download(update), throwsA(isA<OtaException>()));
  });

  test('sin actualización publicada devuelve null', () async {
    notFound = true;
    expect(await serviceFor('secret').check(), isNull);
  });
}
