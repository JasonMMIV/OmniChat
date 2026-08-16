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
