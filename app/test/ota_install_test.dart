import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openterritorio/data/ota_channel.dart';

/// El canal OTA debe devolver el resultado **real** de la instalación, no "ok"
/// en cuanto se cierra la sesión: el operador necesita el motivo del fallo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('openterritorio/ota');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockInstall(String respuesta) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'install') return respuesta;
      return null;
    });
  }

  Future<void> sendResult(Map<String, dynamic> payload) async {
    await messenger.handlePlatformMessage(
      'openterritorio/ota',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('installResult', payload),
      ),
      (_) {},
    );
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('success: devuelve ok solo cuando Android confirma', () async {
    mockInstall('ok');
    final install = OtaChannel.install('/tmp/op.apk');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sendResult(<String, dynamic>{
      'session': 7,
      'success': true,
      'status': 0,
      'message': '',
    });
    expect(await install, 'ok');
  });

  test('fallo por firma: devuelve el motivo en cristiano', () async {
    mockInstall('ok');
    final install = OtaChannel.install('/tmp/op.apk');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sendResult(<String, dynamic>{
      'session': 8,
      'success': false,
      'status': 7,
      'message': 'INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match',
    });
    final result = await install;
    expect(result, startsWith('error:'));
    expect(result, contains('desinstala OPENTERITORIO'));
    expect(result, contains('signatures do not match'));
  });

  test('sin permiso de instalar apps: no espera al instalador', () async {
    mockInstall('permission');
    expect(await OtaChannel.install('/tmp/op.apk'), 'permission');
  });

  test('si el instalador nunca responde, no deja la app colgada', () async {
    mockInstall('ok');
    final result = await OtaChannel.install(
      '/tmp/op.apk',
      timeout: const Duration(milliseconds: 150),
    );
    expect(result, contains('no respondió'));
  });
}
