import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

ChatStreamChunk _text(String content) =>
    ChatStreamChunk(content: content, isDone: false, totalTokens: 0);

void main() {
  test(
    '5 session follow-ups keep every prior answer in the transcript',
    () async {
      List<Map<String, dynamic>>? transcript;
      for (var i = 0; i < 5; i++) {
        late List<Map<String, dynamic>> sent;
        final runner = SubagentRunner(
          sendRound: (request) async {
            sent = request.messages;
            return Stream<ChatStreamChunk>.fromIterable([_text('ANSWER $i')]);
          },
          onToolCall: (_) async => 'ok',
        );
        final outcome = await runner.run(
          SubagentSpec(task: 'follow-up $i'),
          initialMessages: transcript,
        );
        expect(outcome.summary, 'ANSWER $i');
        expect(outcome.transcriptMessages, isNotNull);
        if (i > 0) {
          expect(jsonEncodeMessages(sent), contains('ANSWER ${i - 1}'));
        }
        transcript = outcome.transcriptMessages;
      }
      expect(jsonEncodeMessages(transcript!), contains('ANSWER 4'));
    },
  );

  test('5 read-only attack rounds cannot reintroduce write tools', () {
    final parent = <Map<String, dynamic>>[
      for (final name in <String>[
        'file_read',
        'file_write',
        'file_append',
        'file_mkdir',
        'shell_run',
        'memory_update',
      ])
        {
          'type': 'function',
          'function': {'name': name},
        },
    ];
    for (var round = 0; round < 5; round++) {
      const profile = SubagentProfile(
        id: 'attack',
        name: 'Attack',
        description: 'd',
        readOnly: true,
        allowedTools: <String>{
          'file_read',
          'file_write',
          'file_append',
          'file_mkdir',
          'shell_run',
          'memory_update',
        },
      );
      final tools = subagentChildTools(parent, profile: profile);
      expect(tools, hasLength(1), reason: 'round $round');
      expect(
        ((tools.single['function'] as Map)['name']),
        'file_read',
        reason: 'round $round',
      );
      expect(profile.permits('file_write'), isFalse);
      expect(profile.permits('file_append'), isFalse);
      expect(profile.permits('file_mkdir'), isFalse);
      expect(profile.permits('shell_run'), isFalse);
      expect(profile.permits('memory_update'), isFalse);
    }
  });
}

String jsonEncodeMessages(List<Map<String, dynamic>> messages) {
  final buffer = StringBuffer();
  for (final message in messages) {
    buffer.writeln('${message['role']}: ${message['content']}');
  }
  return buffer.toString();
}
