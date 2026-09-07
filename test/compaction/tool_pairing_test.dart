// Pairing-safe cut selection + R0 mechanical trim units.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/agent/compaction/context_trim.dart';
import 'package:OmniChat/core/services/agent/compaction/tool_pairing.dart';

Map<String, dynamic> user(String c) => {'role': 'user', 'content': c};
Map<String, dynamic> assistant(String c) => {'role': 'assistant', 'content': c};
Map<String, dynamic> assistantWithCalls(String id, int count) => {
      'role': 'assistant',
      'content': '\n\n',
      'tool_calls': [
        for (var i = 0; i < count; i++)
          {
            'id': '${id}_$i',
            'type': 'function',
            'function': {'name': 'file_read', 'arguments': '{"path":"a.txt"}'},
          }
      ],
    };
Map<String, dynamic> toolResult(String id, String c) => {
      'role': 'tool',
      'name': 'file_read',
      'tool_call_id': id,
      'content': c,
    };

void main() {
  group('isLegalCutIndex / firstLegalTailStart', () {
    test('a cut before a tool result is illegal', () {
      final messages = [
        assistantWithCalls('c', 2),
        toolResult('c_0', 'r0'),
        toolResult('c_1', 'r1'),
        assistant('done'),
      ];
      expect(isLegalCutIndex(messages, 0), isTrue);
      expect(isLegalCutIndex(messages, 1), isFalse);
      expect(isLegalCutIndex(messages, 2), isFalse);
      expect(isLegalCutIndex(messages, 3), isTrue);
      expect(firstLegalTailStart(messages, 1), 3);
    });

    test('system prefix and plain messages are always legal cuts', () {
      final messages = [
        {'role': 'system', 'content': 'sys'},
        user('u'),
        assistant('a'),
      ];
      for (var i = 0; i <= messages.length; i++) {
        expect(isLegalCutIndex(messages, i), isTrue);
      }
    });
  });

  group('trimMessagesToFitTokenLimit', () {
    test('already fits → null (nothing to do)', () {
      final messages = [user('hello'), assistant('hi')];
      expect(trimMessagesToFitTokenLimit(messages, 100_000), isNull);
    });

    test('keeps the newest tail, drops the head, inserts a placeholder', () {
      final big = 'x' * 30_000; // ~10k tokens each
      final messages = [
        user('${big}1'),
        assistant('${big}2'),
        user('${big}3'),
        assistant('short answer'),
      ];
      // Target: keep only the last message (~1 token) plus placeholder.
      final trimmed = trimMessagesToFitTokenLimit(messages, 200)!;
      expect(trimmed.length, 2);
      expect(trimmed.first['content'], contextTrimPlaceholderText);
      expect(trimmed.last['content'], 'short answer');
      expect(estimateApiMessagesTokens(trimmed), lessThanOrEqualTo(200 + 100));
    });

    test('system messages are always preserved', () {
      final big = 'x' * 30_000;
      final messages = [
        {'role': 'system', 'content': 'You are OmniChat.'},
        user(big),
        user(big),
        user('latest'),
      ];
      final trimmed = trimMessagesToFitTokenLimit(messages, 300)!;
      expect(trimmed.first['role'], 'system');
      expect(trimmed.first['content'], 'You are OmniChat.');
    });

    test('never starts the kept tail on a dangling tool result', () {
      final big = 'x' * 30_000;
      final messages = [
        user(big),
        assistantWithCalls('c', 1),
        toolResult('c_0', big),
        user('latest'),
      ];
      // Budget only fits the last user message; the cut must advance past
      // the tool result.
      final trimmed = trimMessagesToFitTokenLimit(messages, 300)!;
      expect(trimmed.first['role'], isNot('tool'));
      expect(trimmed.last['content'], 'latest');
    });

    test('irreducible: only the forced newest message remains → still trims', () {
      final messages = [
        user('x' * 30_000),
        user('x' * 30_000),
      ];
      final trimmed = trimMessagesToFitTokenLimit(messages, 15_000)!;
      // The newest message is always kept even when it alone blows the
      // budget; the head is still dropped.
      expect(trimmed.length, 2);
      expect(estimateApiMessagesTokens(trimmed),
          lessThan(estimateApiMessagesTokens(messages)));
    });
  });

  group('estimateApiMessagesTokens', () {
    test('counts content and tool-call arguments (chars/3)', () {
      final messages = [
        user('a' * 300),
        assistantWithCalls('c', 2),
      ];
      final tokens = estimateApiMessagesTokens(messages);
      // args json is ~30 chars per call; 300+ args chars → ~110+ tokens.
      expect(tokens, greaterThan(100));
      expect(tokens, lessThan(200));
    });
  });
}
