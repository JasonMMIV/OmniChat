import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_request.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';

ChatStreamChunk _text(String content, {int total = 0}) =>
    ChatStreamChunk(content: content, isDone: false, totalTokens: total);

ChatStreamChunk _done({int total = 0}) =>
    ChatStreamChunk(content: '', isDone: true, totalTokens: total);

ChatStreamChunk _toolCall(String id, String name) => ChatStreamChunk(
  content: '',
  isDone: false,
  totalTokens: 0,
  toolCalls: [ToolCallInfo(id: id, name: name, arguments: const {})],
);

void main() {
  group('wrap-up cancellation', () {
    test('a wrap-up timeout aborts the summary transport', () async {
      final aborted = <String>[];
      final hang = StreamController<ChatStreamChunk>();
      addTearDown(hang.close);

      final runner = SubagentRunner(
        sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
          _text('working'),
          _toolCall('c1', 'file_read'),
          _done(),
        ]),
        sendWrapUpRound: (request) async => hang.stream,
        onAbortRequest: aborted.add,
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'timeout the wrap-up',
          maxSteps: 1,
          requestId: 'run',
          wrapUpTimeout: Duration(milliseconds: 30),
        ),
      );

      expect(aborted, <String>['run_summary']);
      expect(outcome.status, 'max_steps');
      expect(outcome.summary, 'working');
      expect(outcome.summarySource, SubagentSummarySource.preamble);
    });

    test('a timeout still produces a wrap-up summary', () async {
      final hang = StreamController<ChatStreamChunk>();
      addTearDown(hang.close);

      final runner = SubagentRunner(
        sendRound: (request) async {
          hang.add(_text('partial'));
          return hang.stream;
        },
        sendWrapUpRound: (request) async =>
            Stream<ChatStreamChunk>.fromIterable([
              _text('FINAL DELIVERABLE'),
              _done(total: 12),
            ]),
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'timeout',
          requestId: 't',
          timeout: Duration(milliseconds: 60),
          wrapUpTimeout: Duration(milliseconds: 40),
        ),
      );

      expect(outcome.timedOut, isTrue);
      expect(outcome.status, 'timeout');
      expect(outcome.summary, 'FINAL DELIVERABLE');
      expect(outcome.summarySource, SubagentSummarySource.wrapUp);
      expect(outcome.partial, isTrue);
    });

    test('a token-budget stop still produces a wrap-up summary', () async {
      var round = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          round++;
          if (round == 1) {
            return Stream<ChatStreamChunk>.fromIterable([
              _text('working'),
              _toolCall('c1', 'file_read'),
              _done(total: 2000),
            ]);
          }
          return Stream<ChatStreamChunk>.fromIterable([
            _text('unexpected'),
            _done(),
          ]);
        },
        sendWrapUpRound: (request) async =>
            Stream<ChatStreamChunk>.fromIterable([
              _text('BUDGET WRAP-UP'),
              _done(),
            ]),
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'budget', tokenBudget: 1000),
      );

      expect(outcome.status, 'token_budget');
      expect(outcome.summary, 'BUDGET WRAP-UP');
      expect(outcome.summarySource, SubagentSummarySource.wrapUp);
      expect(outcome.partial, isTrue);
    });
  });

  group('main deadline abort', () {
    test('a wrap-up that cannot fit inside the deadline is skipped', () async {
      final hang = StreamController<ChatStreamChunk>();
      addTearDown(hang.close);
      var wrapUpCalls = 0;

      final runner = SubagentRunner(
        sendRound: (request) async => hang.stream,
        sendWrapUpRound: (request) async {
          wrapUpCalls++;
          return const Stream<ChatStreamChunk>.empty();
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'short deadline',
          timeout: Duration(milliseconds: 50),
          wrapUpTimeout: Duration(milliseconds: 80),
        ),
      );

      expect(outcome.timedOut, isTrue);
      expect(wrapUpCalls, 0);
    });

    test('the main deadline calls onAbort before the settle wait', () async {
      final hang = StreamController<ChatStreamChunk>();
      addTearDown(hang.close);
      var aborts = 0;

      final runner = SubagentRunner(
        sendRound: (request) async => hang.stream,
        onAbort: () => aborts++,
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'abort me',
          timeout: Duration(milliseconds: 40),
          wrapUpTimeout: Duration.zero,
        ),
      );

      expect(outcome.timedOut, isTrue);
      expect(aborts, 1);
    });
  });

  group('cancelled runs', () {
    test('a clean-ended cancelled run never reports a final answer', () async {
      var cancelled = false;
      final runner = SubagentRunner(
        sendRound: (request) async {
          cancelled = true;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('partial answer'),
            _done(),
          ]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'cancel'),
        isCancelled: () => cancelled,
      );

      expect(outcome.cancelled, isTrue);
      expect(outcome.status, 'stopped');
      expect(outcome.summary, isEmpty);
      expect(outcome.summarySource, SubagentSummarySource.none);
    });

    test('a stop during a hanging wrap-up returns promptly', () async {
      final wrap = StreamController<ChatStreamChunk>();
      addTearDown(wrap.close);
      final started = Completer<void>();
      final cancel = Completer<void>();

      final runner = SubagentRunner(
        sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
          _text('working'),
          _toolCall('c1', 'file_read'),
          _done(),
        ]),
        sendWrapUpRound: (request) async {
          if (!started.isCompleted) started.complete();
          return wrap.stream;
        },
        onToolCall: (_) async => 'ok',
      );

      // Deliberately no isCancelled polling: the cancel future alone must
      // still produce a stopped outcome, not a preamble fallback.
      final run = runner.run(
        const SubagentSpec(task: 'stop during hanging wrap-up', maxSteps: 1),
        cancelFuture: cancel.future,
      );
      await started.future;
      final watch = Stopwatch()..start();
      cancel.complete();
      final outcome = await run.timeout(const Duration(seconds: 2));
      watch.stop();

      expect(outcome.cancelled, isTrue);
      expect(outcome.status, 'stopped');
      expect(outcome.summary, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('a stop during the wrap-up discards the wrap-up text', () async {
      var cancelled = false;
      final runner = SubagentRunner(
        sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
          _text('working'),
          _toolCall('c1', 'file_read'),
          _done(),
        ]),
        sendWrapUpRound: (request) async {
          cancelled = true;
          return Stream<ChatStreamChunk>.fromIterable([
            _text('SHOULD NOT BECOME THE SUMMARY'),
            _done(),
          ]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(task: 'stop during wrap-up', maxSteps: 1),
        isCancelled: () => cancelled,
      );

      expect(outcome.cancelled, isTrue);
      expect(outcome.status, 'stopped');
      expect(outcome.summary, isEmpty);
    });
  });

  group('observability and context', () {
    test('steps count completed rounds when the run times out', () async {
      var round = 0;
      final hang = StreamController<ChatStreamChunk>();
      addTearDown(hang.close);

      final runner = SubagentRunner(
        sendRound: (request) async {
          round++;
          if (round == 1) {
            return Stream<ChatStreamChunk>.fromIterable([
              _toolCall('c1', 'file_read'),
              _done(),
            ]);
          }
          return hang.stream;
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'steps',
          timeout: Duration(milliseconds: 70),
          wrapUpTimeout: Duration.zero,
        ),
      );

      expect(outcome.timedOut, isTrue);
      expect(outcome.steps, 1);
    });

    test('context trimming keeps the original task', () async {
      final requests = <List<Map<String, dynamic>>>[];
      var round = 0;
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request.messages);
          round++;
          if (round <= 2) {
            return Stream<ChatStreamChunk>.fromIterable([
              _toolCall('c$round', 'file_read'),
              _done(),
            ]);
          }
          return Stream<ChatStreamChunk>.fromIterable([_text('done'), _done()]);
        },
        onToolCall: (_) async => 'r' * 30000,
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'ORIGINAL TASK: inspect every file and report the findings',
          maxSteps: 5,
          contextWindowTokens: 4000,
          maxOutputTokens: 512,
        ),
      );

      expect(outcome.contextTrimmed, isTrue);
      final last = jsonEncode(requests.last);
      expect(last, contains('ORIGINAL TASK'));
    });

    test(
      'a resumed run pins the current follow-up, not the original task',
      () async {
        final requests = <List<Map<String, dynamic>>>[];
        final runner = SubagentRunner(
          sendRound: (request) async {
            requests.add(request.messages);
            return Stream<ChatStreamChunk>.fromIterable([
              _text('done'),
              _done(),
            ]);
          },
          onToolCall: (_) async => 'ok',
        );

        final outcome = await runner.run(
          const SubagentSpec(
            task: 'CURRENT FOLLOW-UP',
            contextWindowTokens: 1000,
            maxOutputTokens: 512,
          ),
          initialMessages: <Map<String, dynamic>>[
            {'role': 'system', 'content': 'sys'},
            {'role': 'user', 'content': 'ORIGINAL TASK ${'o' * 20000}'},
            {'role': 'assistant', 'content': 'working'},
          ],
        );

        expect(outcome.contextTrimmed, isTrue);
        final last = jsonEncode(requests.last);
        expect(last, contains('CURRENT FOLLOW-UP'));
        expect(
          'CURRENT FOLLOW-UP'.allMatches(last).length,
          1,
          reason: 'the pinned follow-up must not be duplicated',
        );
        expect(last, isNot(contains('ORIGINAL TASK')));
      },
    );
  });

  group('session and wire contract', () {
    test('a resumed run keeps the session id on every request', () async {
      final requests = <SubagentRoundRequest>[];
      final runner = SubagentRunner(
        sendRound: (request) async {
          requests.add(request);
          return Stream<ChatStreamChunk>.fromIterable([_text('done'), _done()]);
        },
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(
        const SubagentSpec(
          task: 'follow-up',
          sessionId: 'session-1',
          requestId: 'run-2',
        ),
        initialMessages: const [
          {'role': 'system', 'content': 'STABLE SYSTEM'},
          {'role': 'user', 'content': 'Task:\nfirst'},
        ],
      );

      expect(requests.single.sessionId, 'session-1');
      expect(requests.single.requestId, 'run-2');
      expect(outcome.sessionId, 'session-1');
    });

    test('decorateRequest fills the effective wire values', () async {
      final seen = <SubagentRoundRequest>[];
      final runner = SubagentRunner(
        sendRound: (request) async {
          seen.add(request);
          return Stream<ChatStreamChunk>.fromIterable([_text('done'), _done()]);
        },
        decorateRequest: (request) => request.copyWith(
          providerKey: 'provider-x',
          modelId: 'model-y',
          tools: const [],
          maxTokens: 1234,
          temperature: 0.25,
          topP: 0.75,
          thinkingBudget: 2048,
          toolImagesEnabled: false,
          requestId: 'decorated-run',
          sessionId: 'decorated-session',
        ),
        onToolCall: (_) async => 'ok',
      );

      await runner.run(const SubagentSpec(task: 'wire'));

      final request = seen.single;
      expect(request.providerKey, 'provider-x');
      expect(request.modelId, 'model-y');
      expect(request.tools, isEmpty);
      expect(request.maxTokens, 1234);
      expect(request.temperature, 0.25);
      expect(request.topP, 0.75);
      expect(request.thinkingBudget, 2048);
      expect(request.toolImagesEnabled, isFalse);
      expect(request.requestId, 'decorated-run');
      expect(request.sessionId, 'decorated-session');
    });

    test(
      'decorateRequest also applies to the text-only wrap-up request',
      () async {
        SubagentRoundRequest? summaryRequest;
        final runner = SubagentRunner(
          sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
            _toolCall('c1', 'file_read'),
            _done(),
          ]),
          sendWrapUpRound: (request) async {
            summaryRequest = request;
            return Stream<ChatStreamChunk>.fromIterable([
              _text('summary'),
              _done(),
            ]);
          },
          decorateRequest: (request) => request.copyWith(
            providerKey: 'provider-x',
            modelId: 'model-y',
            sessionId: 'session-z',
          ),
          onToolCall: (_) async => 'ok',
        );

        await runner.run(
          const SubagentSpec(task: 'wrap', maxSteps: 1, requestId: 'run-z'),
        );

        expect(summaryRequest, isNotNull);
        expect(summaryRequest!.textOnly, isTrue);
        expect(summaryRequest!.tools, isNull);
        expect(summaryRequest!.providerKey, 'provider-x');
        expect(summaryRequest!.modelId, 'model-y');
        expect(summaryRequest!.sessionId, 'session-z');
        expect(summaryRequest!.requestId, 'run-z_summary');
      },
    );
  });

  group('tool-result JSON contract', () {
    test('the summary is wrapped and marked untrusted', () {
      const outcome = SubagentOutcome(
        summary: 'deliverable',
        stopReason: AgentRunStopReason.finished,
        sessionId: 's1',
      );
      final json = jsonDecode(outcome.toToolResultJson()) as Map;
      expect(json['summary'], contains('<subagent_summary>'));
      expect(json['summary'], contains('deliverable'));
      expect(json['summary'], contains('</subagent_summary>'));
      expect(json['untrusted'], isTrue);
      expect(json['session_id'], 's1');
    });

    test('JSON escaping cannot push the encoded payload over the cap', () {
      final outcome = SubagentOutcome(
        summary: '"' * 24000,
        stopReason: AgentRunStopReason.finished,
      );
      final raw = outcome.toToolResultJson();
      expect(raw.length, lessThan(SubagentOutcome.maxEncodedChars + 1));
      final json = jsonDecode(raw) as Map;
      expect(json['status'], 'finished');
      expect(json['summary_truncated'], isTrue);
      expect(json['summary'], contains('<subagent_summary>'));
    });

    test('control-character escaping still respects the cap', () {
      final outcome = SubagentOutcome(
        summary: '' * 24000,
        stopReason: AgentRunStopReason.finished,
      );
      final raw = outcome.toToolResultJson();
      expect(raw.length, lessThan(SubagentOutcome.maxEncodedChars + 1));
      final json = jsonDecode(raw) as Map;
      expect(json['summary_truncated'], isTrue);
    });
  });

  group('session transcript', () {
    test('a finished answer is appended to the resumable transcript', () async {
      final runner = SubagentRunner(
        sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
          _text('FINAL ANSWER'),
          _done(),
        ]),
        onToolCall: (_) async => 'ok',
      );

      final outcome = await runner.run(const SubagentSpec(task: 'answer'));
      final transcript = outcome.transcriptMessages!;
      expect(transcript.last['role'], 'assistant');
      expect(transcript.last['content'], 'FINAL ANSWER');
    });

    test(
      'a long session transcript is capped with its system prefix',
      () async {
        final runner = SubagentRunner(
          sendRound: (request) async =>
              Stream<ChatStreamChunk>.fromIterable([_text('FINAL'), _done()]),
          onToolCall: (_) async => 'ok',
        );

        final outcome = await runner.run(
          const SubagentSpec(task: 'cap the transcript'),
          initialMessages: <Map<String, dynamic>>[
            {'role': 'system', 'content': 'sys'},
            for (var i = 0; i < 300; i++)
              {
                'role': i.isEven ? 'user' : 'assistant',
                'content': 'history $i',
              },
          ],
        );

        final transcript = outcome.transcriptMessages!;
        expect(
          transcript.length,
          lessThanOrEqualTo(SubagentRunner.maxStoredTranscriptMessages),
        );
        expect(transcript.first['role'], 'system');
        expect(transcript.last['role'], 'assistant');
        expect(transcript.last['content'], 'FINAL');
      },
    );

    test('withSessionId can clear a never-stored session id', () {
      const outcome = SubagentOutcome(summary: 'x', sessionId: 'run-1');
      expect(outcome.withSessionId(null, clear: true).sessionId, isNull);
      expect(outcome.withSessionId('session-2').sessionId, 'session-2');
    });
  });

  group('serial tool execution', () {
    test('two helpers never execute tools concurrently', () async {
      final gate = SerialGate();
      var active = 0;
      var maxActive = 0;

      SubagentRunner makeRunner() {
        var round = 0;
        return SubagentRunner(
          gate: gate,
          sendRound: (request) async {
            round++;
            if (round == 1) {
              return Stream<ChatStreamChunk>.fromIterable([
                _toolCall('c1', 'file_read'),
                _done(),
              ]);
            }
            return Stream<ChatStreamChunk>.fromIterable([
              _text('done'),
              _done(),
            ]);
          },
          onToolCall: (_) async {
            active++;
            if (active > maxActive) maxActive = active;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            active--;
            return 'ok';
          },
        );
      }

      await Future.wait([
        makeRunner().run(const SubagentSpec(task: 'one')),
        makeRunner().run(const SubagentSpec(task: 'two')),
      ]);

      expect(maxActive, 1);
    });
  });

  group('soak', () {
    test('20 max_steps runs all produce a wrap-up summary', () async {
      for (var i = 0; i < 20; i++) {
        final runner = SubagentRunner(
          sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
            _text('working $i'),
            _toolCall('c$i', 'file_read'),
            _done(),
          ]),
          sendWrapUpRound: (request) async =>
              Stream<ChatStreamChunk>.fromIterable([
                _text('FINAL $i'),
                _done(),
              ]),
          onToolCall: (_) async => 'ok',
        );
        final outcome = await runner.run(
          SubagentSpec(task: 'soak $i', maxSteps: 1, requestId: 'soak-$i'),
        );
        expect(outcome.summary, 'FINAL $i');
        expect(outcome.summarySource, SubagentSummarySource.wrapUp);
        expect(outcome.status, 'max_steps');
      }
    });

    test('10 timeout runs all produce a wrap-up summary', () async {
      for (var i = 0; i < 10; i++) {
        final hang = StreamController<ChatStreamChunk>();
        final runner = SubagentRunner(
          sendRound: (request) async => hang.stream,
          sendWrapUpRound: (request) async =>
              Stream<ChatStreamChunk>.fromIterable([
                _text('TIMEOUT FINAL $i'),
                _done(),
              ]),
          onToolCall: (_) async => 'ok',
        );
        final outcome = await runner.run(
          SubagentSpec(
            task: 'timeout soak $i',
            requestId: 'timeout-$i',
            timeout: const Duration(milliseconds: 50),
            wrapUpTimeout: const Duration(milliseconds: 25),
          ),
        );
        await hang.close();
        expect(outcome.summary, 'TIMEOUT FINAL $i');
        expect(outcome.summarySource, SubagentSummarySource.wrapUp);
        expect(outcome.status, 'timeout');
      }
    });
  });
}
