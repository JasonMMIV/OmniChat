// P2-1: durable run journal lifecycle. These tests lock the behaviour that
// used to be untested in ChatActions: write-before-dispatch, pending veto,
// unknown-vs-none, terminal classification, session degradation and the
// in-process run fence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_checkpoint.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_journal.dart';

class _FakeSink implements AgentRunCheckpointSink {
  final List<AgentRunCheckpoint> saved = <AgentRunCheckpoint>[];
  final List<String> deleted = <String>[];
  Duration delay = Duration.zero;
  Object? failNext;
  int saveCalls = 0;

  @override
  Future<void> save(AgentRunCheckpoint checkpoint) async {
    saveCalls++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    saved.add(checkpoint);
  }

  @override
  Future<void> delete(String conversationId) async {
    deleted.add(conversationId);
  }
}

AgentRunPendingTool _approval(String id) =>
    AgentRunPendingTool(id: id, name: 'shell_run', kind: 'approval');

AgentRunPendingSnapshot _known(List<AgentRunPendingTool> tools) =>
    AgentRunPendingSnapshot.known(tools);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentRunJournal', () {
    late _FakeSink sink;
    late AgentRunFence fence;
    late AgentRunPendingSnapshot pending;
    late AgentRunJournal journal;

    setUp(() {
      sink = _FakeSink();
      fence = AgentRunFence();
      pending = const AgentRunPendingSnapshot.unknown();
      journal = AgentRunJournal(
        store: sink,
        conversationId: 'conv-1',
        assistantMessageId: 'msg-1',
        resolvePending: () async => pending,
        fence: fence,
        runId: 'run-1',
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
    });

    test('onRoundStart waits for the durable write before returning', () async {
      sink.delay = const Duration(milliseconds: 20);
      final future = journal.onRoundStart(0, 0);

      expect(sink.saveCalls, 1);
      expect(sink.saved, isEmpty);

      expect(await future, isTrue);
      expect(sink.saved, hasLength(1));
      expect(sink.saved.single.phase, agentRunPhaseRunning);
      expect(sink.saved.single.runId, 'run-1');
      expect(journal.hasWritten, isTrue);
    });

    test('a pending card writes paused and vetoes the next round', () async {
      pending = _known(<AgentRunPendingTool>[_approval('call-1')]);

      expect(await journal.onRoundStart(1, 1234), isFalse);

      expect(sink.saved.single.phase, agentRunPhasePaused);
      expect(sink.saved.single.pendingTools.single.id, 'call-1');
      expect(sink.saved.single.stepIndex, 1);
      expect(sink.saved.single.tokensSoFar, 1234);
    });

    test('unknown pending state keeps the last known pause', () async {
      pending = _known(<AgentRunPendingTool>[_approval('call-1')]);
      expect(await journal.onRoundStart(1, 0), isFalse);

      pending = const AgentRunPendingSnapshot.unknown();
      expect(await journal.onRoundStart(2, 0), isFalse);

      expect(sink.saved.last.phase, agentRunPhasePaused);
      expect(sink.saved.last.pendingTools.single.id, 'call-1');
    });

    test('onRoundEnd advances the step and records running', () async {
      await journal.onRoundStart(0, 0);
      pending = _known(const <AgentRunPendingTool>[]);

      await journal.onRoundEnd(0);

      expect(sink.saved.last.stepIndex, 1);
      expect(sink.saved.last.phase, agentRunPhaseRunning);
    });

    test('tool results write only on pending transitions', () async {
      await journal.onRoundStart(0, 0);
      sink.saved.clear();

      pending = _known(const <AgentRunPendingTool>[]);
      await journal.onToolResults();
      expect(sink.saved, isEmpty);

      pending = _known(<AgentRunPendingTool>[_approval('call-1')]);
      await journal.onToolResults();
      expect(sink.saved.single.phase, agentRunPhasePaused);

      pending = _known(const <AgentRunPendingTool>[]);
      await journal.onToolResults();
      expect(sink.saved.last.phase, agentRunPhaseRunning);
    });

    test('repeated pending tool results do not re-flush the pause', () async {
      await journal.onRoundStart(0, 0);
      sink.saved.clear();

      pending = _known(<AgentRunPendingTool>[_approval('call-1')]);
      await journal.onToolResults();
      expect(sink.saved, hasLength(1));

      // Same pending list (e.g. a later tool result in the same round).
      await journal.onToolResults();
      expect(sink.saved, hasLength(1));

      // A second card is a real state change.
      pending = _known(<AgentRunPendingTool>[
        _approval('call-1'),
        _approval('call-2'),
      ]);
      await journal.onToolResults();
      expect(sink.saved, hasLength(2));
    });

    test('onError records interrupted with the current pending list', () async {
      await journal.onRoundStart(0, 0);
      pending = _known(<AgentRunPendingTool>[_approval('call-1')]);

      await journal.onError();

      expect(sink.saved.last.phase, agentRunPhaseInterrupted);
      expect(sink.saved.last.pendingTools.single.id, 'call-1');
    });

    test(
      'terminal before the first write does not delete an older row',
      () async {
        await journal.onDone();
        expect(sink.deleted, isEmpty);
      },
    );

    test('onDone clears the journal on ordinary completion', () async {
      await journal.onRoundStart(0, 0);
      pending = _known(const <AgentRunPendingTool>[]);

      await journal.onDone();

      expect(sink.deleted, <String>['conv-1']);
    });

    test('onDone keeps a soft-stopped checkpoint', () async {
      await journal.onRoundStart(0, 0);
      pending = _known(const <AgentRunPendingTool>[]);

      await journal.onDone(softStopReason: 'max_steps');

      expect(sink.saved.last.phase, agentRunPhaseSoftStopped);
      expect(sink.saved.last.softStopReason, 'max_steps');
      expect(sink.deleted, isEmpty);
    });

    test('onDone keeps a pending pause checkpoint', () async {
      await journal.onRoundStart(0, 0);
      pending = _known(<AgentRunPendingTool>[_approval('call-1')]);

      await journal.onDone();

      expect(sink.saved.last.phase, agentRunPhasePaused);
      expect(sink.saved.last.pendingTools.single.id, 'call-1');
      expect(sink.deleted, isEmpty);
    });

    test('onDone with unknown pending state does not clear the row', () async {
      await journal.onRoundStart(0, 0);
      sink.saved.clear();
      pending = const AgentRunPendingSnapshot.unknown();

      await journal.onDone();

      expect(sink.saved, isEmpty);
      expect(sink.deleted, isEmpty);
    });

    test(
      'a write failure disables the journal but lets the run continue',
      () async {
        sink.failNext = StateError('disk full');

        expect(await journal.onRoundStart(0, 0), isTrue);
        expect(journal.disabled, isTrue);
        expect(sink.saved, isEmpty);

        pending = _known(<AgentRunPendingTool>[_approval('call-1')]);
        expect(await journal.onRoundStart(1, 0), isFalse);
        expect(sink.saveCalls, 1);
      },
    );

    test('a newer run fences out the old journal', () async {
      await journal.onRoundStart(0, 0);
      sink.saved.clear();

      final newer = AgentRunJournal(
        store: sink,
        conversationId: 'conv-1',
        assistantMessageId: 'msg-2',
        resolvePending: () async => _known(const <AgentRunPendingTool>[]),
        fence: fence,
        runId: 'run-2',
      );

      await journal.onRoundStart(1, 0);
      expect(sink.saved, isEmpty);

      await newer.onRoundStart(0, 0);
      expect(sink.saved.single.assistantMessageId, 'msg-2');

      await journal.onDone();
      expect(sink.deleted, isEmpty);

      await newer.onDone();
      expect(sink.deleted, <String>['conv-1']);
    });

    test('cancel invalidates the current journal', () async {
      expect(fence.cancel('conv-1'), isTrue);

      await journal.onRoundStart(0, 0);

      expect(sink.saved, isEmpty);
    });
  });
}
