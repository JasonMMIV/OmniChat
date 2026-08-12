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
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('imageAspectRatio defaults to 1:1', () async {
    final sp = await _loadedProvider();
    expect(sp.imageAspectRatio, '1:1');
  });

  test('imageAspectRatio round-trips through SharedPreferences', () async {
    final sp = await _loadedProvider();
    await sp.setImageAspectRatio('16:9');
    expect(sp.imageAspectRatio, '16:9');

    // 重開 provider 後仍讀回持久化值
    final sp2 = await _loadedProvider();
    expect(sp2.imageAspectRatio, '16:9');
  });

  test('imageAspectRatio setter notifies listeners', () async {
    final sp = await _loadedProvider();
    var notified = false;
    void listener() => notified = true;
    sp.addListener(listener);
    await sp.setImageAspectRatio('9:16');
    expect(notified, isTrue);
    sp.removeListener(listener);
  });
}
