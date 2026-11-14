import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/chat/tool_replay.dart';

void main() {
  group('spawn_subagent replay compaction (P1-5)', () {
    test('a large persisted result is compacted by buildToolReplayPairs', () {
      final summary = 'a' * 24000;
      final content = jsonEncode({
        'type': 'subagent_result',
        'status': 'max_steps',
        'summary': summary,
        'summary_source': 'wrap_up',
        'partial': true,
        'steps': 16,
        'tool_calls': 21,
        'tokens': 98234,
        'session_id': 'sub_1',
        'profile': 'explore',
        'untrusted': true,
      });

      final pairs = buildToolReplayPairs([
        {
          'id': 'call_1',
          'name': spawnSubagentToolName,
          'arguments': {'task': 'x'},
          'content': content,
          'approvalState': 'auto',
        },
      ], messageId: 'm1');

      expect(pairs, hasLength(1));
      expect(pairs.single.content.length, lessThan(2500));
      final parsed = jsonDecode(pairs.single.content) as Map;
      expect(parsed['status'], 'max_steps');
      expect(parsed['session_id'], 'sub_1');
      expect(parsed['replay_truncated'], isTrue);
    });

    test('other tools are replayed untouched', () {
      final content = 'x' * 5000;
      final pairs = buildToolReplayPairs([
        {
          'id': 'call_2',
          'name': 'file_read',
          'arguments': {'path': 'a.txt'},
          'content': content,
          'approvalState': 'auto',
        },
      ], messageId: 'm1');
      expect(pairs.single.content.length, 5000);
    });

    test('a short helper result is not rewritten', () {
      final content = jsonEncode({
        'type': 'subagent_result',
        'status': 'finished',
        'summary': 'done',
      });
      final pairs = buildToolReplayPairs([
        {
          'id': 'call_3',
          'name': spawnSubagentToolName,
          'arguments': const <String, dynamic>{},
          'content': content,
          'approvalState': 'auto',
        },
      ], messageId: 'm1');
      expect(pairs.single.content, content);
    });
  });
}
