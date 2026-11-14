import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/token_usage.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/agent/agent_orchestrator.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

ProviderConfig _config() => ProviderConfig(
  id: 't',
  enabled: true,
  name: 't',
  apiKey: 'k',
  baseUrl: 'http://127.0.0.1:1',
  providerType: ProviderKind.openai,
  models: const ['m'],
);

ChatStreamChunk _toolCall() => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: <ToolCallInfo>[
    ToolCallInfo(id: 'c1', name: 'file_read', arguments: const {'path': 'a'}),
  ],
);

void main() {
  group('AgentOrchestrator subagent usage (P1-4)', () {
    test(
      'normal terminal includes helper tokens in total but not prompt',
      () async {
        final chunks = await AgentOrchestrator()
            .run(
              config: _config(),
              modelId: 'm',
              requestId: 'u1',
              streamOutput: true,
              messages: const [
                {'role': 'user', 'content': 'hi'},
              ],
              subagentTokens: () => 50,
              onToolCall: (name, args, {String? toolCallId}) async => 'R',
              sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable([
                ChatStreamChunk(
                  content: 'hello',
                  isDone: false,
                  totalTokens: 0,
                  usage: const TokenUsage(
                    promptTokens: 80,
                    completionTokens: 20,
                    totalTokens: 100,
                  ),
                ),
                ChatStreamChunk(
                  content: '',
                  isDone: true,
                  totalTokens: 0,
                  usage: const TokenUsage(
                    promptTokens: 80,
                    completionTokens: 20,
                    totalTokens: 100,
                  ),
                ),
              ]),
            )
            .toList();

        final terminal = chunks.last;
        expect(terminal.isDone, isTrue);
        expect(terminal.totalTokens, 150);
        expect(terminal.usage, isNotNull);
        expect(terminal.usage!.subagentTokens, 50);
        expect(terminal.usage!.promptTokens, 80);
        expect(terminal.usage!.completionTokens, 20);
        expect(terminal.usage!.totalTokens, 150);
      },
    );

    test(
      'early stop carries helper tokens on the synthesized terminal',
      () async {
        final chunks = await AgentOrchestrator()
            .run(
              config: _config(),
              modelId: 'm',
              requestId: 'u2',
              streamOutput: true,
              messages: const [
                {'role': 'user', 'content': 'read'},
              ],
              options: const AgentLoopOptions(maxSteps: 1),
              subagentTokens: () => 30,
              onToolCall: (name, args, {String? toolCallId}) async => 'R',
              sendRound: (msgs) async =>
                  Stream<ChatStreamChunk>.fromIterable([_toolCall()]),
            )
            .toList();

        final terminal = chunks.last;
        expect(terminal.isDone, isTrue);
        expect(terminal.softStopReason, 'max_steps');
        expect(terminal.totalTokens, 30);
        expect(terminal.usage, isNotNull);
        expect(terminal.usage!.subagentTokens, 30);
        expect(terminal.usage!.totalTokens, 30);
      },
    );

    test('two helper runs accumulate', () async {
      var helperTokens = 0;
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 'u3',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'read'},
            ],
            options: const AgentLoopOptions(maxSteps: 1),
            subagentTokens: () => helperTokens,
            onToolCall: (name, args, {String? toolCallId}) async {
              helperTokens += 20;
              return 'R';
            },
            sendRound: (msgs) async =>
                Stream<ChatStreamChunk>.fromIterable([_toolCall()]),
          )
          .toList();

      expect(helperTokens, 20);
      expect(chunks.last.totalTokens, 20);
      expect(chunks.last.usage!.subagentTokens, 20);
    });
  });
}
