import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/services/live/live_api_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  test('read returns null when nothing stored', () async {
    final store = LiveApiKeyStore();
    expect(await store.read(), isNull);
  });

  test('write then read round-trips through secure storage', () async {
    final store = LiveApiKeyStore();
    await store.write('AIza-secure-1');
    expect(await store.read(), 'AIza-secure-1');
    const storage = FlutterSecureStorage();
    expect(
      await storage.read(key: LiveApiKeyStore.secureKey),
      'AIza-secure-1',
    );
  });

  test('write removes the legacy SharedPreferences copy', () async {
    SharedPreferences.setMockInitialValues({
      LiveApiKeyStore.legacyPrefsKey: 'AIza-old',
    });
    final store = LiveApiKeyStore();
    await store.write('AIza-new');
    expect((await prefs()).getString(LiveApiKeyStore.legacyPrefsKey), isNull);
    expect(await store.read(), 'AIza-new');
  });

  test('delete clears both secure and legacy locations', () async {
    SharedPreferences.setMockInitialValues({
      LiveApiKeyStore.legacyPrefsKey: 'AIza-old',
    });
    const storage = FlutterSecureStorage();
    await storage.write(key: LiveApiKeyStore.secureKey, value: 'AIza-sec');
    final store = LiveApiKeyStore();
    await store.delete();
    expect(await store.read(), isNull);
    expect((await prefs()).getString(LiveApiKeyStore.legacyPrefsKey), isNull);
  });

  test('read migrates legacy SharedPreferences value and clears it', () async {
    SharedPreferences.setMockInitialValues({
      LiveApiKeyStore.legacyPrefsKey: 'AIza-legacy-1',
    });
    final store = LiveApiKeyStore();
    expect(await store.read(), 'AIza-legacy-1');
    // 遷移後：舊位置已清除、新位置已寫入
    expect((await prefs()).getString(LiveApiKeyStore.legacyPrefsKey), isNull);
    const storage = FlutterSecureStorage();
    expect(
      await storage.read(key: LiveApiKeyStore.secureKey),
      'AIza-legacy-1',
    );
    // 第二次讀取不再依賴 legacy
    expect(await store.read(), 'AIza-legacy-1');
  });

  test('secure storage wins over legacy and stale legacy is removed', () async {
    SharedPreferences.setMockInitialValues({
      LiveApiKeyStore.legacyPrefsKey: 'AIza-legacy-2',
    });
    const storage = FlutterSecureStorage();
    await storage.write(key: LiveApiKeyStore.secureKey, value: 'AIza-sec-2');
    final store = LiveApiKeyStore();
    expect(await store.read(), 'AIza-sec-2');
    expect((await prefs()).getString(LiveApiKeyStore.legacyPrefsKey), isNull);
  });
}
