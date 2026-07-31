import 'dart:math';
import 'package:flutter/material.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';

/// Service responsible for managing New Chat Page greetings.
/// Provides time-of-day preset greetings and background AI greeting generation.
class GreetingService {
  GreetingService._();

  static bool _isFetching = false;

  // Traditional Chinese (zh_Hant) Greetings
  static const List<String> _morningGreetingsZhHant = [
    '早安！準備好開始新的一天了嗎？',
    '早安！今天想聊些什麼呢？',
    '早安！有什麼我可以為您服務的？',
  ];

  static const List<String> _afternoonGreetingsZhHant = [
    '午安！有什麼想法需要腦力激盪嗎？',
    '午安！今天過得如何？',
    '午安！有什麼問題需要我協助解答嗎？',
  ];

  static const List<String> _eveningGreetingsZhHant = [
    '晚安！有什麼疑難雜症想和我討論呢？',
    '晚安！今天辛苦了，想聊點什麼？',
    '晚安！隨時準備好幫助您解決問題。',
  ];

  static const List<String> _nightGreetingsZhHant = [
    '夜深了，還在忙碌嗎？',
    '夜深了，有什麼我可以幫您的呢？',
    '夜深了，需要幫您梳理想法或資料嗎？',
  ];

  // Simplified Chinese (zh_Hans) Greetings
  static const List<String> _morningGreetingsZhHans = [
    '早上好！准备好开始新的一天了吗？',
    '早上好！今天想聊些什么呢？',
    '早上好！有什么我可以为您服务的？',
  ];

  static const List<String> _afternoonGreetingsZhHans = [
    '下午好！有什么想法需要脑力激荡吗？',
    '下午好！今天过得如何？',
    '下午好！有什么问题需要我协助解答吗？',
  ];

  static const List<String> _eveningGreetingsZhHans = [
    '晚上好！有什么疑难杂症想和我讨论呢？',
    '晚上好！今天辛苦了，想聊点什么？',
    '晚上好！随时准备好帮助您解决问题。',
  ];

  static const List<String> _nightGreetingsZhHans = [
    '夜深了，还在忙碌吗？',
    '夜深了，有什么我可以帮您的呢？',
    '夜深了，需要帮您梳理想法或资料吗？',
  ];

  // English Greetings
  static const List<String> _morningGreetingsEn = [
    'Good morning! Ready to start a new day?',
    'Good morning! What would you like to chat about today?',
    'Good morning! How can I help you today?',
  ];

  static const List<String> _afternoonGreetingsEn = [
    'Good afternoon! Have any ideas you would like to brainstorm?',
    'Good afternoon! How is your day going?',
    'Good afternoon! Is there anything I can assist you with?',
  ];

  static const List<String> _eveningGreetingsEn = [
    'Good evening! What would you like to discuss tonight?',
    'Good evening! Hope you had a great day. What is on your mind?',
    'Good evening! Ready whenever you are.',
  ];

  static const List<String> _nightGreetingsEn = [
    "It's getting late, still working hard?",
    'Late night! Need a hand with anything?',
    'Late night! Let me know if you need help organizing thoughts or data.',
  ];

  /// Returns a time-of-day appropriate preset greeting for given locale or languageCode.
  static String getPresetGreeting({DateTime? time, Locale? locale, String? languageCode}) {
    final now = time ?? DateTime.now();
    final hour = now.hour;

    final lang = languageCode ?? locale?.languageCode ?? 'zh';
    final script = locale?.scriptCode ?? '';
    final country = locale?.countryCode ?? '';
    final isZhHant = lang == 'zh' && (script == 'Hant' || country == 'TW' || country == 'HK');
    final isEn = lang == 'en';

    final List<String> pool;
    if (hour >= 5 && hour < 12) {
      pool = isEn ? _morningGreetingsEn : (isZhHant ? _morningGreetingsZhHant : _morningGreetingsZhHans);
    } else if (hour >= 12 && hour < 18) {
      pool = isEn ? _afternoonGreetingsEn : (isZhHant ? _afternoonGreetingsZhHant : _afternoonGreetingsZhHans);
    } else if (hour >= 18 && hour < 23) {
      pool = isEn ? _eveningGreetingsEn : (isZhHant ? _eveningGreetingsZhHant : _eveningGreetingsZhHans);
    } else {
      pool = isEn ? _nightGreetingsEn : (isZhHant ? _nightGreetingsZhHant : _nightGreetingsZhHans);
    }
    final rand = Random(now.day * 100 + hour);
    return pool[rand.nextInt(pool.length)];
  }

  static bool _hasFetchedThisSession = false;

  /// Resets session fetch state (useful when settings or language changes).
  static void resetSessionFetch() {
    _hasFetchedThisSession = false;
  }

  /// Triggers background fetching of AI greeting if configured.
  /// Generates once per App launch session unless [force] is true.
  static Future<void> fetchAiGreetingInBackground(SettingsProvider settings, {bool force = false}) async {
    if (settings.newChatTextType != 'aiGreeting') return;
    if (!force && _hasFetchedThisSession) return;
    if (_isFetching) return;

    _isFetching = true;

    try {
      final providerKey = settings.greetingModelProvider ?? settings.currentModelProvider;
      final modelId = settings.greetingModelId ?? settings.currentModelId;

      if (providerKey == null || modelId == null) return;
      final cfg = settings.getProviderConfig(providerKey);
      if (!cfg.enabled) return;

      final prompt = settings.getGreetingPromptForLocale(settings.appLocale);
      final result = await ChatApiService.generateText(
        config: cfg,
        modelId: modelId,
        prompt: prompt,
        thinkingBudget: settings.greetingGenerationThinkingBudgetFor(),
      ).timeout(const Duration(seconds: 12));

      var text = result.trim();
      text = text.replaceAll(RegExp(r'''^["'「』『」“”]+|["'「』『」“”]+$'''), '').trim();
      text = text.replaceAll('\n', ' ').trim();
      if (text.isNotEmpty) {
        await settings.setNewChatCachedAiGreeting(text);
        _hasFetchedThisSession = true;
      }
    } catch (_) {
      // Fallback or background error silently ignored
    } finally {
      _isFetching = false;
    }
  }
}
