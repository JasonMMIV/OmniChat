import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/agent/compaction/context_trim.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/core/services/agent/subagent_request.dart';
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
  group('P0-2 wrap-up', () {
    test('a max_steps stop produces a wrap-up summary', () async {
      SubagentRoundRequest? summaryRequest;
      final runner = SubagentRunner(
        sendRound: (request) async {
          return Stream<ChatStreamChunk>.fromIterable([
            _text('working on it'),
            _toolCall('c1', 'file_read'),
            _done(),
          ]);
        },
        sendWrapUpRound: (request) async {
          summaryRequest = request;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('FINAL DELIVERABLE'),
            _done(total: 30),
          ]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'loop', maxSteps: 1),
      );

      expect(outcome.status, 'max_steps');
      expect(outcome.summary, 'FINAL DELIVERABLE');
      expect(outcome.summarySource, SubagentSummarySource.wrapUp);
      expect(outcome.partial, isTrue);
      expect(outcome.tokensUsed, 30);

      expect(summaryRequest, isNotNull);
      expect(summaryRequest!.textOnly, isTrue);
      expect(summaryRequest!.tools, isNull);
      expect(summaryRequest!.webFetchEnabled, isFalse);
      expect(summaryRequest!.toolImagesEnabled, isFalse);
      expect(
        summaryRequest!.messages.last['content'].toString(),
        contains('FINAL ROUND'),
      );
      // The kernel history is trimmed BEFORE the instruction is appended, so
      // the instruction can never be the thing that gets dropped.
      expect(
        summaryRequest!.messages.last['content'].toString(),
        contains('step or token'),
      );

      final json = jsonDecode(outcome.toToolResultJson()) as Map;
      expect(json['summary_source'], 'wrap_up');
      expect(json['partial'], isTrue);
    });

    test('a failed wrap-up falls back to the last preamble', () async {
      var round = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          round++;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('preamble $round'),
            _toolCall('c$round', 'file_read'),
            _done(),
          ]);
        },
        sendWrapUpRound: (request) async => throw StateError('nope'),
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'loop', maxSteps: 2),
      );

      expect(outcome.status, 'max_steps');
      expect(outcome.summary, 'preamble 2');
      expect(outcome.summarySource, SubagentSummarySource.preamble);
      expect(
        (jsonDecode(outcome.toToolResultJson()) as Map)['note'],
        contains('wrap-up failed'),
      );
    });

    test('a user stop never spends a wrap-up request', () async {
      var cancelled = false;
      var wrapUps = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          return Stream<ChatStreamChunk>.fromIterable([
            _text('working'),
            _toolCall('c1', 'file_read'),
            _done(),
          ]);
        },
        sendWrapUpRound: (request) async {
          wrapUps++;
          return Stream<ChatStreamChunk>.fromIterable([_text('x'), _done()]);
        },
        onToolCall: (_) async {
          cancelled = true;
          return 'ok';
        },
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'stop'),
        isCancelled: () => cancelled,
      );

      expect(outcome.status, 'stopped');
      expect(wrapUps, 0);
    });

    test('wrapUpTimeout zero disables the extra request', () async {
      var wrapUps = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          return Stream<ChatStreamChunk>.fromIterable([
            _text('still working'),
            _toolCall('c1', 'file_read'),
            _done(),
          ]);
        },
        sendWrapUpRound: (request) async {
          wrapUps++;
          return Stream<ChatStreamChunk>.fromIterable([_text('x'), _done()]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'loop',
          maxSteps: 1,
          wrapUpTimeout: Duration.zero,
        ),
      );
      expect(wrapUps, 0);
      expect(outcome.summarySource, SubagentSummarySource.preamble);
    });
  });

  group('P0-1 gate and abort', () {
    test('the gate waits for an in-flight tool after a timeout', () async {
      final order = <String>[];
      final toolGate = Completer<void>();
      final hang = StreamController<ChatStreamChunk>();

      final runnerA = SubagentRunner(
        sendRound: (request) async {
          if (order.where((e) => e == 'a_round').isEmpty) {
            order.add('a_round');
            return Stream<ChatStreamChunk>.fromIterable([
              _toolCall('c1', 'file_read'),
              _done(),
            ]);
          }
          order.add('a_hang');
          return hang.stream;
        },
        onToolCall: (_) async {
          order.add('tool_start');
          await toolGate.future;
          order.add('tool_done');
          return 'ok';
        },
      );

      final runnerB = SubagentRunner(
        sendRound: (request) async {
          order.add('b_start');
          return Stream<ChatStreamChunk>.fromIterable([
            _text('done'),
            _done(),
          ]);
        },
        onToolCall: (_) async => 'ok',
      );

      final futureA = runnerA.run(
        const SubagentSpec(
          task: 'slow',
          timeout: Duration(milliseconds: 120),
          toolSettleGrace: Duration(seconds: 2),
        ),
      );
      final futureB = runnerB.run(const SubagentSpec(task: 'second'));

      // Let the deadline fire, then let the tool finish.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(order.contains('b_start'), isFalse);
      toolGate.complete();
      final outcomeA = await futureA;
      await futureB;
      // A single-subscription controller with no listener never completes
      // close(); the kernel may have already abandoned round 2.
      unawaited(hang.close());

      expect(outcomeA.timedOut, isTrue);
      expect(
        order.indexOf('tool_done'),
        lessThan(order.indexOf('b_start')),
      );
    });

    test('an aborted round throws instead of faking a finished stream', () async {
      var cancelled = false;
      final runner = SubagentRunner(
        sendRound: (request) async {
          cancelled = true;
          throw const SubagentAborted();
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'abort'),
        isCancelled: () => cancelled,
      );

      expect(outcome.cancelled, isTrue);
      expect(outcome.status, 'stopped');
      expect(outcome.summary, isEmpty);
    });

    test('a cancel while queued returns immediately and keeps FIFO', () async {
      final gate = SerialGate();
      final order = <String>[];
      final abortSecond = Completer<void>();

      final first = gate.run<String>(() async {
        order.add('first_start');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        order.add('first_end');
        return 'first';
      });
      final second = gate.run<String>(
        () async {
          order.add('second_start');
          return 'second';
        },
        abort: abortSecond.future,
      );
      final third = gate.run<String>(() async {
        order.add('third_start');
        return 'third';
      });

      abortSecond.complete();
      final secondResult = await second;
      expect(secondResult, isNull);
      expect(order.contains('second_start'), isFalse);

      expect(await first, 'first');
      expect(await third, 'third');
      // The third waiter still waited for the first holder.
      expect(order.indexOf('first_end'), lessThan(order.indexOf('third_start')));
    });

    test('a cancelled tool call is refused without executing', () async {
      var executed = 0;
      var cancelled = false;
      final runner = SubagentRunner(
        sendRound: (request) async {
          return Stream<ChatStreamChunk>.fromIterable([
            _toolCall('c1', 'file_read'),
            _done(),
          ]);
        },
        onToolCall: (_) async {
          executed++;
          cancelled = true;
          return 'ok';
        },
      );

      await runner.run(
        const SubagentSpec(task: 'stop before second tool'),
        isCancelled: () => cancelled,
      );
      expect(executed, 1);
    });
  });

  group('P0-4 context guard', () {
    test('large tool results are trimmed without touching the caller list',
        () async {
      final requests = <List<Map<String, dynamic>>>[];
      var round = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request.messages);
          round++;
          if (round <= 3) {
            return Stream<ChatStreamChunk>.fromIterable([
              _toolCall('c$round', 'file_read'),
              _done(),
            ]);
          }
          return Stream<ChatStreamChunk>.fromIterable([
            _text('done'),
            _done(),
          ]);
        },
        onToolCall: (_) async => 'x' * 30000,
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'big',
          maxSteps: 5,
          contextWindowTokens: 8000,
          maxOutputTokens: 1024,
        ),
      );

      expect(outcome.contextTrimmed, isTrue);
      expect(outcome.status, 'finished');
      final last = requests.last;
      expect(
        estimateApiMessagesTokens(last),
        lessThanOrEqualTo(8000 - (1024 + 2048)),
      );
      // Every request got its own copy: the kernel's working list (and the
      // previous request) is never mutated by the guard.
      expect(identical(requests[0], requests[1]), isFalse);
      expect(requests[0][0]['content'], contains('subagent'));
    });

    test('a short conversation is left untouched', () async {
      final runner = SubagentRunner(
        sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
          _text('ok'),
          _done(),
        ]),
        onToolCall: (_) async => 'ok',
      );
      final outcome = await runner.run(const SubagentSpec(task: 'short'));
      expect(outcome.contextTrimmed, isFalse);
    });
  });

  group('P1-2 trace', () {
    test('records tool name, duration and result size but no arguments',
        () async {
      var round = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          round++;
          if (round == 1) {
            return Stream<ChatStreamChunk>.fromIterable([
              _toolCall('c1', 'file_read'),
              _toolCall('c2', 'file_grep'),
              _toolCall('c3', 'file_list'),
              _done(),
            ]);
          }
          return Stream<ChatStreamChunk>.fromIterable([
            _text('done'),
            _done(),
          ]);
        },
        onToolCall: (call) async => call.name == 'file_grep' ? 'y' * 42 : 'x',
      );

      final outcome = await runner.run(const SubagentSpec(task: 'trace'));
      expect(outcome.trace, hasLength(3));
      expect(outcome.trace.map((t) => t.tool).toList(), [
        'file_read',
        'file_grep',
        'file_list',
      ]);
      expect(outcome.trace[1].resultChars, 42);
      final json = outcome.toTraceJson();
      expect(json['toolCalls'], 3);
      final items = json['items'] as List;
      expect((items.first as Map).keys.toSet(), {'t', 'ms', 'chars'});
      expect(jsonEncode(json), isNot(contains('arguments')));
    });

    test('caps the trace at 40 rows', () async {
      var round = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          round++;
          if (round == 1) {
            return Stream<ChatStreamChunk>.fromIterable([
              for (var i = 0; i < 45; i++) _toolCall('c$i', 'file_read'),
              _done(),
            ]);
          }
          return Stream<ChatStreamChunk>.fromIterable([
            _text('done'),
            _done(),
          ]);
        },
        onToolCall: (_) async => 'ok',
      );
      final outcome = await runner.run(const SubagentSpec(task: 'many'));
      final json = outcome.toTraceJson();
      expect((json['items'] as List), hasLength(40));
      expect(json['more'], 5);
    });
  });

  group('P1-3 session', () {
    test('reuses initial messages and appends a follow-up task', () async {
      final requests = <List<Map<String, dynamic>>>[];
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request.messages);
          return Stream<ChatStreamChunk>.fromIterable([
            _text('follow-up answer'),
            _done(),
          ]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'second task'),
        initialMessages: [
          {'role': 'system', 'content': 'STABLE SYSTEM'},
          {'role': 'user', 'content': 'Task:\nfirst task'},
          {'role': 'assistant', 'content': 'first answer'},
        ],
        priorTokens: 500,
      );

      expect(requests.single.first['content'], 'STABLE SYSTEM');
      expect(
        requests.single.last['content'].toString(),
        contains('Task (follow-up):\nsecond task'),
      );
      expect(outcome.tokensUsed, 500);
      expect(outcome.transcriptMessages, isNotNull);
    });
  });

  group('P1-5 replay compaction', () {
    test('a 24k summary becomes a small valid stub', () {
      final content = jsonEncode({
        'type': 'subagent_result',
        'status': 'max_steps',
        'summary': 's' * 24000,
        'session_id': 'sub_1',
        'untrusted': true,
      });
      final compact = compactSubagentReplay(content);
      expect(compact.length, lessThan(2500));
      final parsed = jsonDecode(compact) as Map;
      expect(parsed['status'], 'max_steps');
      expect(parsed['session_id'], 'sub_1');
      expect(parsed['replay_truncated'], isTrue);
      expect(parsed['untrusted'], isTrue);
    });

    test('a short payload passes through unchanged', () {
      const content = '{"type":"subagent_result","status":"finished"}';
      expect(compactSubagentReplay(content), content);
    });

    test('malformed JSON is clipped safely', () {
      final compact = compactSubagentReplay('z' * 5000);
      expect(compact.length, lessThan(2500));
    });

    test('image markers are neutralized in live results and replay', () {
      final outcome = SubagentOutcome(
        summary: 'saw [image:/tmp/a.png]',
        stopReason: AgentRunStopReason.finished,
      );
      final json = jsonDecode(outcome.toToolResultJson()) as Map;
      expect(json['summary'], contains('[image-ref: '));
      expect(json['summary'], isNot(contains('[image:')));
      expect(
        compactSubagentReplay(outcome.toToolResultJson()),
        isNot(contains('[image:')),
      );
    });
  });

  group('profiles', () {
    test('built-ins cover the documented ids and read-only sets', () {
      final ids = SubagentProfiles.builtInIds;
      expect(ids.containsAll(['general', 'explore', 'reviewer', 'researcher', 'coder']), isTrue);

      final explore = SubagentProfiles.resolve('explore', SubagentProfiles.builtIns)!;
      expect(explore.readOnly, isTrue);
      expect(explore.permits('file_read'), isTrue);
      expect(explore.permits('file_write'), isFalse);
      expect(explore.permits('shell_run'), isFalse);
      expect(explore.permits('mcp_tool'), isFalse);

      final general = SubagentProfiles.resolve('general', SubagentProfiles.builtIns)!;
      expect(general.permits('file_write'), isTrue);
      expect(general.permits('shell_run'), isTrue);
    });

    test('child tools honor the allowlist and read-only guard', () {
      final parent = <Map<String, dynamic>>[
        for (final name in [
          'file_read',
          'file_write',
          'shell_run',
          'web_fetch',
          spawnSubagentToolName,
        ])
          {
            'type': 'function',
            'function': {'name': name},
          },
      ];
      final explore = SubagentProfiles.resolve('explore', SubagentProfiles.builtIns)!;
      expect(
        subagentChildTools(parent, profile: explore)
            .map((d) => (d['function'] as Map)['name'])
            .toList(),
        ['file_read'],
      );
      expect(subagentChildTools(parent), hasLength(4));
    });

    test('a malformed stored profile is skipped, built-ins survive', () {
      final merged = SubagentProfiles.mergeWithBuiltIns([
        const SubagentProfile(id: 'my_helper', name: 'Mine', description: ''),
        const SubagentProfile(id: 'Bad Id', name: 'Nope', description: ''),
      ]);
      expect(merged.map((p) => p.id), contains('my_helper'));
      expect(merged.map((p) => p.id), contains('general'));
      expect(merged.map((p) => p.id), isNot(contains('Bad Id')));
    });

    test('withProfile binds a model and drops cross-provider headers', () {
      const launch = SubagentLaunchConfig(
        providerKey: 'openai',
        modelId: 'gpt',
        tools: <Map<String, dynamic>>[],
        extraHeaders: {'X-Parent': '1'},
        extraBody: {'parent': true},
        maxTokens: 4096,
        thinkingBudget: 2048,
      );
      const cross = SubagentProfile(
        id: 'x',
        name: 'X',
        description: '',
        providerKey: 'anthropic',
        modelId: 'claude',
      );
      final switched = launch.withProfile(cross);
      expect(switched.providerKey, 'anthropic');
      expect(switched.modelId, 'claude');
      expect(switched.extraHeaders, isNull);
      expect(switched.extraBody, isNull);
      expect(switched.maxTokens, isNull);
      expect(switched.thinkingBudget, isNull);

      const same = SubagentProfile(
        id: 'y',
        name: 'Y',
        description: '',
        providerKey: 'openai',
        modelId: 'gpt-mini',
      );
      final sameProvider = launch.withProfile(same);
      expect(sameProvider.extraHeaders, {'X-Parent': '1'});
      expect(sameProvider.maxTokens, 4096);
    });
  });

  group('P1-7 untrusted contract', () {
    test('the tool result and definition carry the untrusted marker', () {
      final outcome = SubagentOutcome(
        summary: 'summary',
        stopReason: AgentRunStopReason.finished,
      );
      final json = jsonDecode(outcome.toToolResultJson()) as Map;
      expect(json['untrusted'], isTrue);
    });
  });
}
