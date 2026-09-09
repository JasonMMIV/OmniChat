// Driver tests (IMPORT_PLAN_COWORK.md P0-2).
//
// `AgentOrchestrator.run` must re-map kernel events onto the chunk stream
// contract the existing UI pipeline consumes:
//   - transport chunks pass through untouched (content / toolCalls /
//     synthetic toolResults from `emitCalls`),
//   - a normal run ends with the transport's own `isDone` chunk (no
//     duplicate terminal chunk),
//   - an early stop (maxSteps / budget / hook veto) synthesizes the terminal
//     `isDone` chunk so the UI finalizes the message bubble.

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';
import 'package:OmniChat/features/home/services/agent_orchestrator.dart';

ProviderConfig _config({bool responses = false}) => ProviderConfig(
  id: 't',
  enabled: true,
  name: 't',
  apiKey: 'k',
  baseUrl: 'http://127.0.0.1:1',
  providerType: ProviderKind.openai,
  models: const ['m'],
  useResponseApi: responses ? true : null,
);

ChatStreamChunk _text(String content) =>
    ChatStreamChunk(content: content, isDone: false, totalTokens: 0);

ChatStreamChunk _done() =>
    ChatStreamChunk(content: '', isDone: true, totalTokens: 0);

ChatStreamChunk _tools() => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: <ToolCallInfo>[
    ToolCallInfo(id: 'c1', name: 'file_read', arguments: const {'path': 'a'}),
  ],
);

void main() {
  test('normal run: chunks pass through, transport isDone closes the stream, '
      'no duplicate terminal chunk', () async {
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 't1',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'R',
          sendRound: (msgs) async => Stream<ChatStreamChunk>.fromIterable(
            <ChatStreamChunk>[_text('hello'), _done()],
          ),
        )
        .toList();

    expect(chunks.map((c) => c.content), <String>['hello', '']);
    expect(chunks.map((c) => c.isDone), <bool>[false, true]);
    // Exactly one isDone chunk: the transport's own.
    expect(chunks.where((c) => c.isDone), hasLength(1));
  });

  test('tool round: toolCalls + synthetic toolResults pass through, run '
      'finishes with the second round\'s isDone chunk', () async {
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 't2',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          sendRound: (msgs) async {
            final hasToolCalls = msgs.any(
              (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
            );
            // Expose-mode faithful: a tool round returns after the toolCalls
            // chunk (no isDone); a text round ends with its own isDone.
            return Stream<ChatStreamChunk>.fromIterable(
              hasToolCalls
                  ? <ChatStreamChunk>[_text('final'), _done()]
                  : <ChatStreamChunk>[_tools()],
            );
          },
        )
        .toList();

    final toolCallChunks = chunks
        .where((c) => (c.toolCalls ?? const []).isNotEmpty)
        .toList();
    expect(toolCallChunks, hasLength(1));
    expect(toolCallChunks.single.toolCalls!.single.id, 'c1');

    final resultChunks = chunks
        .where((c) => (c.toolResults ?? const []).isNotEmpty)
        .toList();
    // Kernel emitCalls: true re-emits one synthetic toolResults chunk.
    expect(resultChunks, hasLength(1));
    expect(resultChunks.single.toolResults!.single.content, 'BODY');
    expect(chunks.map((c) => c.content), contains('final'));
    expect(chunks.last.isDone, isTrue);
    expect(chunks.where((c) => c.isDone), hasLength(1));
  });

  test('early stop (maxSteps): terminal isDone chunk is synthesized', () async {
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 't3',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          options: const AgentLoopOptions(maxSteps: 1),
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[_tools()]),
        )
        .toList();

    // Tool round only: the transport never emitted a terminal chunk for
    // it, so the driver synthesizes isDone to finalize the bubble.
    expect(chunks.last.isDone, isTrue);
    expect(chunks.where((c) => c.isDone), hasLength(1));
    // P0-5: max-steps soft stop carries the reason on the terminal chunk
    // so the UI can append the localized footnote.
    expect(chunks.last.softStopReason, 'max_steps');
  });

  test('early stop (token budget): terminal chunk carries token_budget',
      () async {
    final chunks = await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 't3b',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async => 'BODY',
          // maxSteps must not bind first (the kernel checks it before the
          // budget gate), so give the run room and trip the budget only.
          options: const AgentLoopOptions(maxSteps: 5, tokenBudget: 1),
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[
                // Usage-carrying tool round: tokensUsed(5) >= budget(1)
                // stops the run before round 2 is dispatched.
                ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: 5,
                  toolCalls: _tools().toolCalls,
                ),
              ]),
        )
        .toList();

    expect(chunks.last.isDone, isTrue);
    expect(chunks.last.softStopReason, 'token_budget');
  });

  test(
    'hook veto: terminal isDone chunk synthesized, no request sent',
    () async {
      var sent = 0;
      final chunks = await AgentOrchestrator()
          .run(
            config: _config(),
            modelId: 'm',
            requestId: 't4',
            streamOutput: true,
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            onToolCall: (name, args, {String? toolCallId}) async => 'R',
            hooks: AgentLoopHooks(
              onRoundStart: (step, msgs, tokens) async => false,
            ),
            sendRound: (msgs) async {
              sent++;
              return Stream<ChatStreamChunk>.fromIterable(
                const <ChatStreamChunk>[],
              );
            },
          )
          .toList();

      expect(sent, 0);
      expect(chunks.single.isDone, isTrue);
      // P0-5: hook vetoes (approval pause) carry NO soft-stop reason — the
      // approval card is the user-facing surface for those.
      expect(chunks.single.softStopReason, isNull);
    },
  );

  test('P1-4: handler receives the provider tool-call id', () async {
    String? seenId;
    await AgentOrchestrator()
        .run(
          config: _config(),
          modelId: 'm',
          requestId: 't4b',
          streamOutput: true,
          messages: const [
            {'role': 'user', 'content': 'read'},
          ],
          onToolCall: (name, args, {String? toolCallId}) async {
            seenId = toolCallId;
            return 'BODY';
          },
          sendRound: (msgs) async =>
              Stream<ChatStreamChunk>.fromIterable(<ChatStreamChunk>[_tools()]),
        )
        .toList();
    expect(seenId, 'c1');
  });

  test('supportsKernelPath: OpenAI/Claude/Gemini/Responses yes', () {
    expect(AgentOrchestrator.supportsKernelPath(_config()), isTrue);
    expect(
      AgentOrchestrator.supportsKernelPath(_config(responses: true)),
      isTrue,
    );
    expect(
      AgentOrchestrator.supportsKernelPath(
        ProviderConfig(
          id: 'c',
          enabled: true,
          name: 'c',
          apiKey: 'k',
          baseUrl: 'http://127.0.0.1:1',
          providerType: ProviderKind.claude,
          models: const ['m'],
        ),
      ),
      isTrue,
    );
    expect(
      AgentOrchestrator.supportsKernelPath(
        ProviderConfig(
          id: 'g',
          enabled: true,
          name: 'g',
          apiKey: 'k',
          baseUrl: 'http://127.0.0.1:1',
          providerType: ProviderKind.google,
          models: const ['m'],
        ),
      ),
      isTrue,
    );
  });
}
