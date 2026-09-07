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

void main() {
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

    test('seed table lookup order: specific ids before family rules', () {
      expect(seedWindowForModel('gpt-5.2-chat-latest')!.windowTokens, 128_000);
      expect(seedWindowForModel('gpt-5.2')!.windowTokens, 272_000);
      expect(seedWindowForModel('gpt-5')!.windowTokens, 272_000);
      expect(seedWindowForModel('claude-sonnet-4-5-20250929')!.windowTokens,
          200_000);
      expect(seedWindowForModel('kimi-k2.6')!.windowTokens, 262_144);
      expect(seedWindowForModel('minimax-m2.7')!.windowTokens, 204_800);
      expect(seedWindowForModel('glm-5.1')!.windowTokens, 200_000);
      expect(seedWindowForModel('totally-unknown-model'), isNull);
      expect(
        resolveContextWindowTokens('totally-unknown-model'),
        unknownModelContextFallback,
      );
      // Learned windows win over the seed table.
      expect(resolveContextWindowTokens('claude-sonnet-4-5', learned: 150_000),
          150_000);
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
    test('below the 140k floor → no compaction', () {
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
