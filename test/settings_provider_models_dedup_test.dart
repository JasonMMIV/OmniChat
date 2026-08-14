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

ProviderConfig _cfg(List<String> models) => ProviderConfig(
  id: 'openai',
  enabled: true,
  name: 'OpenAI',
  apiKey: 'sk-test',
  baseUrl: 'https://api.openai.com/v1',
  models: models,
);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('uniqueModels preserves first-occurrence order and drops duplicates',
      () {
    expect(ProviderConfig.uniqueModels(['a', 'b', 'a', 'c', 'b']), [
      'a',
      'b',
      'c',
    ]);
    expect(ProviderConfig.uniqueModels([]), isEmpty);
    expect(ProviderConfig.uniqueModels(['x', 'y']), ['x', 'y']);
  });

  test('fromJson deduplicates persisted models', () {
    final cfg = ProviderConfig.fromJson({
      'id': 'openai',
      'enabled': true,
      'name': 'OpenAI',
      'apiKey': 'sk-test',
      'baseUrl': 'https://api.openai.com/v1',
      'models': ['gpt-4o', 'gpt-4o', 'gpt-4o-mini', 'gpt-4o'],
    });
    expect(cfg.models, ['gpt-4o', 'gpt-4o-mini']);
  });

  test('copyWith deduplicates explicit and existing models', () {
    final base = _cfg(['a', 'a', 'b']);

    // No-arg copyWith normalizes already-present duplicates.
    expect(base.copyWith().models, ['a', 'b']);
    // Explicit models are deduplicated too.
    expect(base.copyWith(models: ['x', 'x', 'y']).models, ['x', 'y']);
    // Explicit empty list stays empty.
    expect(base.copyWith(models: []).models, isEmpty);
    // Unrelated fields untouched.
    expect(base.copyWith(enabled: false).enabled, isFalse);
  });

  test('setProviderConfig stores and reloads deduplicated models', () async {
    final sp = await _loadedProvider();
    await sp.setProviderConfig('openai', _cfg(['a', 'a', 'b']));
    expect(sp.getProviderConfig('openai').models, ['a', 'b']);

    // Persisted JSON round-trips through fromJson (also deduped).
    final sp2 = await _loadedProvider();
    expect(sp2.getProviderConfig('openai').models, ['a', 'b']);
  });
}
