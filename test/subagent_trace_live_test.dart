import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

ChatStreamChunk _text(String content) =>
    ChatStreamChunk(content: content, isDone: false, totalTokens: 0);

ChatStreamChunk _done() =>
    ChatStreamChunk(content: '', isDone: true, totalTokens: 1);

ChatStreamChunk _toolCall(String id, String name) => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: [ToolCallInfo(id: id, name: name, arguments: const {})],
);

void main() {
  test('runner emits live start/end callbacks for each child tool', () async {
    final events = <String>[];
    var round = 0;
    final runner = SubagentRunner(
      sendRound: (request) async {
        round++;
        if (round == 1) {
          return Stream<ChatStreamChunk>.fromIterable([
            _toolCall('c1', 'file_read'),
            _done(),
          ]);
        }
        return Stream<ChatStreamChunk>.fromIterable([_text('done'), _done()]);
      },
      onToolCall: (_) async => 'ok',
      onToolStart: (tool) => events.add('start:$tool'),
      onToolEnd: (step) => events.add('end:${step.tool}:${step.resultChars}'),
    );

    final outcome = await runner.run(const SubagentSpec(task: 'read a file'));

    expect(events, <String>['start:file_read', 'end:file_read:2']);
    expect(outcome.trace.single.tool, 'file_read');
    expect(outcome.trace.single.resultChars, 2);
  });
}
