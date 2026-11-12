import 'dart:async';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('send_tool_images_v1 defaults on and survives reload', () async {
    final sp = await _loadedProvider();
    expect(sp.sendToolImages, isTrue);

    await sp.setSendToolImages(false);
    final reloaded = await _loadedProvider();
    expect(reloaded.sendToolImages, isFalse);

    await reloaded.setSendToolImages(true);
    final again = await _loadedProvider();
    expect(again.sendToolImages, isTrue);
  });
}
