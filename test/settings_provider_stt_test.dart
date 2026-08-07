import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/stt/network_stt.dart';

/// 建立已載入完成的真實 SettingsProvider（_load 完成後會 notifyListeners）。
/// 呼叫前必須已 `SharedPreferences.setMockInitialValues`（由 setUp 處理，
/// 避免每次建立時重設 mock 而抹掉先前寫入的值）。
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

OpenAiWhisperSttOptions _openAi({String? id}) => OpenAiWhisperSttOptions(
      id: id,
      enabled: true,
      name: 'Whisper',
      apiKey: 'sk-1',
      baseUrl: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
    );

GroqWhisperSttOptions _groq({String? id}) => GroqWhisperSttOptions(
      id: id,
      enabled: true,
      name: 'Groq',
      apiKey: 'gsk-1',
      baseUrl: 'https://api.groq.com/openai/v1/audio/transcriptions',
      model: 'whisper-large-v3',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stt_services_v1 persists across provider instances', () async {
    final sp = await _loadedProvider();
    expect(sp.sttServices, isEmpty);
    await sp.setSttServices([_openAi(), _groq()]);

    // Recreate the provider with the same prefs and verify round-trip.
    final sp2 = await _loadedProvider();
    expect(sp2.sttServices, hasLength(2));
    expect(sp2.sttServices[0], isA<OpenAiWhisperSttOptions>());
    expect(sp2.sttServices[1], isA<GroqWhisperSttOptions>());
  });

  test('stt_selected_v1 persists and defaults to System STT', () async {
    final sp = await _loadedProvider();
    expect(sp.usingSystemStt, isTrue);
    await sp.setSttServices([_openAi(), _groq()]);
    await sp.setSttServiceSelected(1);

    final sp2 = await _loadedProvider();
    expect(sp2.sttServices, hasLength(2));
    expect(sp2.sttServiceSelected, 1);
    expect(sp2.usingSystemStt, isFalse);
  });

  test('out-of-range selection converges when services are deleted', () async {
    final sp = await _loadedProvider();
    final a = _openAi(id: 'a');
    final b = _groq(id: 'b');
    await sp.setSttServices([a, b]);
    await sp.setSttServiceSelected(1); // select Groq

    // Delete the selected service (index 1)
    final remaining = List<SttServiceOptions>.from(sp.sttServices)..removeAt(1);
    await sp.setSttServices(remaining);

    expect(sp.sttServices, hasLength(1));
    // Selection out of range → converge to the last valid index.
    expect(sp.sttServiceSelected, 0);
    expect(sp.usingSystemStt, isFalse);

    // Deleting the last service returns to System STT.
    await sp.setSttServices(const []);
    expect(sp.sttServiceSelected, -1);
    expect(sp.usingSystemStt, isTrue);
  });

  test('stt_system_locale_v1 round-trips and clearing returns to auto', () async {
    final sp = await _loadedProvider();
    expect(sp.sttSystemLocaleId, isNull);

    await sp.setSttSystemLocaleId('zh_TW');
    expect(sp.sttSystemLocaleId, 'zh_TW');

    final sp2 = await _loadedProvider();
    expect(sp2.sttSystemLocaleId, 'zh_TW');

    await sp2.setSttSystemLocaleId(null);
    expect(sp2.sttSystemLocaleId, isNull);

    final sp3 = await _loadedProvider();
    expect(sp3.sttSystemLocaleId, isNull);
  });

  test('selectedSttService resolves only within range', () async {
    final sp = await _loadedProvider();
    expect(sp.selectedSttService, isNull);

    await sp.setSttServices([_openAi()]);
    await sp.setSttServiceSelected(0);
    expect(sp.selectedSttService, isA<OpenAiWhisperSttOptions>());
  });
}
