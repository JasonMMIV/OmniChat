import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_checkpoint.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_checkpoint_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentRunCheckpoint model', () {
    test('round-trips pending tools and soft-stop metadata', () {
      final checkpoint = AgentRunCheckpoint(
        conversationId: 'conv-1',
        assistantMessageId: 'assistant-1',
        stepIndex: 3,
        tokensSoFar: 1200,
        phase: agentRunPhaseSoftStopped,
        updatedAtMs: 123456,
        softStopReason: 'max_steps',
        runId: 'run-1',
        pendingTools: const <AgentRunPendingTool>[
          AgentRunPendingTool(
            id: 'call-1',
            name: 'shell_run',
            kind: 'approval',
          ),
          AgentRunPendingTool(id: 'call-2', name: 'ask_user', kind: 'ask_user'),
        ],
      );

      final decoded = AgentRunCheckpoint.tryDecode(checkpoint.encode());

      expect(decoded, isNotNull);
      expect(decoded!.conversationId, 'conv-1');
      expect(decoded.assistantMessageId, 'assistant-1');
      expect(decoded.stepIndex, 3);
      expect(decoded.tokensSoFar, 1200);
      expect(decoded.phase, agentRunPhaseSoftStopped);
      expect(decoded.softStopReason, 'max_steps');
      expect(decoded.runId, 'run-1');
      expect(decoded.pendingTools, hasLength(2));
      expect(decoded.pendingTools.first.isApproval, isTrue);
      expect(decoded.pendingTools.last.isAskUser, isTrue);
    });

    test('rejects missing identifiers and negative counters', () {
      expect(AgentRunCheckpoint.tryDecode('not json'), isNull);
      expect(
        AgentRunCheckpoint.tryDecode(
          '{"conversationId":"","assistantMessageId":"a",'
          '"stepIndex":0,"tokensSoFar":0,"updatedAtMs":1}',
        ),
        isNull,
      );
      expect(
        AgentRunCheckpoint.tryDecode(
          '{"conversationId":"c","assistantMessageId":"a",'
          '"stepIndex":-1,"tokensSoFar":0,"updatedAtMs":1}',
        ),
        isNull,
      );
    });

    test('normalizes an unknown phase to interrupted', () {
      final decoded = AgentRunCheckpoint.tryDecode(
        '{"conversationId":"c","assistantMessageId":"a",'
        '"stepIndex":0,"tokensSoFar":0,"updatedAtMs":1,"phase":"future"}',
      );
      expect(decoded?.phase, agentRunPhaseInterrupted);
    });

    test('copyWith can clear softStopReason and preserve runId', () {
      final checkpoint = AgentRunCheckpoint(
        conversationId: 'c',
        assistantMessageId: 'a',
        stepIndex: 0,
        tokensSoFar: 0,
        phase: agentRunPhaseSoftStopped,
        updatedAtMs: 1,
        softStopReason: 'max_steps',
        runId: 'run-1',
      );

      final cleared = checkpoint.copyWith(clearSoftStopReason: true);

      expect(cleared.softStopReason, isNull);
      expect(cleared.runId, 'run-1');
    });
  });

  group('AgentRunCheckpointStore', () {
    const boxName = 'agent_runs_v1_test';
    late Directory tempDir;
    late AgentRunCheckpointStore store;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('omni_agent_runs_');
      Hive.init(tempDir.path);
    });

    setUp(() async {
      store = AgentRunCheckpointStore(boxName: boxName);
      await store.debugReset();
    });

    tearDown(() async {
      await store.close();
    });

    tearDownAll(() async {
      await Hive.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    AgentRunCheckpoint checkpoint({
      required String conversationId,
      int updatedAtMs = 1000,
      String phase = agentRunPhaseRunning,
    }) {
      return AgentRunCheckpoint(
        conversationId: conversationId,
        assistantMessageId: 'assistant-$conversationId',
        stepIndex: 1,
        tokensSoFar: 42,
        phase: phase,
        updatedAtMs: updatedAtMs,
      );
    }

    test('persists, loads and selects the newest checkpoint', () async {
      await store.save(checkpoint(conversationId: 'older', updatedAtMs: 1000));
      await store.save(
        checkpoint(
          conversationId: 'newer',
          updatedAtMs: 2000,
          phase: agentRunPhasePaused,
        ),
      );

      expect((await store.load('older'))?.conversationId, 'older');
      expect((await store.load('missing')), isNull);

      final latest = await store.latest();
      expect(latest?.conversationId, 'newer');
      expect(latest?.phase, agentRunPhasePaused);
    });

    test('deletes a corrupt row while keeping valid checkpoints', () async {
      await store.save(checkpoint(conversationId: 'valid'));
      final box = Hive.box<dynamic>(boxName);
      await box.put('corrupt', '{not-json');

      final latest = await store.latest();

      expect(latest?.conversationId, 'valid');
      expect(box.containsKey('corrupt'), isFalse);
    });

    test('delete and clearAll remove the journal entries', () async {
      await store.save(checkpoint(conversationId: 'one'));
      await store.save(checkpoint(conversationId: 'two'));

      await store.delete('one');
      expect(await store.load('one'), isNull);
      expect(await store.load('two'), isNotNull);

      await store.clearAll();
      expect(await store.latest(), isNull);
    });
  });
}
