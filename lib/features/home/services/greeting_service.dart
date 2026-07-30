import 'dart:math';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';

/// Service responsible for managing New Chat Page greetings.
/// Provides time-of-day preset greetings and background AI greeting generation.
class GreetingService {
  GreetingService._();

  static bool _isFetching = false;

  static const List<String> _morningGreetings = [
    '早安！準備好開始新的一天了嗎？',
    '早安！今天想聊些什麼呢？',
    '早安！有什麼我可以為您服務的？',
  ];

  static const List<String> _afternoonGreetings = [
    '午安！有什麼想法需要腦力激盪嗎？',
    '午安！今天過得如何？',
    '午安！有什麼問題需要我協助解答嗎？',
  ];

  static const List<String> _eveningGreetings = [
    '晚安！有什麼疑難雜症想和我討論呢？',
    '晚安！今天辛苦了，想聊點什麼？',
    '晚安！隨時準備好幫助您解決問題。',
  ];

  static const List<String> _nightGreetings = [
    '夜深了，還在忙碌嗎？',
    '夜深了，有什麼我可以幫您的呢？',
    '夜深了，需要幫您梳理想法或資料嗎？',
  ];

  /// Returns a time-of-day appropriate preset greeting.
  static String getPresetGreeting({DateTime? time}) {
    final now = time ?? DateTime.now();
    final hour = now.hour;
    final List<String> pool;
    if (hour >= 5 && hour < 12) {
      pool = _morningGreetings;
    } else if (hour >= 12 && hour < 18) {
      pool = _afternoonGreetings;
    } else if (hour >= 18 && hour < 23) {
      pool = _eveningGreetings;
    } else {
      pool = _nightGreetings;
    }
    final rand = Random(now.day * 100 + hour);
    return pool[rand.nextInt(pool.length)];
  }

  static bool _hasFetchedThisSession = false;

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

      final prompt = settings.greetingPrompt;
      final result = await ChatApiService.generateText(
        config: cfg,
        modelId: modelId,
        prompt: prompt,
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
