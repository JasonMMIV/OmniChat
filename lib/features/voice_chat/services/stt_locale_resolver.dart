import 'dart:ui' show Locale;

import 'package:speech_to_text/speech_to_text.dart';

import '../../../core/providers/settings_provider.dart';

/// Task 2.8：STT locale 解析（含快取）。僅當 appLocale / isFollowingSystemLocale
/// 變更時重新解析。自 voice_chat_screen 搬移（Phase 3 任務 3.3）。
class SttLocaleResolver {
  SttLocaleResolver({required this.speechToText, required this.settings});

  final SpeechToText speechToText;
  final SettingsProvider settings;

  String? _cachedSttLocale;
  Locale? _cachedSttLocaleKey;
  bool? _cachedSttSystemFlag;

  Future<String?> resolve() async {
    final settingsLocale = settings.appLocale;
    final isSystemLocale = settings.isFollowingSystemLocale;

    if (_cachedSttLocale != null &&
        _cachedSttLocaleKey == settingsLocale &&
        _cachedSttSystemFlag == isSystemLocale) {
      return _cachedSttLocale;
    }

    String? selectedLocaleId;
    try {
      final systemLocales = await speechToText.locales();

      if (systemLocales.isNotEmpty) {
        final localeTag =
            '${settingsLocale.languageCode}${settingsLocale.scriptCode != null ? '_${settingsLocale.scriptCode}' : ''}${settingsLocale.countryCode != null ? '_${settingsLocale.countryCode}' : ''}';

        // Normalize app locale to lower case with hyphens for comparison
        // e.g., zh_Hant -> zh-hant, zh_CN -> zh-cn
        final normalizedAppLocale = localeTag.toLowerCase().replaceAll('_', '-');

        // 1. Try exact match (insensitive)
        try {
          selectedLocaleId = systemLocales.firstWhere(
            (l) => l.localeId.toLowerCase().replaceAll('_', '-') == normalizedAppLocale,
          ).localeId;
        } catch (_) {
          // 2. Special mapping for Chinese variants (common issue on Windows)
          if (normalizedAppLocale.startsWith('zh')) {
            if (normalizedAppLocale.contains('hant') ||
                normalizedAppLocale.contains('tw') ||
                normalizedAppLocale.contains('hk')) {
              // Traditional: try TW, HK
              try {
                selectedLocaleId = systemLocales.firstWhere(
                  (l) {
                    final lid = l.localeId.toLowerCase();
                    return lid.contains('zh-tw') ||
                        lid.contains('zh-hk') ||
                        lid.contains('tw') ||
                        lid.contains('hk');
                  },
                ).localeId;
              } catch (_) {
                // If no Traditional, try any Chinese
                try {
                  selectedLocaleId = systemLocales.firstWhere(
                    (l) => l.localeId.toLowerCase().startsWith('zh'),
                  ).localeId;
                } catch (_) {}
              }
            } else {
              // Simplified: try CN first, then any Chinese
              try {
                selectedLocaleId = systemLocales.firstWhere(
                  (l) =>
                      l.localeId.toLowerCase().contains('zh-cn') ||
                      l.localeId.toLowerCase().contains('cn'),
                ).localeId;
              } catch (_) {
                // If no Simplified, try any Chinese
                try {
                  selectedLocaleId = systemLocales.firstWhere(
                    (l) => l.localeId.toLowerCase().startsWith('zh'),
                  ).localeId;
                } catch (_) {}
              }
            }
          }

          // 3. General language match (e.g. en_US -> en_GB if US not found)
          if (selectedLocaleId == null) {
            final appLang = normalizedAppLocale.split('-')[0];
            try {
              selectedLocaleId = systemLocales.firstWhere(
                (l) => l.localeId.toLowerCase().startsWith(appLang),
              ).localeId;
            } catch (_) {}
          }
        }
      }

      // 4. Force fallback if still null (Best Effort)
      // This handles cases where systemLocales list is incomplete (e.g. Windows WinRT restriction)
      // but the language pack is actually installed.
      if (selectedLocaleId == null) {
        final localeTag =
            '${settingsLocale.languageCode}${settingsLocale.scriptCode != null ? '_${settingsLocale.scriptCode}' : ''}${settingsLocale.countryCode != null ? '_${settingsLocale.countryCode}' : ''}';
        final normalizedAppLocale = localeTag.toLowerCase().replaceAll('_', '-');

        if (normalizedAppLocale.contains('zh')) {
          if (normalizedAppLocale.contains('hant') ||
              normalizedAppLocale.contains('tw') ||
              normalizedAppLocale.contains('hk')) {
            selectedLocaleId = 'zh-TW';
          } else {
            selectedLocaleId = 'zh-CN';
          }
        } else {
          // For other languages, use the standard tag (e.g. ja-JP, ko-KR)
          // Best effort: construct a valid BCP-47 tag
          if (settingsLocale.countryCode != null) {
            selectedLocaleId =
                '${settingsLocale.languageCode}-${settingsLocale.countryCode}';
          } else {
            selectedLocaleId = settingsLocale.languageCode;
          }
        }
      }
    } catch (_) {
      // 忽略：解析失敗時走 forced fallback
    }

    _cachedSttLocale = selectedLocaleId;
    _cachedSttLocaleKey = settingsLocale;
    _cachedSttSystemFlag = isSystemLocale;
    return selectedLocaleId;
  }
}
