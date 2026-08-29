import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';

/// 建立已載入完成的真實 SettingsProvider（_load 完成後會 notifyListeners）。
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

  test('replayToolResults defaults to true', () async {
    final sp = await _loadedProvider();
    expect(sp.replayToolResults, isTrue);
  });

  test('setReplayToolResults persists across provider instances', () async {
    final sp = await _loadedProvider();
    expect(sp.replayToolResults, isTrue);

    await sp.setReplayToolResults(false);
    expect(sp.replayToolResults, isFalse);

    // Recreate the provider with the same prefs and verify round-trip.
    final sp2 = await _loadedProvider();
    expect(sp2.replayToolResults, isFalse);

    await sp2.setReplayToolResults(true);
    final sp3 = await _loadedProvider();
    expect(sp3.replayToolResults, isTrue);
  });
}
