import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/token_usage.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

/// A scripted fake transport: one scripted chunk list per dispatched round.
class _FakeRoundTransport {
  _FakeRoundTransport(this.scripts);

  final List<List<ChatStreamChunk>> scripts;
  int calls = 0;
  final List<List<Map<String, dynamic>>> receivedMessages =
      <List<Map<String, dynamic>>>[];

  Future<Stream<ChatStreamChunk>> send(
    List<Map<String, dynamic>> messages,
  ) async {
    calls++;
    receivedMessages.add(List<Map<String, dynamic>>.of(messages));
    final script = calls <= scripts.length
        ? scripts[calls - 1]
        : const <ChatStreamChunk>[];
    return Stream<ChatStreamChunk>.fromIterable(script);
  }
}

ChatStreamChunk _text(String content) =>
    ChatStreamChunk(content: content, isDone: false, totalTokens: 0);

ChatStreamChunk _done() =>
    ChatStreamChunk(content: '', isDone: true, totalTokens: 0);

ChatStreamChunk _usage(TokenUsage usage) =>
    ChatStreamChunk(content: '', isDone: false, totalTokens: 0, usage: usage);

ChatStreamChunk _tools(List<ToolCallInfo> calls) => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: calls,
);

ToolCallInfo _call(String id, String name, [Map<String, dynamic>? args]) =>
    ToolCallInfo(
      id: id,
      name: name,
      arguments: args ?? const <String, dynamic>{},
    );

