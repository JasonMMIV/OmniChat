// Regression coverage for the new-chat greeting language.
//
// The greeting prompt is chosen from the *effective* app locale. When the app
// follows the system language, `appLocale` used to fall back to en_US while
// the UI was Chinese, so Gemini received the English default prompt and the
// greeting came back in English even though the settings sheet showed the
// Traditional Chinese prompt.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';

const String _appLocaleKey = 'app_locale_v1';
const String _greetingModelKey = 'greeting_model_v1';
const String _cachedGreetingKey = 'new_chat_cached_ai_greeting_v1';
const String _cachedGreetingLocaleKey = 'new_chat_cached_ai_greeting_locale_v1';

Future<SettingsProvider> _loadedProvider() async {
  final settings = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  settings.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  settings.removeListener(listener);
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'following a Traditional Chinese system uses the zh-Hant prompt',
    (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
      SharedPreferences.setMockInitialValues({});

      final settings = await _loadedProvider();

      expect(settings.isFollowingSystemLocale, isTrue);
      expect(settings.appLocale.scriptCode, 'Hant');
      expect(
        settings.getGreetingPromptForLocale(settings.appLocale),
        SettingsProvider.defaultGreetingPromptZhHant,
      );
    },
  );

  test('an explicit zh_Hant app language uses the zh-Hant prompt', () async {
    SharedPreferences.setMockInitialValues({_appLocaleKey: 'zh_Hant'});

    final settings = await _loadedProvider();

    expect(settings.appLocale.scriptCode, 'Hant');
    expect(
      settings.getGreetingPromptForLocale(settings.appLocale),
      SettingsProvider.defaultGreetingPromptZhHant,
    );
  });

  test('an explicit en_US app language uses the English prompt', () async {
    SharedPreferences.setMockInitialValues({_appLocaleKey: 'en_US'});

    final settings = await _loadedProvider();

    expect(
      settings.getGreetingPromptForLocale(settings.appLocale),
      SettingsProvider.defaultGreetingPromptEn,
    );
  });

  test('a cached greeting for the current language is kept', () async {
    SharedPreferences.setMockInitialValues({
      _appLocaleKey: 'zh_Hant',
      _cachedGreetingKey: '你好！今天想聊什麼？',
      _cachedGreetingLocaleKey: 'zh_Hant',
    });

    final settings = await _loadedProvider();

    expect(settings.newChatCachedAiGreeting, '你好！今天想聊什麼？');
  });

  test('a cached greeting for another language is dropped', () async {
    SharedPreferences.setMockInitialValues({
      _appLocaleKey: 'zh_Hant',
      _cachedGreetingKey: 'Hi there! How can I help you today?',
      _cachedGreetingLocaleKey: 'en_US',
    });

    final settings = await _loadedProvider();

    expect(settings.newChatCachedAiGreeting, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_cachedGreetingKey), isNull);
  });

  test('an untagged legacy greeting is treated as stale', () async {
    SharedPreferences.setMockInitialValues({
      _appLocaleKey: 'zh_Hant',
      _cachedGreetingKey: 'Hi there! How can I help you today?',
    });

    final settings = await _loadedProvider();

    expect(settings.newChatCachedAiGreeting, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_cachedGreetingKey), isNull);
  });

  test('changing the app language removes the persisted greeting', () async {
    SharedPreferences.setMockInitialValues({
      _appLocaleKey: 'en_US',
      _cachedGreetingKey: 'Hi there! How can I help you today?',
      _cachedGreetingLocaleKey: 'en_US',
    });

    final settings = await _loadedProvider();
    expect(settings.newChatCachedAiGreeting, isNotEmpty);

    await settings.setAppLocale(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );

    expect(settings.newChatCachedAiGreeting, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_cachedGreetingKey), isNull);
    expect(prefs.getString(_cachedGreetingLocaleKey), isNull);

    final reloaded = await _loadedProvider();
    expect(reloaded.newChatCachedAiGreeting, isNull);
  });

  test('changing the greeting model removes the persisted greeting', () async {
    SharedPreferences.setMockInitialValues({
      _appLocaleKey: 'en_US',
      _cachedGreetingKey: 'Hi there! How can I help you today?',
      _cachedGreetingLocaleKey: 'en_US',
    });

    final settings = await _loadedProvider();

    await settings.setGreetingModel('Gemini', 'gemini-3.5-flash-lite');

    expect(settings.newChatCachedAiGreeting, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_cachedGreetingKey), isNull);
    expect(prefs.getString(_cachedGreetingLocaleKey), isNull);
    expect(prefs.getString(_greetingModelKey), 'Gemini::gemini-3.5-flash-lite');
  });
}
