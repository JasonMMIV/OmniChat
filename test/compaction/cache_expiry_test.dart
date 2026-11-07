// P1-2 tail (`cache_expiry`): an idle successful request means the provider's
// prompt cache is cold, so compaction may skip the token trigger threshold —
// but it still respects the 140k floor and the normal boundary walk.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/services/agent/compaction/compaction_trigger.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';

const String _catalogFixture = '''
{
  "anthropic": {
    "models": {
      "claude-sonnet-4-5": {
        "limit": {"context": 200000, "output": 64000}
      }
    }
  }
}
''';

void main() {
  setUp(() => ModelCatalog.loadFromJsonString(_catalogFixture));
  tearDown(ModelCatalog.debugReset);

  ChatMessage msg(
    String role,
    String content, {
    String? id,
    int? promptTokens,
    DateTime? timestamp,
    bool isStreaming = false,
  }) {
    return ChatMessage(
      id: id ?? 'm-$role-${content.hashCode}',
      role: role,
      content: content,
      conversationId: 'c1',
      promptTokens: promptTokens,
      timestamp: timestamp,
      isStreaming: isStreaming,
    );
  }

  final t = DateTime.utc(2026, 11, 6, 12);
  final messages = <ChatMessage>[
    msg('user', 'first'),
    msg('assistant', 'completed', promptTokens: 150_000, timestamp: t),
    msg('user', 'live'),
  ];

  group('latestSuccessfulRequestAt', () {
    test('uses the latest assistant message carrying usage', () {
      final later = t.add(const Duration(minutes: 5));
      final result = latestSuccessfulRequestAt(<ChatMessage>[
        ...messages,
        msg(
          'assistant',
          'later success',
          promptTokens: 151_000,
          timestamp: later,
        ),
      ]);
      expect(result, later);
    });

    test('ignores a later failed/retry message without usage', () {
      final result = latestSuccessfulRequestAt(<ChatMessage>[
        ...messages,
        msg(
          'assistant',
          'interrupted',
          timestamp: t.add(const Duration(minutes: 1)),
        ),
      ]);
      expect(result, t);
    });

    test('ignores the live streaming placeholder', () {
      final result = latestSuccessfulRequestAt(<ChatMessage>[
        ...messages,
        msg(
          'assistant',
          'streaming',
          isStreaming: true,
          timestamp: t.add(const Duration(minutes: 2)),
        ),
      ]);
      expect(result, t);
    });
  });

  group('cache-expiry trigger', () {
    CompactionTriggerResult evaluate({
      required DateTime now,
      int promptTokens = 150_000,
      String modelId = 'unknown-model-xyz',
    }) {
      return evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: promptTokens,
        modelId: modelId,
        learnedWindowTokens: null,
        lastSuccessfulRequestAt: t,
        now: now,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
    }

    test('29m59s idle stays below the token trigger', () {
      final result = evaluate(
        now: t.add(const Duration(minutes: 29, seconds: 59)),
      );
      expect(result.overTrigger, isFalse);
      expect(result.boundaryIndex, -1);
    });

    test('exactly 30 minutes idle triggers (>= boundary)', () {
      final result = evaluate(now: t.add(cacheExpiryIdleThreshold));
      expect(result.overTrigger, isTrue);
      expect(result.boundaryIndex, greaterThan(0));
    });

    test(
      '30m01s idle bypasses the token trigger but keeps a safe boundary',
      () {
        final result = evaluate(
          now: t.add(const Duration(minutes: 30, seconds: 1)),
        );
        expect(result.overTrigger, isTrue);
        expect(result.boundaryIndex, greaterThan(0));
        expect(result.boundaryIndex, lessThan(messages.length));
      },
    );

    test('the 140k floor still wins over cache expiry', () {
      final result = evaluate(
        now: t.add(const Duration(hours: 2)),
        promptTokens: compactionFloorTokens - 1,
      );
      expect(result.overTrigger, isFalse);
      expect(result.boundaryIndex, -1);
    });

    test('the normal token trigger still fires without idle time', () {
      final result = evaluate(
        now: t.add(const Duration(minutes: 1)),
        promptTokens: 200_000,
        modelId: 'claude-sonnet-4-5',
      );
      expect(result.overTrigger, isTrue);
    });

    test('clock skew into the future does not look idle', () {
      final result = evaluateCompactionTrigger(
        messages: messages,
        measuredPromptTokens: 150_000,
        modelId: 'unknown-model-xyz',
        learnedWindowTokens: null,
        lastSuccessfulRequestAt: t.add(const Duration(minutes: 1)),
        now: t,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
      );
      expect(result.overTrigger, isFalse);
    });
  });

  group('evaluatePrepTimeCompaction', () {
    test('derives the 31-minute anchor from the message list', () {
      final result = evaluatePrepTimeCompaction(
        messages: messages,
        measuredPromptTokens: 150_000,
        modelId: 'unknown-model-xyz',
        learnedWindowTokens: null,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
        now: t.add(const Duration(minutes: 31)),
      );
      expect(result.overTrigger, isTrue);
    });

    test('29 minutes stays below the token trigger', () {
      final result = evaluatePrepTimeCompaction(
        messages: messages,
        measuredPromptTokens: 150_000,
        modelId: 'unknown-model-xyz',
        learnedWindowTokens: null,
        estimateMessageTokens: (_) => 1,
        hasToolEvents: (_) => false,
        now: t.add(const Duration(minutes: 29)),
      );
      expect(result.overTrigger, isFalse);
    });
  });
}
