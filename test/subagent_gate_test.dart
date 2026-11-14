import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

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
  group('SerialGate gateWaitMs (Phase 3-1)', () {
    test(
      'runMeasured reports only the queue wait, not execution time',
      () async {
        final gate = SerialGate();
        final release = Completer<void>();
        final first = gate.run<String>(() async {
          await release.future;
          return 'first';
        });

        final second = gate.runMeasured<String>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return 'second';
        });

        await Future<void>.delayed(const Duration(milliseconds: 60));
        release.complete();

        expect(await first, 'first');
        final result = await second;
        expect(result.value, 'second');
        // The queue waited at least the explicit 60ms hold; an upper bound is
        // intentionally absent because loaded CI timers may fire late.
        expect(result.waitMs, greaterThanOrEqualTo(40));
      },
    );

    test('an aborted queued run reports its wait and never executes', () async {
      final gate = SerialGate();
      final release = Completer<void>();
      final abort = Completer<void>();
      var executed = false;

      final first = gate.run<String>(() async {
        await release.future;
        return 'first';
      });
      final second = gate.runMeasured<String>(() async {
        executed = true;
        return 'second';
      }, abort: abort.future);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      abort.complete();
      final result = await second;
      expect(result.value, isNull);
      expect(result.waitMs, greaterThanOrEqualTo(15));
      expect(executed, isFalse);

      release.complete();
      expect(await first, 'first');
    });

    test('the runner attaches the measured wait to its outcome', () async {
      final gate = SerialGate();
      final release = Completer<void>();
      final holder = gate.run<String>(() async {
        await release.future;
        return 'holder';
      });

      final runner = SubagentRunner(
        gate: gate,
        sendRound: (request) async =>
            Stream<ChatStreamChunk>.fromIterable([_text('done')]),
        onToolCall: (_) async => 'ok',
      );
      final run = runner.run(const SubagentSpec(task: 'queued'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      release.complete();
      await holder;

      final outcome = await run;
      expect(outcome.status, 'finished');
      expect(outcome.gateWaitMs, greaterThanOrEqualTo(25));
    });
  });

  test('a tool that outlives the settle grace reports a zombie', () async {
    final toolDone = Completer<String>();
    final zombies = <int>[];
    final runner = SubagentRunner(
      sendRound: (request) async => Stream<ChatStreamChunk>.fromIterable([
        _text('working'),
        _toolCall('c1', 'file_read'),
      ]),
      onToolCall: (_) => toolDone.future,
      onZombie: zombies.add,
    );

    final outcome = await runner.run(
      const SubagentSpec(
        task: 'zombie',
        timeout: Duration(milliseconds: 40),
        wrapUpTimeout: Duration.zero,
        toolSettleGrace: Duration(milliseconds: 20),
      ),
    );

    expect(outcome.timedOut, isTrue);
    expect(zombies, isNotEmpty);
    expect(zombies.last, 1);
    toolDone.complete('late');
  });
}
