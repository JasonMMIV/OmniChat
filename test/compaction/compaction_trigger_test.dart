// P1-2 worked examples for the trigger formula (plan §4 P1-2, AnyBuff v2):
//   reserve(W, out) = clamp(max(0.12W, min(out, 64k)), 8k, 0.5W)
//   trigger(W)      = min(0.7W, W - reserve(W, out))
// Locked by the plan: Claude 200k/64k → 136k, GPT-5.x input 272k/128k →
// 190.4k, W=32k/out=32k → 16k (0.5W guard), unknown W → 1M → 700k.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/services/agent/compaction/compaction_trigger.dart';
import 'package:OmniChat/core/services/agent/compaction/context_trim.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';

const String _catalogFixture = '''
{
  "anthropic": {
    "api": "https://api.anthropic.com/v1",
    "models": {
      "claude-sonnet-4-5": {
        "limit": {"context": 200000, "output": 64000},
        "reasoning": true
      }
    }
  },
  "openai": {
    "models": {
      "gpt-5": {
        "limit": {"context": 400000, "input": 272000, "output": 128000},
        "reasoning": true
      },
      "small-128k": {
        "limit": {"context": 128000, "output": 16384}
      }
    }
  }
}
''';

void main() {
  setUp(() => ModelCatalog.loadFromJsonString(_catalogFixture));
  tearDown(ModelCatalog.debugReset);

  group('reserveTokens / compactionTriggerTokens worked examples', () {
    test('Claude 200k window / 64k output → trigger 136k', () {
      expect(reserveTokens(200_000, 64_000), 64_000);
      expect(compactionTriggerTokens(200_000, 64_000), 136_000);
    });

    test('GPT-5.x input 272k / output 128k → trigger 190.4k', () {
      expect(reserveTokens(272_000, 128_000), 64_000);
      expect(compactionTriggerTokens(272_000, 128_000), 190_400);
    });

    test('W=32k / out=32k → 0.5W guard degrades gracefully to 16k', () {
      expect(reserveTokens(32_000, 32_000), 16_000);
      expect(compactionTriggerTokens(32_000, 32_000), 16_000);
    });

    test('unknown window fallback 1M → trigger 700k', () {
      expect(
        compactionTriggerTokens(unknownModelContextFallback, null),
        700_000,
      );
    });

    test('output reserve is capped at 64k', () {
      // kimi-k2.6 declares 262k output; the reserve must not swallow the
      // whole trigger.
      expect(reserveTokens(262_144, 262_144), 64_000);
    });

    test('window precedence: learned → catalog input cap → 1M', () {
      // Catalog hit, input cap preferred over the total context.
      expect(resolveContextWindowTokens('gpt-5'), 272_000);
      expect(resolveContextWindowTokens('claude-sonnet-4-5'), 200_000);
      // Learned windows are endpoint facts and always win.
      expect(resolveContextWindowTokens('claude-sonnet-4-5', learned: 150_000),
          150_000);
      // Catalog miss keeps the optimistic 1M fallback.
      expect(
        resolveContextWindowTokens('totally-unknown-model'),
        unknownModelContextFallback,
      );
    });

    test('user override wins over learned and catalog', () {
      expect(
        resolveContextWindowTokens(
          'claude-sonnet-4-5',
          userOverride: 123_456,
          learned: 150_000,
        ),
        123_456,
      );
      // A user override also fills in for a catalog miss.
      expect(
        resolveContextWindowTokens(
          'totally-unknown-model',
          userOverride: 64_000,
        ),
        64_000,
      );
      // Non-positive values are ignored (fall through the chain).
      expect(
        resolveContextWindowTokens(
          'claude-sonnet-4-5',
          userOverride: 0,
          learned: 150_000,
        ),
        150_000,
      );
    });
  });

  ChatMessage msg(
    String role,
    String content, {
    String? id,
    String? groupId,
    int? promptTokens,
  }) {
    return ChatMessage(
      id: id ?? 'm-${role}-${content.hashCode}',
      role: role,
      content: content,
      conversationId: 'c1',
      groupId: groupId,
      version: 0,
      promptTokens: promptTokens,
    );
  }

  group('evaluateCompactionTrigger', () {
    test('below the trigger threshold → no compaction', () {
      final messages = [
        msg('user', 'hi'),
        msg('assistant', 'hello', promptTokens: 100_000),
        msg('user', 'next'),
      ];
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 100_000,
        modelId: 'claude-sonnet-4-5',
        learnedWindowTokens: null,
        estimateMessageTokens: (m) => m.content.length,
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isFalse);
      expect(result.boundaryIndex, -1);
    });

    test('GPT-5 input 272k uses the 190.4k trigger, not 0.7 × 400k', () {
      final messages = [
        msg('user', 'hi'),
        msg('assistant', 'hello', promptTokens: 200_000),
        msg('user', 'next'),
      ];
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 200_000,
        modelId: 'gpt-5',
        learnedWindowTokens: null,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isTrue);
    });

    test('user context window overrides the catalog window', () {
      final messages = [
        msg('user', 'hi'),
        msg('assistant', 'hello', promptTokens: 150_000),
        msg('user', 'next'),
      ];
      // Catalog: gpt-5 input cap 272k / output 128k → trigger 190.4k →
      // 150k passes (and clears the 140k floor).
      final withoutUser = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 150_000,
        modelId: 'gpt-5',
        learnedWindowTokens: null,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(withoutUser.overTrigger, isFalse);
      // User window 200k / same output 128k → trigger 136k → 150k compacts.
      final withUser = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 150_000,
        modelId: 'gpt-5',
        learnedWindowTokens: null,
        userContextWindow: 200_000,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(withUser.overTrigger, isTrue);
    });

    test('user max output shrinks the reserve and delays the trigger', () {
      final messages = [
        msg('user', 'hi'),
        msg('assistant', 'hello', promptTokens: 140_000),
        msg('user', 'next'),
      ];
      // Catalog output 64k → reserve 64k → trigger 136k → 140k compacts.
      final withoutUser = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 140_000,
        modelId: 'claude-sonnet-4-5',
        learnedWindowTokens: null,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(withoutUser.overTrigger, isTrue);
      // User output 1k → reserve max(24k, 1k) = 24k → trigger 140k → no
      // compaction at exactly 140k.
      final withUser = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 140_000,
        modelId: 'claude-sonnet-4-5',
        learnedWindowTokens: null,
        userMaxOutput: 1_000,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(withUser.overTrigger, isFalse);
    });

    test('128k model pre-compacts at its trigger, below the 140k floor', () {
      final messages = [
        msg('user', 'hi'),
        msg('assistant', 'hello', promptTokens: 130_000),
        msg('user', 'next'),
      ];
      // Catalog: 128k window / 16.4k output → trigger 89.6k. The fixed floor
      // must not block small windows (they could never reach 140k).
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 130_000,
        modelId: 'small-128k',
        learnedWindowTokens: null,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isTrue);
      expect(result.boundaryIndex, greaterThan(0));

      // Below its own trigger the same model still does not compact.
      final below = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 80_000,
        modelId: 'small-128k',
        learnedWindowTokens: null,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(below.overTrigger, isFalse);
    });

    test('user window below the floor uses the user trigger', () {
      final messages = [
        msg('user', 'hi'),
        msg('assistant', 'hello', promptTokens: 50_000),
        msg('user', 'next'),
      ];
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 50_000,
        modelId: 'unknown-model-xyz',
        learnedWindowTokens: null,
        userContextWindow: 64_000,
        userMaxOutput: 4_000,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      // reserve = 8k → trigger 44.8k → 50k compacts.
      expect(result.overTrigger, isTrue);
    });

    test('measured usage under the trigger → no compaction', () {
      final messages = [
        msg('user', 'hi'),
        msg('assistant', 'hello', promptTokens: 150_000),
        msg('user', 'next'),
      ];
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 150_000,
        // Unknown model → 1M window → trigger 700k; 150k passes the 140k
        // floor but stays under the trigger.
        modelId: 'unknown-model-xyz',
        learnedWindowTokens: null,
        estimateMessageTokens: (m) => m.content.length,
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isFalse);
    });

    test('over the trigger → boundary keeps the previous turn verbatim', () {
      // Realistic prep-time shape: alternating turns, the live user prompt
      // is the newest message, and the measured usage sits on the previous
      // turn's assistant message.
      final messages = <ChatMessage>[];
      for (var i = 0; i < 24; i++) {
        messages.add(msg('user', 'u$i${'x' * 20000}'));
        messages.add(
          msg('assistant', 'a$i',
              promptTokens: i == 23 ? 160_000 : null),
        );
      }
      messages.add(msg('user', 'live'));
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 160_000,
        modelId: 'claude-sonnet-4-5',
        learnedWindowTokens: null,
        estimateMessageTokens: (m) => (m.content.length / charsPerToken).ceil(),
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isTrue);
      expect(result.boundaryIndex, greaterThan(0));
      // The live user prompt is never compacted.
      expect(messages.last.role, 'user');
      expect(result.boundaryIndex, lessThan(messages.length));
      expect(messages[result.boundaryIndex].content, startsWith('a23'));
      // The walk stops at the previous user prompt: the tail is exactly the
      // last turn's assistant reply + the live prompt.
      expect(messages.length - result.boundaryIndex, 2);
    });

    test('tail budget stops the walk: boundary lands within budget of tail', () {
      final messages = <ChatMessage>[
        for (var i = 0; i < 40; i++) ...[
          msg('user', 'u$i'),
          msg('assistant', 'm$i${'y' * 30000}',
              promptTokens: i == 39 ? 200_000 : null),
        ],
        msg('user', 'live'),
      ];
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 200_000,
        modelId: 'claude-sonnet-4-5',
        learnedWindowTokens: null,
        estimateMessageTokens: (m) => (m.content.length / charsPerToken).ceil(),
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isTrue);
      final tail = messages.sublist(result.boundaryIndex);
      final tailTokens = tail.fold<int>(
          0, (sum, m) => sum + (m.content.length / charsPerToken).ceil());
      // Tail ≈ one 10k-token assistant message + the live prompt; never the
      // whole history.
      expect(tailTokens, lessThanOrEqualTo(10_000 + 3001 + 1));
      expect(tailTokens, greaterThan(0));
      expect(tail.last.role, 'user');
    });

    test('tailMaxPairs caps tool-bearing assistant rounds', () {
      // One user prompt followed by many tool-bearing assistant messages
      // (multi-round agent turn), then the live user prompt.
      final messages = <ChatMessage>[
        msg('user', 'root'),
        for (var i = 0; i < 30; i++)
          msg('assistant', 'work$i',
              id: 'a$i', promptTokens: i == 29 ? 300_000 : null),
        msg('user', 'live'),
      ];
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 900_000,
        modelId: 'unknown-model-xyz', // trigger 700k
        learnedWindowTokens: null,
        estimateMessageTokens: (m) => 100,
        hasToolEvents: (_) => true,
      );
      expect(result.overTrigger, isTrue);
      final tail = messages.sublist(result.boundaryIndex);
      final toolAssistants = tail.where((m) => m.role == 'assistant').length;
      expect(toolAssistants, tailMaxPairs);
    });

    test('boundary snaps back to a version-group start', () {
      final messages = <ChatMessage>[
        msg('user', 'root'),
        // Two versions of the same reply: the boundary must not split them.
        msg('assistant', 'v0', id: 'a1', groupId: 'g1'),
        msg('assistant', 'v1', id: 'a2', groupId: 'g1'),
        msg('user', 'live', promptTokens: null),
        msg('assistant', 'done', promptTokens: 999_000),
      ];
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 999_000,
        modelId: 'claude-sonnet-4-5',
        learnedWindowTokens: null,
        estimateMessageTokens: (m) => (m.content.length / charsPerToken).ceil(),
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isTrue);
      if (result.boundaryIndex < messages.length) {
        // The boundary message starts its group: no earlier message shares
        // its groupId.
        final boundaryMsg = messages[result.boundaryIndex];
        final gid = boundaryMsg.groupId ?? boundaryMsg.id;
        for (var i = 0; i < result.boundaryIndex; i++) {
          final m = messages[i];
          expect(m.groupId ?? m.id, isNot(gid));
        }
      }
    });
  });
}
