import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

ChatStreamChunk _text(String content, {int total = 0}) => ChatStreamChunk(
  content: content,
  isDone: false,
  totalTokens: total,
);

ChatStreamChunk _done({int total = 0}) =>
    ChatStreamChunk(content: '', isDone: true, totalTokens: total);

ChatStreamChunk _toolCall(String id, String name) => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: [ToolCallInfo(id: id, name: name, arguments: const {})],
);

void main() {
  group('subagentChildTools', () {
    test('drops the excluded tools and keeps the rest', () {
      final parent = <Map<String, dynamic>>[
        {
          'type': 'function',
          'function': {'name': 'file_read'},
        },
        {
          'type': 'function',
          'function': {'name': spawnSubagentToolName},
        },
        {
          'type': 'function',
          'function': {'name': 'ask_user'},
        },
        {
          'type': 'function',
          'function': {'name': 'write_todos'},
        },
        {
          'type': 'function',
          'function': {'name': 'search_web'},
        },
        // Malformed entries are skipped, never crash the child list.
        <String, dynamic>{'type': 'function'},
      ];

      final child = subagentChildTools(parent);
      expect(
        child.map((d) => (d['function'] as Map)['name']).toList(),
        ['file_read', 'search_web'],
      );
      expect(subagentChildTools(null), isEmpty);
      expect(subagentChildTools(const []), isEmpty);
    });
  });

  group('SubagentLaunchConfig', () {
    test('child inherits transport fields and bumps the depth', () {
      const parent = SubagentLaunchConfig(
        providerKey: 'p',
        modelId: 'm',
        tools: <Map<String, dynamic>>[],
        extraHeaders: {'X-Test': '1'},
        extraBody: {'custom': true},
        maxTokens: 4096,
      );

      final child = parent.child(<Map<String, dynamic>>[]);
      expect(child.providerKey, 'p');
      expect(child.modelId, 'm');
      expect(child.extraHeaders, {'X-Test': '1'});
      expect(child.extraBody, {'custom': true});
      expect(child.maxTokens, 4096);
      expect(child.depth, 1);
      // The parent's depth is untouched: the snapshot is immutable.
      expect(parent.depth, 0);
    });
  });

  group('SubagentSpec', () {
    test('normalizes arguments and clamps the step ceiling', () {
      final spec = SubagentSpec.fromArguments(<String, dynamic>{
        'task': '  find the TODO markers  ',
        'role': 'code reviewer',
        'max_steps': 999,
      });
      expect(spec.task, 'find the TODO markers');
      expect(spec.role, 'code reviewer');
      expect(spec.maxSteps, SubagentSpec.maxStepsLimit);

      final low = SubagentSpec.fromArguments(<String, dynamic>{
        'task': 'x',
        'max_steps': 0,
      });
      expect(low.maxSteps, 1);

      final byDefault = SubagentSpec.fromArguments(<String, dynamic>{
        'task': 'x',
      });
      expect(byDefault.maxSteps, SubagentSpec.defaultMaxSteps);
      expect(byDefault.role, isNull);
    });
  });

  group('SubagentRunner', () {
    test('starts from a fresh system+task context and returns only the '
        'final round summary', () async {
      final calls = <List<Map<String, dynamic>>>[];
      final runner = SubagentRunner(
        sendRound: (request) async {
          final messages = request.messages;
          calls.add(List<Map<String, dynamic>>.of(messages));
          if (calls.length == 1) {
            return Stream<ChatStreamChunk>.fromIterable([
              _text('Let me inspect the file first.'),
              _toolCall('c1', 'file_read'),
              _done(),
            ]);
          }
          return Stream<ChatStreamChunk>.fromIterable([
            _text('The file contains the word alpha. '),
            _text('Summary complete.'),
            _done(total: 40),
          ]);
        },
        onToolCall: (call) async => 'alpha',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'Summarise a.txt', role: 'reviewer'),
      );

      expect(outcome.status, 'finished');
      // The tool-round preamble is discarded; only the last round answers.
      expect(outcome.summary, 'The file contains the word alpha. Summary complete.');
      expect(outcome.toolCallCount, 1);
      expect(outcome.steps, 1);

      // First round: only the helper system prompt + the task. No parent
      // conversation messages are part of the request.
      expect(calls.first, hasLength(2));
      expect(calls.first[0]['role'], 'system');
      expect(calls.first[0]['content'], contains('subagent'));
      expect(calls.first[0]['content'], contains('reviewer'));
      expect(calls.first[1]['role'], 'user');
      expect(calls.first[1]['content'], contains('Summarise a.txt'));

      // Second round: the kernel appended the assistant tool_calls message and
      // the tool result to the helper's own working list.
      expect(calls[1], hasLength(4));
      expect(calls[1][2]['role'], 'assistant');
      expect(calls[1][3]['role'], 'tool');
      expect(calls[1][3]['content'], 'alpha');
    });

    test('stops at its own step ceiling and reports a partial summary', () async {
      var rounds = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          final messages = request.messages;
          rounds++;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('round $rounds'),
            _toolCall('c$rounds', 'file_read'),
            _done(),
          ]);
        },
        onToolCall: (call) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'loop', maxSteps: 2),
      );

      expect(rounds, 2);
      expect(outcome.status, 'max_steps');
      expect(outcome.steps, 2);
      expect(outcome.toolCallCount, 2);
      final json = jsonDecode(outcome.toToolResultJson()) as Map;
      expect(json['type'], 'subagent_result');
      expect(json['status'], 'max_steps');
      expect(json['note'], contains('limit'));
    });

    test('times out with a partial summary instead of hanging', () async {
      // An open stream that never terminates: the deadline must cancel it.
      final hang = StreamController<ChatStreamChunk>();
      final hangingRunner = SubagentRunner(
        sendRound: (request) async {
          final messages = request.messages;
          hang.add(_text('Partial answer so far', total: 7));
          return hang.stream;
        },
        onToolCall: (call) async => 'ok',
      );

      final outcome = await hangingRunner.run(
        const SubagentSpec(
          task: 'hang',
          timeout: Duration(milliseconds: 80),
        ),
      );
      await hang.close();

      expect(outcome.timedOut, isTrue);
      expect(outcome.status, 'timeout');
      expect(outcome.summary, 'Partial answer so far');
      expect(
        (jsonDecode(outcome.toToolResultJson()) as Map)['note'],
        contains('time limit'),
      );
    });

    test('reports transport errors as a structured outcome', () async {
      final runner = SubagentRunner(
        sendRound: (request) async => throw StateError('boom'),
        onToolCall: (call) async => 'ok',
      );

      final outcome = await runner.run(const SubagentSpec(task: 'fail'));

      expect(outcome.status, 'error');
      expect(outcome.error, contains('boom'));
      final json = jsonDecode(outcome.toToolResultJson()) as Map;
      expect(json['type'], 'subagent_result');
      expect(json['error'], contains('boom'));
    });

    test('runs helpers one at a time across concurrent generations', () async {
      var active = 0;
      var maxActive = 0;

      Future<SubagentRunner> makeRunner() async => SubagentRunner(
        sendRound: (request) async {
          final messages = request.messages;
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          active--;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('done'),
            _done(),
          ]);
        },
        onToolCall: (call) async => 'ok',
      );

      final a = await makeRunner();
      final b = await makeRunner();
      await Future.wait([
        a.run(const SubagentSpec(task: 'one')),
        b.run(const SubagentSpec(task: 'two')),
      ]);

      expect(maxActive, 1);
    });

    test('stops at a round boundary when the generation is cancelled', () async {
      var cancelled = false;
      final runner = SubagentRunner(
        sendRound: (request) async {
          final messages = request.messages;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('working'),
            _toolCall('c1', 'file_read'),
            _done(),
          ]);
        },
        onToolCall: (call) async {
          cancelled = true;
          return 'ok';
        },
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'stop me'),
        isCancelled: () => cancelled,
      );

      expect(outcome.status, 'stopped');
      expect(outcome.summary, isEmpty);
      expect(
        (jsonDecode(outcome.toToolResultJson()) as Map)['note'],
        contains('stopped'),
      );
    });

    test('reports a cancelled run as stopped even when the stream still ends '
        'cleanly', () async {
      var cancelled = false;
      final runner = SubagentRunner(
        sendRound: (request) async {
          final messages = request.messages;
          // The stop arrives while the round is in flight. The transport may
          // still end the stream without an error/terminal — the runner must
          // not report that as a finished helper.
          cancelled = true;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('partial answer'),
            _done(),
          ]);
        },
        onToolCall: (call) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'cancel me'),
        isCancelled: () => cancelled,
      );

      expect(outcome.cancelled, isTrue);
      expect(outcome.status, 'stopped');
    });

    test('independent usage accounting does not inherit parent tokens', () async {
      final runner = SubagentRunner(
        sendRound: (request) async {
          final messages = request.messages;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('answer', total: 120),
            _done(total: 120),
          ]);
        },
        onToolCall: (call) async => 'ok',
      );

      final outcome = await runner.run(const SubagentSpec(task: 'count'));
      expect(outcome.tokensUsed, 120);
    });
  });

  test('clips an oversized summary without corrupting the JSON contract', () {
    final outcome = SubagentOutcome(
      summary: 'x' * (SubagentOutcome.maxSummaryChars + 500),
      stopReason: AgentRunStopReason.finished,
    );

    final json = jsonDecode(outcome.toToolResultJson()) as Map;
    expect(json['status'], 'finished');
    expect(json['summary_truncated'], isTrue);
    final summary = json['summary'] as String;
    expect(summary, contains('summary truncated'));
    // The whole payload must stay inside the 32 KB tool cap, so the transport
    // backstop never cuts the encoded JSON itself.
    expect(outcome.toToolResultJson().length, lessThan(32768));
  });

  test('system prompt demands a self-contained final summary', () {
    final prompt = buildSubagentSystemPrompt(role: 'researcher');
    expect(prompt, contains('fresh'));
    expect(prompt, contains('Your role: researcher'));
    expect(prompt, contains('FINAL message is the deliverable'));
    expect(prompt, contains('approval_required'));
    expect(
      buildSubagentSystemPrompt(),
      isNot(contains('Your role:')),
    );
  });
}
