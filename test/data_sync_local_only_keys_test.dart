import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart'
    hide SharedPreferencesAsync;

import 'package:OmniChat/core/services/backup/data_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fontScaleKey = 'display_chat_font_scale_v1';
  const windowWidthKey = 'window_width_v1';
  const normalKey = 'some_regular_setting_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues({
      fontScaleKey: 1.4,
      windowWidthKey: 1200,
      normalKey: 'hello',
    });
  });

  group('SharedPreferencesAsync local-only keys', () {
    test('snapshot excludes chat font scale and window state', () async {
      final prefs = await SharedPreferencesAsync.instance;
      final map = await prefs.snapshot();

      expect(map.containsKey(fontScaleKey), isFalse,
          reason: 'chat font scale must stay local to the device');
      expect(map.containsKey(windowWidthKey), isFalse);
      expect(map[normalKey], 'hello');
    });

    test('restore skips local-only keys but applies the rest', () async {
      final prefs = await SharedPreferencesAsync.instance;
      await prefs.restore({
        fontScaleKey: 0.8,
        windowWidthKey: 800,
        normalKey: 'world',
      });

      final stored = await SharedPreferences.getInstance();
      expect(stored.getDouble(fontScaleKey), 1.4,
          reason: 'local-only keys must not be overwritten by sync restore');
      expect(stored.getInt(windowWidthKey), 1200);
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
