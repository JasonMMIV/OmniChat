// SettingsProvider test: the stored chat-input button order/hidden lists
// migrate `mcp` → `addons` in place (2026-11-10 Add-ons reorganization, when
// the MCP servers button grew into the Add-ons menu).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider chat-input button id migration', () {
    testWidgets('stored mcp entries become addons and persist', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues(<String, Object>{
        'chat_input_button_order_v1': <String>['model', 'mcp', 'search'],
        'chat_input_button_hidden_v1': <String>['mcp'],
      });

      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      expect(settings.chatInputButtonOrder, ['model', 'addons', 'search']);
      expect(settings.chatInputButtonHidden, ['addons']);

      // The migration is persisted so it does not re-run on every launch.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('chat_input_button_order_v1'), [
        'model',
        'addons',
        'search',
      ]);
      expect(prefs.getStringList('chat_input_button_hidden_v1'), ['addons']);
    });

    testWidgets('lists without legacy ids are left untouched', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues(<String, Object>{
        'chat_input_button_order_v1': <String>['ocr', 'voice'],
      });

      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      expect(settings.chatInputButtonOrder, ['ocr', 'voice']);
      expect(settings.chatInputButtonHidden, isEmpty);
    });
  });
}
