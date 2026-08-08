import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';

/// 與 `settings_provider_stt_test.dart` 相同的載入輔助：
/// 等待 SettingsProvider 的 `_load()` 完成（載入完成會 notifyListeners）。
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
  });

  test('voice_call_mode_v1 defaults to standard and round-trips', () async {
    final sp = await _loadedProvider();
    expect(sp.voiceCallMode, VoiceCallMode.standard);
    expect(sp.usingLiveApi, isFalse);

    await sp.setVoiceCallMode(VoiceCallMode.liveApi);
    expect(sp.usingLiveApi, isTrue);

    final sp2 = await _loadedProvider();
    expect(sp2.voiceCallMode, VoiceCallMode.liveApi);
    expect(sp2.usingLiveApi, isTrue);

    await sp2.setVoiceCallMode(VoiceCallMode.standard);
    final sp3 = await _loadedProvider();
    expect(sp3.voiceCallMode, VoiceCallMode.standard);
  });

  test('unknown voice_call_mode_v1 value falls back to standard', () async {
    SharedPreferences.setMockInitialValues({
      'voice_call_mode_v1': 'not-a-mode',
    });
    final sp = await _loadedProvider();
    expect(sp.voiceCallMode, VoiceCallMode.standard);
  });

  test('live_api_base_url_v1 / api_key_v1 round-trip and clear on empty',
      () async {
    final sp = await _loadedProvider();
    expect(sp.liveApiBaseUrl, '');
    expect(sp.liveApiApiKey, '');

    await sp.setLiveApiBaseUrl('wss://example.com/ws');
    await sp.setLiveApiApiKey('AIza-test-key');
    expect(sp.liveApiConfigured, isTrue);

    final sp2 = await _loadedProvider();
    expect(sp2.liveApiBaseUrl, 'wss://example.com/ws');
    expect(sp2.liveApiApiKey, 'AIza-test-key');
    expect(sp2.liveApiConfigured, isTrue);

    await sp2.setLiveApiBaseUrl('   ');
    await sp2.setLiveApiApiKey('');
    final sp3 = await _loadedProvider();
    expect(sp3.liveApiBaseUrl, '');
    expect(sp3.liveApiApiKey, '');
    expect(sp3.liveApiConfigured, isFalse);
  });

  test('live_api_model_v1 / voice_v1 round-trip with defaults', () async {
    final sp = await _loadedProvider();
    expect(sp.liveApiModel, VoiceCallDefaults.defaultModel);
    expect(sp.liveApiVoice, VoiceCallDefaults.defaultVoice);
    expect(sp.resolvedLiveApiBaseUrl, VoiceCallDefaults.officialBaseUrl);

    await sp.setLiveApiModel('gemini-2.0-flash-live-preview');
    await sp.setLiveApiVoice('Puck');

    final sp2 = await _loadedProvider();
    expect(sp2.liveApiModel, 'gemini-2.0-flash-live-preview');
    expect(sp2.liveApiVoice, 'Puck');
  });

  test('resolvedLiveApiBaseUrl falls back to official endpoint when empty',
      () async {
    final sp = await _loadedProvider();
    expect(sp.liveApiBaseUrl, '');
    expect(sp.resolvedLiveApiBaseUrl, VoiceCallDefaults.officialBaseUrl);

    await sp.setLiveApiBaseUrl('wss://custom.example/ws');
    expect(sp.resolvedLiveApiBaseUrl, 'wss://custom.example/ws');
  });

  test('liveApiConfigured requires a non-empty key', () async {
    final sp = await _loadedProvider();
    expect(sp.liveApiConfigured, isFalse);

    await sp.setLiveApiApiKey('  ');
    expect(sp.liveApiConfigured, isFalse);

    await sp.setLiveApiApiKey('AIza-valid');
    expect(sp.liveApiConfigured, isTrue);
  });
}
