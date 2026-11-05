import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart'
    hide SharedPreferencesAsync;

import 'package:OmniChat/core/services/backup/data_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fontScaleKey = 'display_chat_font_scale_v1';
  const windowWidthKey = 'window_width_v1';
  const privateHostsKey = 'web_fetch_allow_private_hosts_v1';
  const longImageTilingKey = 'long_image_tiling_v1';
  const openCodeFetchedAtKey = 'opencode_catalog_fetched_at_v1';
  const openCodeEtagKey = 'opencode_catalog_etag_v1';
  const normalKey = 'some_regular_setting_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues({
      fontScaleKey: 1.4,
      windowWidthKey: 1200,
      privateHostsKey: false,
      longImageTilingKey: false,
      openCodeFetchedAtKey: 123,
      openCodeEtagKey: '"v1"',
      normalKey: 'hello',
    });
  });

  group('SharedPreferencesAsync local-only keys', () {
    test('snapshot excludes chat font scale and window state', () async {
      final prefs = await SharedPreferencesAsync.instance;
      final map = await prefs.snapshot();

      expect(
        map.containsKey(fontScaleKey),
        isFalse,
        reason: 'chat font scale must stay local to the device',
      );
      expect(map.containsKey(windowWidthKey), isFalse);
      expect(
        map.containsKey(privateHostsKey),
        isFalse,
        reason: 'allowing private hosts is device/network specific',
      );
      expect(
        map.containsKey(longImageTilingKey),
        isFalse,
        reason: 'long-image tiling depends on device memory limits',
      );
      expect(
        map.containsKey(openCodeFetchedAtKey),
        isFalse,
        reason: 'OpenCode overlay refresh metadata is device-local',
      );
      expect(map.containsKey(openCodeEtagKey), isFalse);
      expect(map[normalKey], 'hello');
    });

    test('restore skips local-only keys but applies the rest', () async {
      final prefs = await SharedPreferencesAsync.instance;
      await prefs.restore({
        fontScaleKey: 0.8,
        windowWidthKey: 800,
        privateHostsKey: true,
        longImageTilingKey: true,
        openCodeFetchedAtKey: 999,
        openCodeEtagKey: '"v2"',
        normalKey: 'world',
      });

      final stored = await SharedPreferences.getInstance();
      expect(
        stored.getDouble(fontScaleKey),
        1.4,
        reason: 'local-only keys must not be overwritten by sync restore',
      );
      expect(stored.getInt(windowWidthKey), 1200);
      expect(stored.getBool(privateHostsKey), isFalse);
      expect(stored.getBool(longImageTilingKey), isFalse);
      expect(stored.getInt(openCodeFetchedAtKey), 123);
      expect(stored.getString(openCodeEtagKey), '"v1"');
      expect(stored.getString(normalKey), 'world');
    });

    test('restoreSingle ignores local-only keys', () async {
      final prefs = await SharedPreferencesAsync.instance;
      await prefs.restoreSingle(fontScaleKey, 0.8);
      await prefs.restoreSingle(normalKey, 'updated');

      final stored = await SharedPreferences.getInstance();
      expect(stored.getDouble(fontScaleKey), 1.4);
      expect(stored.getString(normalKey), 'updated');
    });
  });
}
