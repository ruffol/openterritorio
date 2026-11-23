import 'package:flutter_test/flutter_test.dart';
import 'package:openterritorio/data/connection_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sin valores guardados usa la URL por defecto', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await ConnectionSettings.load();
    expect(settings.baseUrl, ConnectionSettings.fallbackUrl);
    expect(settings.token, isEmpty);
    expect(settings.hasToken, isFalse);
    expect(settings.senderId, inInclusiveRange(2000, 8999));
  });

  test('el sender_id generado se reutiliza entre arranques', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final first = await ConnectionSettings.load();
    final second = await ConnectionSettings.load();
    expect(second.senderId, first.senderId);
  });

  test('lee los valores persistidos', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'op.url': 'http://10.0.0.2:3000',
      'op.token': 'secreto',
      'op.sender': 4242,
    });
    final settings = await ConnectionSettings.load();
    expect(settings.baseUrl, 'http://10.0.0.2:3000');
    expect(settings.token, 'secreto');
    expect(settings.hasToken, isTrue);
    expect(settings.senderId, 4242);
  });

  test('save y load hacen round-trip', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const settings = ConnectionSettings(
      baseUrl: 'https://tienda.example',
      token: 'abc',
      senderId: 777,
    );
    await settings.save();
    final loaded = await ConnectionSettings.load();
    expect(loaded.baseUrl, 'https://tienda.example');
    expect(loaded.token, 'abc');
    expect(loaded.senderId, 777);
  });
}
