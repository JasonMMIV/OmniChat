import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/compaction/context_trim.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

ChatStreamChunk _text(String content) =>
    ChatStreamChunk(content: content, isDone: false, totalTokens: 0);

ChatStreamChunk _toolCall(String id, String name) => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: [ToolCallInfo(id: id, name: name, arguments: const {})],
);

void main() {
  group('P0-4 context guard boundaries', () {
    test('20 rounds of large tool results stay under a 128k window', () async {
      final requests = <List<Map<String, dynamic>>>[];
      var round = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request.messages);
          round++;
          if (round < 20) {
            return Stream<ChatStreamChunk>.fromIterable([
              _toolCall('c$round', 'file_read'),
            ]);
          }
          return Stream<ChatStreamChunk>.fromIterable([
            _text('finished after 20 rounds'),
          ]);
        },
        onToolCall: (_) async => 'x' * 80000,
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'long soak',
          maxSteps: 20,
          contextWindowTokens: 128000,
          maxOutputTokens: 4096,
        ),
      );

      // The L0 middle pruner keeps 20 x 80k results under 128k tokens, so the
      // window trim is not forced. The contract under test is that no round
      // ever sends an over-window request.
      expect(outcome.status, 'finished');
      expect(requests, hasLength(20));
      expect(outcome.steps, greaterThanOrEqualTo(19));
      expect(outcome.toolCallCount, 19);
      for (final messages in requests) {
        expect(
          estimateApiMessagesTokens(messages),
          lessThanOrEqualTo(128000 - (4096 + 2048)),
        );
      }
    });

    test('a single oversized task is hard-capped below the window', () async {
      final requests = <List<Map<String, dynamic>>>[];
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request.messages);
          return Stream<ChatStreamChunk>.fromIterable([_text('ok')]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        SubagentSpec(task: 'T' * 500000, contextWindowTokens: 8000),
      );

      expect(outcome.contextTrimmed, isTrue);
      expect(estimateApiMessagesTokens(requests.single), lessThan(8000));
      final last = requests.single.last;
      expect((last['content'] as String).length, lessThan(20000));
      expect(last['content'], contains('omitted'));
    });

    test('an unknown window uses the 1M fallback and does not trim', () async {
      final requests = <List<Map<String, dynamic>>>[];
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request.messages);
          return Stream<ChatStreamChunk>.fromIterable([_text('ok')]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        SubagentSpec(task: 'x' * 50000, contextWindowTokens: null),
      );

      expect(outcome.contextTrimmed, isFalse);
      expect(outcome.status, 'finished');
      expect(estimateApiMessagesTokens(requests.single), greaterThan(8000));
    });

    test('multimodal list content is clipped in place, not skipped', () async {
      final requests = <List<Map<String, dynamic>>>[];
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request.messages);
          return Stream<ChatStreamChunk>.fromIterable([_text('ok')]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'follow up', contextWindowTokens: 8000),
        initialMessages: [
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': 'S' * 100000},
            ],
          },
          {'role': 'user', 'content': 'Task:\nfirst'},
        ],
      );

      expect(outcome.contextTrimmed, isTrue);
      final system = requests.single.first;
      final parts = system['content'] as List;
      expect(parts, isNotEmpty);
      final text = (parts.first as Map)['text'] as String;
      expect(text.length, lessThan(20000));
      expect(text, contains('truncated'));
    });
  });
}
