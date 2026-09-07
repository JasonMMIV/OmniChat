// R0 context-overflow classifier / window-learning / trim-decision units.
// Rate-limit messages are locked as counter-examples.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/api/context_overflow.dart';
import 'package:OmniChat/core/services/agent/compaction/context_trim.dart';

class FakeHttpError implements Exception {
  final int status;
  final String body;
  FakeHttpError(this.status, this.body);
  @override
  String toString() => 'FakeHttpError(HTTP $status): $body';
}

Map<String, dynamic> user(String c) => {'role': 'user', 'content': c};
Map<String, dynamic> assistant(String c) => {'role': 'assistant', 'content': c};

void main() {
  group('isContextOverflowMessage — positives', () {
    const positives = [
      'Error: 400 {"error":{"code":"context_length_exceeded"}}',
      "This model's maximum context length is 128000 tokens",
      'prompt is too long: 123456 tokens > 100000 maximum',
      'input is too long and must be reduced',
      'too many input tokens',
      'Please reduce the length of the messages',
      'the request exceeds the context window',
    ];
    for (final p in positives) {
      test('"${p.length > 40 ? p.substring(0, 40) : p}…" classifies as overflow', () {
        expect(isContextOverflowMessage(p), isTrue);
      });
    }
  });

  group('isContextOverflowMessage — counter-examples (rate limits etc.)', () {
    const negatives = [
      'Rate limit reached: limit 10000 TPM, please try again in 20s',
      '429 Too Many Requests',
      'Your account has exceeded its billing quota',
      'invalid api key',
      'Internal server error',
    ];
    for (final n in negatives) {
      test('"$n" does NOT classify as overflow', () {
        expect(isContextOverflowMessage(n), isFalse);
      });
    }
  });

  group('isContextOverflowError', () {
    test('400 + marker → true', () {
      final e = FakeHttpError(
          400, '{"error":{"message":"maximum context length is 200000 tokens"}}');
      expect(isContextOverflowError(e), isTrue);
    });

    test('429 + limit wording → false (rate limits are not overflow)', () {
      final e = FakeHttpError(429, 'maximum context length wording even here');
      expect(isContextOverflowError(e), isFalse);
    });

    test('400 without marker → false', () {
      expect(isContextOverflowError(FakeHttpError(400, 'invalid api key')),
          isFalse);
    });
  });

  group('parseLearnedContextWindow', () {
    test('OpenAI phrasing: takes the window (smaller side)', () {
      // "123456 tokens > 100000 maximum" — the request side must not win.
      final w = parseLearnedContextWindow(
        'This model\'s maximum context length is 100000 tokens. However, your '
        'messages resulted in 123456 tokens.',
        130_000,
      );
      expect(w, 100_000);
    });

    test('single number phrasing', () {
      expect(
        parseLearnedContextWindow(
          'context_length_exceeded: maximum context length is 8192 tokens',
          10_000,
        ),
        8192,
      );
    });

    test('rejects windows larger than 1.2× the local estimate', () {
      expect(
        parseLearnedContextWindow(
          'maximum context length is 200000 tokens',
          10_000,
        ),
        isNull,
      );
    });

    test('rejects values outside the 4k–32M band and unrelated numbers', () {
      // Timestamp-like and id-like numbers must not leak in.
      expect(
        parseLearnedContextWindow(
          'request req_2026 was rejected at 20260907 with error 400',
          10_000,
        ),
        isNull,
      );
    });

    test('comma-separated numbers parse', () {
      expect(
        parseLearnedContextWindow(
          'maximum context length is 200,000 tokens',
          210_000,
        ),
        200_000,
      );
    });
  });

  group('planContextOverflowTrim', () {
    test('non-overflow error → null', () {
      final messages = [user('x' * 30_000), assistant('a')];
      expect(
        planContextOverflowTrim(
          error: FakeHttpError(400, 'invalid api key'),
          messages: messages,
          alreadyTrimmed: false,
          statusCode: 400,
          estimateTokens: estimateApiMessagesTokens,
          declaredWindowTokens: 200_000,
        ),
        isNull,
      );
    });

    test('already trimmed once → null (retry exactly once)', () {
      expect(
        planContextOverflowTrim(
          error: FakeHttpError(400, 'maximum context length is 8000 tokens'),
          messages: [user('x' * 30_000), assistant('a')],
          alreadyTrimmed: true,
          statusCode: 400,
          estimateTokens: estimateApiMessagesTokens,
          declaredWindowTokens: 200_000,
        ),
        isNull,
      );
    });

    test('learned window wins and the plan trims below the target', () {
      final messages = [
        user('x' * 30_000),
        user('x' * 30_000),
        assistant('keep me'),
      ];
      final plan = planContextOverflowTrim(
        error: FakeHttpError(400, 'prompt is too long: 21000 tokens > 12000 maximum'),
        messages: messages,
        alreadyTrimmed: false,
        statusCode: 400,
        estimateTokens: estimateApiMessagesTokens,
        declaredWindowTokens: 200_000,
      )!;
      expect(plan.learnedWindowTokens, 12_000);
      expect(plan.windowTokens, 12_000);
      expect(plan.targetTokens, lessThanOrEqualTo(12_000));
      expect(plan.messages.length, lessThan(messages.length));
      expect(estimateApiMessagesTokens(plan.messages),
          lessThan(estimateApiMessagesTokens(messages)));
      // The newest message survives.
      expect(plan.messages.last['content'], 'keep me');
    });

    test('declared window (seed/fallback) used when the message has no digits',
        () {
      final plan = planContextOverflowTrim(
        error: FakeHttpError(400, 'your input is too long, please shorten it'),
        messages: [user('x' * 300_000), user('x' * 300_000), assistant('a')],
        alreadyTrimmed: false,
        statusCode: 400,
        estimateTokens: estimateApiMessagesTokens,
        declaredWindowTokens: 200_000,
      )!;
      expect(plan.learnedWindowTokens, isNull);
      expect(plan.windowTokens, 200_000);
      // reserve(200k, output unknown) = 0.12 × 200k = 24k → target 176k.
      expect(plan.targetTokens, 176_000);
    });

    test('null declared window and no digits → null (no-window)', () {
      expect(
        planContextOverflowTrim(
          error: FakeHttpError(400, 'your input is too long'),
          messages: [user('x' * 30_000)],
          alreadyTrimmed: false,
          statusCode: 400,
          estimateTokens: estimateApiMessagesTokens,
          declaredWindowTokens: null,
        ),
        isNull,
      );
    });
  });
}
