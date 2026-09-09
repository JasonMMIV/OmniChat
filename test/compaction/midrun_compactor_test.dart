// P1-2 mid-run compaction (IMPORT_PLAN_COWORK.md P1-2 / P0-2 Phase-1 hooks):
// the kernel's `onRoundStart` re-evaluates the prep-time trigger with the
// cumulative `tokensSoFar` and rewrites the working list in place. Tests
// lock the trigger reuse, the tail-walk boundary rules (never cross a user
// prompt, pair caps, legal cut), the system-message exemption, and the
// no-op cases below the floor/trigger.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/agent/compaction/context_trim.dart';
import 'package:OmniChat/core/services/agent/compaction/midrun_compactor.dart';

Map<String, dynamic> _user(String text) => <String, dynamic>{
      'role': 'user',
      'content': text,
    };

Map<String, dynamic> _assistant(String text) => <String, dynamic>{
      'role': 'assistant',
      'content': text,
    };

Map<String, dynamic> _assistantWithToolCall(String id) =>
    <String, dynamic>{
      'role': 'assistant',
      'content': '\n\n',
      'tool_calls': [
        {
          'id': id,
          'type': 'function',
          'function': {
            'name': 'file_read',
            'arguments': '{"path":"a.txt"}',
          },
        }
      ],
    };

Map<String, dynamic> _toolResult(String id, String body) =>
    <String, dynamic>{
      'role': 'tool',
      'tool_call_id': id,
      'name': 'file_read',
      'content': body,
    };

void main() {
  group('applyMidRunCompaction', () {
    test('no-op below the 140k floor', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        _user('hello'),
        _assistant('hi'),
      ];
      final before = List.of(messages);
      final changed = applyMidRunCompaction(
        messages,
        tokensSoFar: 10_000,
        modelId: 'unknown-model',
        learnedWindowTokens: null,
      );
      expect(changed, isFalse);
      expect(messages.length, before.length);
    });

    test('no-op under the trigger (tokensSoFar <= trigger)', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        _user('hello'),
        _assistant('hi'),
      ];
      // Claude 200k window / 64k output → trigger 136k (plan locked).
      final changed = applyMidRunCompaction(
        messages,
        tokensSoFar: 136_000,
        modelId: 'claude-sonnet-4-5-20250929',
        learnedWindowTokens: null,
      );
      expect(changed, isFalse);
    });

    test('fires over the trigger and keeps the system message', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'SYSTEM_PROMPT'},
        _user('turn-1 question'),
        _assistant('turn-1 long answer ${'x' * 500}'),
        _user('turn-2 question'),
        _assistant('turn-2 short answer'),
      ];
      final changed = applyMidRunCompaction(
        messages,
        tokensSoFar: 200_000,
        modelId: 'claude-sonnet-4-5-20250929',
        learnedWindowTokens: null,
      );
      expect(changed, isTrue);
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'SYSTEM_PROMPT');
      // The list shrank: the summarized head collapses to the summary
      // user message, followed by the current turn's verbatim tail. (The
      // head keeps its own turn-1 user prompt because the tail walk stops
      // at the newest user prompt; the summary covers turn-1's answer.)
      expect(messages.length, lessThan(6));
      expect(messages[1]['role'], 'user');
      expect(
        (messages[1]['content'] as String).contains('<conversation_summary>'),
        isTrue,
      );
      expect(messages.last['content'], 'turn-2 short answer');
    });

    test('tail never crosses the newest user prompt', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        _user('old question'),
        _assistant('old answer'),
        _user('current question'),
        _assistant('current answer'),
      ];
      applyMidRunCompaction(
        messages,
        tokensSoFar: 200_000,
        modelId: 'claude-sonnet-4-5-20250929',
        learnedWindowTokens: null,
      );
      // The current turn (user + assistant) must remain verbatim.
      expect(messages[messages.length - 2]['content'], 'current question');
      expect(messages.last['content'], 'current answer');
    });

    test('tail keeps tool-call pairs intact and never cuts a tool result', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        _user('turn-1 question'),
        _assistant('turn-1 answer'),
        _user('turn-2 question'),
        _assistantWithToolCall('call_1'),
        _toolResult('call_1', 'tool body that stays verbatim'),
      ];
      applyMidRunCompaction(
        messages,
        tokensSoFar: 200_000,
        modelId: 'claude-sonnet-4-5-20250929',
        learnedWindowTokens: null,
      );
      // The pair (assistant tool_calls + tool result) must survive as a
      // unit — the first message of the tail must not be a role:'tool'.
      final firstToolIdx = messages
          .indexWhere((m) => m['role'] == 'tool' && m['tool_call_id'] == 'call_1');
      final firstCallIdx = messages
          .indexWhere((m) => m['role'] == 'assistant' && m['tool_calls'] != null);
      expect(firstCallIdx, greaterThan(0));
      expect(firstToolIdx, firstCallIdx + 1);
    });

    test('empty message list is a no-op', () {
      final messages = <Map<String, dynamic>>[];
      expect(
        applyMidRunCompaction(
          messages,
          tokensSoFar: 500_000,
          modelId: 'claude-sonnet-4-5-20250929',
          learnedWindowTokens: null,
        ),
        isFalse,
      );
    });

    test('working list without a user prompt is a no-op', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        _assistant('orphan answer'),
      ];
      expect(
        applyMidRunCompaction(
          messages,
          tokensSoFar: 500_000,
          modelId: 'claude-sonnet-4-5-20250929',
          learnedWindowTokens: null,
        ),
        isFalse,
      );
    });

    test('learned window lowers the trigger (window ceiling wins)', () {
      // Unknown model → 1M fallback → trigger 700k: a tokensSoFar of 150k
      // (above the 140k floor) would NOT fire. A learned 32k window drops
      // the trigger to 16k (0.5W guard), so the same run now compacts.
      List<Map<String, dynamic>> build() => <Map<String, dynamic>>[
            {'role': 'system', 'content': 'sys'},
            _user('turn-1 question'),
            _assistant('turn-1 answer'),
            _user('turn-2 question'),
            _assistant('turn-2 answer'),
          ];
      expect(
        applyMidRunCompaction(
          build(),
          tokensSoFar: 150_000,
          modelId: 'never-seen-model',
          learnedWindowTokens: null,
        ),
        isFalse,
      );
      expect(
        applyMidRunCompaction(
          build(),
          tokensSoFar: 150_000,
          modelId: 'never-seen-model',
          learnedWindowTokens: 32_000,
        ),
        isTrue,
      );
    });

    test('token estimator follows the chars/3 ruler', () {
      // 360 chars of content ≈ 120 tokens; verified indirectly through the
      // public estimateTextTokens ruler consistency.
      expect(estimateTextTokens('x' * 360), 120);
    });
  });
}