void main() {
  group('runAgentLoop', () {
    test(
      'finishes after one text-only round and forwards chunks in order',
      () async {
        final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
          <ChatStreamChunk>[_text('Hello'), _done()],
        ]);
        final events = await runAgentLoop(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
          sendRound: transport.send,
          onToolCall: (_) async => '',
        ).toList();

        expect(transport.calls, 1);
        final streamed = events
            .whereType<AgentStreamEvent>()
            .map((e) => e.chunk)
            .toList();
        expect(streamed.map((c) => c.content), <String>['Hello', '']);
        expect(streamed[0].isDone, isFalse);
        expect(streamed[1].isDone, isTrue);

        final end = events.whereType<AgentRunFinishedEvent>().single;
        expect(end.reason, AgentRunStopReason.finished);
        expect(end.stepIndex, 0);
        expect(end.executedCallCount, 0);
        expect(end.messages.length, 1);
      },
    );

    test('multi-round run executes tools once, appends neutral follow-up '
        'messages and finishes on the text round', () async {
      final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
        <ChatStreamChunk>[
          _tools(<ToolCallInfo>[
            _call('call_1', 'file_read', <String, dynamic>{'path': 'a.txt'}),
          ]),
          _done(),
        ],
        <ChatStreamChunk>[_text('Found 42'), _done()],
      ]);

      final executed = <AgentToolCall>[];
      final events = await runAgentLoop(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'read a.txt'},
        ],
        sendRound: transport.send,
        onToolCall: (call) async {
          executed.add(call);
          return 'FILE_BODY_42';
        },
      ).toList();

      // Tool executed exactly once with the scripted arguments.
      expect(executed, hasLength(1));
      expect(executed.single.name, 'file_read');
      expect(executed.single.toolCallId, 'call_1');
      expect(executed.single.arguments, <String, dynamic>{'path': 'a.txt'});

      // Logical execution event + synthetic toolResults chunk for the UI.
      final toolEvents = events.whereType<AgentToolExecutedEvent>().toList();
      expect(toolEvents, hasLength(1));
      expect(toolEvents.single.result, 'FILE_BODY_42');
      final synthetic = events
          .whereType<AgentStreamEvent>()
          .map((e) => e.chunk)
          .where((c) => (c.toolResults ?? const []).isNotEmpty)
          .toList();
      expect(synthetic, hasLength(1));
      expect(synthetic.single.toolResults!.single.id, 'call_1');
      expect(synthetic.single.toolResults!.single.content, 'FILE_BODY_42');

      // Round bookkeeping events.
      final roundEnd = events.whereType<AgentRoundFinishedEvent>().single;
      expect(roundEnd.stepIndex, 0);
      expect(roundEnd.executed.single.name, 'file_read');

      // Two transport requests; the second carries the appended neutral msgs.
      expect(transport.calls, 2);
      expect(transport.receivedMessages[1], hasLength(3));
      final assistant = transport.receivedMessages[1][1];
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], '\n\n');
      final calls = assistant['tool_calls'] as List<dynamic>;
      expect(calls, hasLength(1));
      final function =
          (calls.single as Map<String, dynamic>)['function']
              as Map<String, dynamic>;
      expect((calls.single as Map<String, dynamic>)['id'], 'call_1');
      expect(function['name'], 'file_read');
      expect(jsonDecode(function['arguments'] as String), <String, dynamic>{
        'path': 'a.txt',
      });
      final toolMsg = transport.receivedMessages[1][2];
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['name'], 'file_read');
      expect(toolMsg['tool_call_id'], 'call_1');
      expect(toolMsg['content'], 'FILE_BODY_42');

      final end = events.whereType<AgentRunFinishedEvent>().single;
      expect(end.reason, AgentRunStopReason.finished);
      expect(end.stepIndex, 1);
      expect(end.executedCallCount, 1);
      expect(end.messages.length, 3);
    });

    test(
      'a throwing tool becomes structured error JSON and the run continues',
      () async {
        final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
          <ChatStreamChunk>[
            _tools(<ToolCallInfo>[_call('call_x', 'search_web')]),
            _done(),
          ],
          <ChatStreamChunk>[_text('Sorry, searching failed.'), _done()],
        ]);

        final events = await runAgentLoop(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'search'},
          ],
          sendRound: transport.send,
          onToolCall: (_) async => throw Exception('boom'),
        ).toList();

        final executed = events.whereType<AgentToolExecutedEvent>().single;
        final errorJson = jsonDecode(executed.result) as Map<String, dynamic>;
        expect(errorJson['type'], 'tool_error');
        expect(errorJson['error'], 'execution_error');

        // The error reached the model as the role:'tool' content…
        final toolMsg = transport.receivedMessages[1][2];
        expect(
          (jsonDecode(toolMsg['content'] as String)
              as Map<String, dynamic>)['message'],
          contains('boom'),
        );
        // …and the run still finished normally on the following text round.
        final end = events.whereType<AgentRunFinishedEvent>().single;
        expect(end.reason, AgentRunStopReason.finished);
        expect(transport.calls, 2);
      },
    );

    test(
      'maxSteps stops before dispatching another round but persists results',
      () async {
        final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
          <ChatStreamChunk>[
            _tools(<ToolCallInfo>[_call('call_a', 'file_edit')]),
            _done(),
          ],
          // This round would never be reached: maxSteps = 1 tool round.
          <ChatStreamChunk>[
            _tools(<ToolCallInfo>[_call('call_b', 'file_write')]),
            _done(),
          ],
        ]);

        final events = await runAgentLoop(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'edit'},
          ],
          sendRound: transport.send,
          onToolCall: (call) async => 'ok:${call.name}',
          options: const AgentLoopOptions(maxSteps: 1),
        ).toList();

        expect(transport.calls, 1);
        final end = events.whereType<AgentRunFinishedEvent>().single;
        expect(end.reason, AgentRunStopReason.maxStepsReached);
        expect(end.stepIndex, 1);
        expect(end.executedCallCount, 1);
        // The executed tool outcome is part of the resume point.
        expect(end.messages, hasLength(3));
        expect(end.messages[2]['content'], 'ok:file_edit');
      },
    );

    test(
      'token budget soft-gate sums usage across rounds and stops cleanly',
      () async {
        final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
          <ChatStreamChunk>[
            _usage(const TokenUsage(totalTokens: 100)),
            _tools(<ToolCallInfo>[_call('c1', 'search_web')]),
            _done(),
          ],
          <ChatStreamChunk>[
            _usage(const TokenUsage(totalTokens: 100)),
            _tools(<ToolCallInfo>[_call('c2', 'search_web')]),
            _done(),
          ],
          <ChatStreamChunk>[
            _usage(const TokenUsage(totalTokens: 100)),
            _tools(<ToolCallInfo>[_call('c3', 'search_web')]),
            _done(),
          ],
          <ChatStreamChunk>[_text('final'), _done()],
        ]);

        final events = await runAgentLoop(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'go'},
          ],
          sendRound: transport.send,
          onToolCall: (_) async => 'result',
          options: const AgentLoopOptions(tokenBudget: 250),
        ).toList();

        // 100 + 100 + 100 = 300 ≥ 250 → stops before the 4th request.
        expect(transport.calls, 3);
        final end = events.whereType<AgentRunFinishedEvent>().single;
        expect(end.reason, AgentRunStopReason.tokenBudgetReached);
        expect(end.tokensUsed, 300);
        expect(end.executedCallCount, 3);
      },
    );

    test(
      'budget falls back to chunk.totalTokens when usage is missing',
      () async {
        final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
          <ChatStreamChunk>[
            _tools(<ToolCallInfo>[_call('c1', 'file_read')]),
            _done(),
          ],
          <ChatStreamChunk>[
            ChatStreamChunk(content: 'tokens', isDone: false, totalTokens: 120),
            _tools(<ToolCallInfo>[_call('c2', 'file_read')]),
            _done(),
          ],
          <ChatStreamChunk>[_text('final'), _done()],
        ]);

        final events = await runAgentLoop(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'go'},
          ],
          sendRound: transport.send,
          onToolCall: (_) async => 'r',
          options: const AgentLoopOptions(tokenBudget: 100),
        ).toList();

        // Round 0 spends 0 tokens (no usage / totalTokens), round 1 reports
        // totalTokens=120 → the next round is soft-gated before dispatch.
        expect(transport.calls, 2);
        final end = events.whereType<AgentRunFinishedEvent>().single;
        expect(end.reason, AgentRunStopReason.tokenBudgetReached);
        expect(end.tokensUsed, 120);
        expect(end.executedCallCount, 2);
      },
    );

    test('emitCalls=false suppresses synthetic result chunks', () async {
      final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
        <ChatStreamChunk>[
          _tools(<ToolCallInfo>[_call('c1', 'file_read')]),
          _done(),
        ],
        <ChatStreamChunk>[_text('done'), _done()],
      ]);

      final events = await runAgentLoop(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'go'},
        ],
        sendRound: transport.send,
        onToolCall: (_) async => 'r',
        options: const AgentLoopOptions(emitCalls: false),
      ).toList();

      final streamed = events
          .whereType<AgentStreamEvent>()
          .map((e) => e.chunk)
          .toList();
      expect(
        streamed.where((c) => (c.toolResults ?? const []).isNotEmpty),
        isEmpty,
      );
      expect(events.whereType<AgentToolExecutedEvent>(), hasLength(1));
      expect(
        events.whereType<AgentRunFinishedEvent>().single.reason,
        AgentRunStopReason.finished,
      );
    });

    test('hook veto stops the run before any request is sent', () async {
      final transport = _FakeRoundTransport(const <List<ChatStreamChunk>>[]);

      final events = await runAgentLoop(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'go'},
        ],
        sendRound: transport.send,
        onToolCall: (_) async => 'r',
        hooks: AgentLoopHooks(onRoundStart: (_, __, ___) async => false),
      ).toList();

      expect(transport.calls, 0);
      expect(
        events.whereType<AgentRunFinishedEvent>().single.reason,
        AgentRunStopReason.stoppedByHook,
      );
    });

    test('hooks observe round start / tool executed / round end', () async {
      final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
        <ChatStreamChunk>[
          _tools(<ToolCallInfo>[_call('c1', 'file_read')]),
          _done(),
        ],
        <ChatStreamChunk>[_text('ok'), _done()],
      ]);

      final starts = <int>[];
      final executedNames = <String>[];
      final endedSteps = <int>[];
      final tokenAtStart = <int>[];

      await runAgentLoop(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'go'},
        ],
        sendRound: transport.send,
        onToolCall: (_) async => 'r',
        hooks: AgentLoopHooks(
          onRoundStart: (step, _, tokens) async {
            starts.add(step);
            tokenAtStart.add(tokens);
            return true;
          },
          onToolExecuted: (call, _) async => executedNames.add(call.name),
          onRoundEnd: (step, _) async => endedSteps.add(step),
        ),
      ).toList();

      expect(starts, <int>[0, 1]);
      expect(tokenAtStart, <int>[0, 0]);
      expect(executedNames, <String>['file_read']);
      expect(endedSteps, <int>[0]);
    });
  });

  group('AgentNeutralMessages', () {
    test('round assistantExtras are threaded onto the follow-up assistant '
        'message (reasoning echo)', () async {
      final transport = _FakeRoundTransport(<List<ChatStreamChunk>>[
        <ChatStreamChunk>[
          ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: 0,
            toolCalls: <ToolCallInfo>[_call('c1', 'file_read')],
            assistantExtras: <String, dynamic>{
              'reasoning_content': 'let me think',
            },
          ),
          _done(),
        ],
        <ChatStreamChunk>[_text('final'), _done()],
      ]);

      await runAgentLoop(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'go'},
        ],
        sendRound: transport.send,
        onToolCall: (_) async => 'r',
      ).toList();

      final followUp = transport.receivedMessages[1];
      final assistant = followUp.firstWhere((m) => m['role'] == 'assistant');
      expect(assistant['tool_calls'], isA<List<dynamic>>());
      expect(assistant['reasoning_content'], 'let me think');
      // Extras are run-scoped only: never persisted into cross-turn replay
      // messages the caller passed in (ADR-A2 / §3.11 known limitation).
      expect(transport.receivedMessages[0], isNotEmpty);
    });

    test(
      'assistant message matches the §3.11 replay shape and accepts extras',
      () {
        final msg = AgentNeutralMessages.assistantMessage(
          calls: <AgentToolCall>[
            const AgentToolCall(
              toolCallId: 'c1',
              name: 'file_read',
              arguments: <String, dynamic>{'path': 'x'},
            ),
          ],
          assistantExtras: <String, dynamic>{'reasoning_content': 'think'},
        );

        expect(msg['role'], 'assistant');
        expect(msg['content'], '\n\n');
        expect(msg['reasoning_content'], 'think');
        final call =
            (msg['tool_calls'] as List<dynamic>).single as Map<String, dynamic>;
        expect(call['id'], 'c1');
        expect(call['type'], 'function');
        expect((call['function'] as Map<String, dynamic>)['name'], 'file_read');
        expect(
          jsonDecode(
            (call['function'] as Map<String, dynamic>)['arguments'] as String,
          ),
          <String, dynamic>{'path': 'x'},
        );
      },
    );

    test('tool result message carries id, name and content', () {
      final msg = AgentNeutralMessages.toolResultMessage(
        call: const AgentToolCall(
          toolCallId: 'c1',
          name: 'file_read',
          arguments: <String, dynamic>{},
        ),
        result: 'BODY',
      );
      expect(msg['role'], 'tool');
      expect(msg['tool_call_id'], 'c1');
      expect(msg['name'], 'file_read');
      expect(msg['content'], 'BODY');
    });

    test('encodeArguments falls back to {} on non-serializable input', () {
      final cyclic = <String, dynamic>{};
      cyclic['self'] = cyclic;
      expect(encodeArguments(cyclic), '{}');
    });
  });
}
