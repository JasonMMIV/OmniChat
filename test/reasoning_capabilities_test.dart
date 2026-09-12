import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/utils/reasoning_capabilities.dart';

void main() {
  group('ReasoningBudget', () {
    test('buckets extended budgets only when supported', () {
      expect(
        ReasoningBudget.bucket(ReasoningBudget.xhigh, allowXhigh: true),
        ReasoningBudget.xhigh,
      );
      expect(
        ReasoningBudget.bucket(
          ReasoningBudget.max,
          allowXhigh: true,
          allowMax: true,
        ),
        ReasoningBudget.max,
      );
      expect(
        ReasoningBudget.bucket(ReasoningBudget.max, allowXhigh: true),
        ReasoningBudget.xhigh,
      );
    });
  });

  group('ReasoningCapabilities', () {
    test('normalizes namespaced OpenAI model IDs', () {
      final gpt54 = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'openai/gpt-5.4',
      );
      final gpt56 = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'openai/gpt-5.6',
      );

      expect(gpt54.supportsXhigh, isTrue);
      expect(gpt54.supportsMax, isFalse);
      expect(gpt56.supportsXhigh, isTrue);
      expect(gpt56.supportsMax, isTrue);
    });

    test('supports GPT-5.5 and requires sampling none except for Pro', () {
      final gpt55 = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'openai/gpt-5.5',
      );
      final gpt55Pro = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.5-pro',
      );
      final gpt55Codex = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.5-codex',
      );
      final gpt55Chat = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.5-chat-latest',
      );

      expect(gpt55.supportsXhigh, isTrue);
      expect(gpt55.supportsMax, isFalse);
      expect(gpt55.samplingRequiresNone, isTrue);

      expect(gpt55Pro.supportsXhigh, isTrue);
      expect(gpt55Pro.supportsMax, isFalse);
      expect(gpt55Pro.samplingRequiresNone, isFalse);

      expect(gpt55Codex.supportsXhigh, isFalse);
      expect(gpt55Codex.samplingRequiresNone, isFalse);

      expect(gpt55Chat.supportsXhigh, isFalse);
      expect(gpt55Chat.samplingRequiresNone, isFalse);
    });

    test('normalizes Kimi K3 to its supported effort levels', () {
      final kimi = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'moonshotai/kimi-k3',
      );

      expect(kimi.thinkingAlwaysOn, isTrue);
      expect(kimi.supportsXhigh, isFalse);
      expect(kimi.supportsMax, isTrue);
      expect(kimi.normalizeOpenAiEffort('off'), 'low');
      expect(kimi.normalizeOpenAiEffort('medium'), 'high');
      expect(kimi.normalizeOpenAiEffort('xhigh'), 'high');
      expect(kimi.normalizeOpenAiEffort('max'), 'max');
    });

    test('covers the 2026-09 model wave: DeepSeek v4.1, GLM 5.3, GPT-5.6 Luna, Muse Spark, Gemini 3.8', () {
      // DeepSeek v4.1 Flash: xhigh + max on the OpenAI-compatible transport.
      final dsV4 = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'deepseek-v4.1-flash',
      );
      final dsV3 = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'deepseek-v3.2',
      );

      expect(dsV4.supportsXhigh, isTrue);
      expect(dsV4.supportsMax, isTrue);
      expect(dsV4.openAiEfforts, contains('max'));
      expect(dsV3.supportsXhigh, isTrue);
      expect(dsV3.supportsMax, isFalse);

      // GLM 5.3 / 5.3 Flash: xhigh-class effort, no max.
      final glm53 = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'glm-5.3',
      );
      final glm53Flash = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'glm-5.3-flash',
      );

      expect(glm53.supportsXhigh, isTrue);
      expect(glm53.supportsMax, isFalse);
      expect(glm53Flash.supportsXhigh, isTrue);
      expect(glm53Flash.supportsMax, isFalse);

      // GPT-5.6 Luna: full ladder incl. a real 'none' off-fallback, and it
      // rejects sampling params while reasoning (official docs).
      final luna = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.6-luna',
      );

      expect(luna.supportsXhigh, isTrue);
      expect(luna.supportsMax, isTrue);
      expect(luna.samplingRequiresNone, isTrue);
      expect(luna.normalizeOpenAiEffort('off'), 'none');
      expect(luna.openAiEfforts, containsAll(['none', 'xhigh', 'max']));

      // Other 5.6 variants keep the generic xhigh+max shape.
      final terra = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.6-terra',
      );
      expect(terra.supportsXhigh, isTrue);
      expect(terra.supportsMax, isTrue);
      expect(terra.samplingRequiresNone, isFalse);
      expect(terra.normalizeOpenAiEffort('off'), 'off');

      // Muse Spark (Meta Model API): always reasons, minimal..xhigh,
      // off remaps to 'minimal', max not yet exposed.
      final muse = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'muse-spark-1.3',
      );

      expect(muse.supportsXhigh, isTrue);
      expect(muse.supportsMax, isFalse);
      expect(muse.thinkingAlwaysOn, isTrue);
      expect(muse.normalizeOpenAiEffort('off'), 'minimal');
      expect(muse.normalizeOpenAiEffort('max'), 'xhigh');
      expect(
        muse.openAiEfforts,
        containsAll(['minimal', 'low', 'medium', 'high', 'xhigh']),
      );

      // Gemini 3.8 Flash on the Google transport: thinkingLevel dial with
      // an xhigh-class ceiling (clamps to 'high' on the wire).
      final gemini38 = ReasoningCapabilities.forModel(
        ReasoningTransport.google,
        'gemini-3.8-flash',
      );

      expect(gemini38.supportsXhigh, isTrue);
      expect(gemini38.supportsMax, isFalse);

      // Gemini 2.x stays unsupported (no thinkingLevel dial).
      final gemini25 = ReasoningCapabilities.forModel(
        ReasoningTransport.google,
        'gemini-2.5-flash',
      );
      expect(gemini25.supportsXhigh, isFalse);
    });

    test('keeps unsupported future OpenAI models conservative', () {
      final capabilities = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'openai/gpt-5.7',
      );

      expect(capabilities.supportsXhigh, isFalse);
      expect(capabilities.supportsMax, isFalse);
    });

    test('maps Claude model families to their verified effort levels', () {
      final opus = ReasoningCapabilities.forModel(
        ReasoningTransport.claude,
        'anthropic/claude-opus-4.8',
      );
      final sonnet = ReasoningCapabilities.forModel(
        ReasoningTransport.claude,
        'claude-sonnet-4-6',
      );
      final old = ReasoningCapabilities.forModel(
        ReasoningTransport.claude,
        'claude-sonnet-4-5',
      );

      expect(opus.supportsXhigh, isTrue);
      expect(opus.supportsMax, isTrue);
      expect(sonnet.supportsXhigh, isFalse);
      expect(sonnet.supportsMax, isTrue);
      expect(old.supportsXhigh, isFalse);
      expect(old.supportsMax, isFalse);
    });

    test('keeps always-on Claude models adaptive', () {
      final capabilities = ReasoningCapabilities.forModel(
        ReasoningTransport.claude,
        'claude-fable-5',
      );

      expect(capabilities.supportsXhigh, isTrue);
      expect(capabilities.supportsMax, isTrue);
      expect(capabilities.supportsAdaptiveThinking, isTrue);
      expect(capabilities.thinkingAlwaysOn, isTrue);
    });
  });
}
