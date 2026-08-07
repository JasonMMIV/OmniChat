import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/voice_chat/services/stt_locale_resolver.dart';

/// 測試用 Fake：SpeechToText 只覆寫 `locales()`，其餘走 noSuchMethod
/// （沿用 chat_turn_service_test.dart 的 implements + noSuchMethod 模式）。
class FakeSpeechToText implements SpeechToText {
  FakeSpeechToText(this.localesResult);

  List<LocaleName> localesResult;
  bool throwOnLocales = false;

  @override
  Future<List<LocaleName>> locales() async {
    if (throwOnLocales) throw Exception('engine failure');
    return localesResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSettingsProvider implements SettingsProvider {
  FakeSettingsProvider({
    required this.appLocale,
    required this.isFollowingSystemLocale,
    String? systemSttLocaleId,
  }) : _systemSttLocaleId = systemSttLocaleId;

  @override
  final Locale appLocale;
  @override
  final bool isFollowingSystemLocale;

  String? _systemSttLocaleId;

  @override
  String? get sttSystemLocaleId => _systemSttLocaleId;

  set systemSttLocaleId(String? v) => _systemSttLocaleId = v;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SttLocaleResolver.resolve', () {
    test('explicit system STT locale takes priority over auto matching', () async {
      final stt = FakeSpeechToText([LocaleName('zh_TW', 'Chinese (Taiwan)')]);
      final settings = FakeSettingsProvider(
        appLocale: const Locale('en', 'US'),
        isFollowingSystemLocale: true,
        systemSttLocaleId: 'en_US',
      );

      final resolver = SttLocaleResolver(speechToText: stt, settings: settings);
      final locale = await resolver.resolve();

      expect(locale, 'en_US');
    });

    test('explicit override wins over app-language auto matching', () async {
      final stt = FakeSpeechToText([LocaleName('zh_CN', 'Chinese (China)')]);
      final settings = FakeSettingsProvider(
        appLocale: const Locale('zh', 'CN'),
        isFollowingSystemLocale: false,
        systemSttLocaleId: 'ja_JP',
      );

      final resolver = SttLocaleResolver(speechToText: stt, settings: settings);
      final locale = await resolver.resolve();

      expect(locale, 'ja_JP');
    });

    test('auto mode matches the app locale from the system list', () async {
      final stt = FakeSpeechToText([LocaleName('en_US', 'English (US)')]);
      final settings = FakeSettingsProvider(
        appLocale: const Locale('en', 'US'),
        isFollowingSystemLocale: true,
        systemSttLocaleId: null,
      );

      final resolver = SttLocaleResolver(speechToText: stt, settings: settings);
      final locale = await resolver.resolve();

      expect(locale, 'en_US');
    });

    test('cache invalidates when system STT locale changes mid-session', () async {
      final stt = FakeSpeechToText([LocaleName('zh_CN', 'Chinese (China)')]);
      final settings = FakeSettingsProvider(
        appLocale: const Locale('en', 'US'),
        isFollowingSystemLocale: true,
        systemSttLocaleId: null,
      );

      final resolver = SttLocaleResolver(speechToText: stt, settings: settings);
      final first = await resolver.resolve();
      // 自動模式：清單中無 en 語言 → forced fallback 構造標籤
      expect(first, 'en-US');

      // User changes the system STT locale in settings; the same resolver
      // instance must pick up the new value instead of serving the cache.
      settings.systemSttLocaleId = 'zh_CN';
      final second = await resolver.resolve();
      expect(second, 'zh_CN');
    });

    test('empty system locale list falls back to a constructed tag', () async {
      final stt = FakeSpeechToText([]);
      final settings = FakeSettingsProvider(
        appLocale: const Locale('ja', 'JP'),
        isFollowingSystemLocale: false,
        systemSttLocaleId: null,
      );

      final resolver = SttLocaleResolver(speechToText: stt, settings: settings);
      final locale = await resolver.resolve();

      expect(locale, 'ja-JP');
    });

    test('fallback constructs zh-TW for Traditional app locale with empty list',
        () async {
      final stt = FakeSpeechToText([]);
      final settings = FakeSettingsProvider(
        appLocale: const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
        ),
        isFollowingSystemLocale: false,
        systemSttLocaleId: null,
      );

      final resolver = SttLocaleResolver(speechToText: stt, settings: settings);
      final locale = await resolver.resolve();

      expect(locale, 'zh-TW');
    });

    test('locales() exceptions degrade to the fallback tag', () async {
      final stt = FakeSpeechToText([])..throwOnLocales = true;
      final settings = FakeSettingsProvider(
        appLocale: const Locale('en', 'US'),
        isFollowingSystemLocale: true,
        systemSttLocaleId: null,
      );

      final resolver = SttLocaleResolver(speechToText: stt, settings: settings);
      final locale = await resolver.resolve();

      expect(locale, 'en-US');
    });
  });
}
