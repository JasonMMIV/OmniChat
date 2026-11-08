import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_checkpoint.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_checkpoint_store.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_task.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_task_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentRunTask', () {
    AgentRunCheckpoint checkpoint({
      required String conversationId,
      String phase = agentRunPhaseRunning,
      int updatedAtMs = 1,
      List<AgentRunPendingTool> pendingTools = const <AgentRunPendingTool>[],
      String? softStopReason,
    }) {
      return AgentRunCheckpoint(
        conversationId: conversationId,
        assistantMessageId: 'assistant-$conversationId',
        stepIndex: 2,
        tokensSoFar: 10,
        phase: phase,
        updatedAtMs: updatedAtMs,
        pendingTools: pendingTools,
        softStopReason: softStopReason,
      );
    }

    test('maps pause kinds, soft stops and crashes to distinct reasons', () {
      final approval = AgentRunTask.fromCheckpoint(
        checkpoint(
          conversationId: 'approval',
          phase: agentRunPhasePaused,
          pendingTools: const <AgentRunPendingTool>[
            AgentRunPendingTool(
              id: 'call-1',
              name: 'shell_run',
              kind: 'approval',
            ),
          ],
        ),
      );
      final askUser = AgentRunTask.fromCheckpoint(
        checkpoint(
          conversationId: 'ask',
          phase: agentRunPhasePaused,
          pendingTools: const <AgentRunPendingTool>[
            AgentRunPendingTool(id: 'call-2', name: 'ask_user', kind: 'ask_user'),
          ],
        ),
      );
      final interrupted = AgentRunTask.fromCheckpoint(
        checkpoint(
          conversationId: 'interrupted',
          phase: agentRunPhaseInterrupted,
        ),
      );
      final running = AgentRunTask.fromCheckpoint(
        checkpoint(conversationId: 'running'),
      );
      final softStop = AgentRunTask.fromCheckpoint(
        checkpoint(
          conversationId: 'soft',
          phase: agentRunPhaseSoftStopped,
          softStopReason: 'max_steps',
        ),
      );

      expect(approval.reason, AgentRunTaskReason.approval);
      expect(approval.requiresUserAction, isTrue);
      expect(askUser.reason, AgentRunTaskReason.askUser);
      expect(askUser.requiresUserAction, isTrue);
      expect(interrupted.reason, AgentRunTaskReason.interrupted);
      expect(interrupted.requiresUserAction, isFalse);
      expect(running.reason, AgentRunTaskReason.running);
      expect(softStop.reason, AgentRunTaskReason.softStopped);
      expect(softStop.checkpoint.softStopReason, 'max_steps');
    });

    test('paused without a pending card is treated as interrupted', () {
      final task = AgentRunTask.fromCheckpoint(
        checkpoint(
          conversationId: 'paused-empty',
          phase: agentRunPhasePaused,
        ),
      );

      expect(task.reason, AgentRunTaskReason.interrupted);
    });

    test('selects the pending tool that matches the ask-user priority', () {
      final task = AgentRunTask.fromCheckpoint(
        checkpoint(
          conversationId: 'mixed-pending',
          phase: agentRunPhasePaused,
          pendingTools: const <AgentRunPendingTool>[
            AgentRunPendingTool(
              id: 'call-approval',
              name: 'shell_run',
              kind: 'approval',
            ),
            AgentRunPendingTool(
              id: 'call-ask',
              name: 'ask_user',
              kind: 'ask_user',
            ),
          ],
        ),
      );

      expect(task.reason, AgentRunTaskReason.askUser);
      expect(task.primaryPendingTool?.name, 'ask_user');
    });

    test('sorts newest first', () {
      final older = AgentRunTask.fromCheckpoint(
        checkpoint(conversationId: 'older', updatedAtMs: 1000),
      );
      final newer = AgentRunTask.fromCheckpoint(
        checkpoint(conversationId: 'newer', updatedAtMs: 3000),
      );
      final tasks = <AgentRunTask>[older, newer]
        ..sort(AgentRunTask.compareNewestFirst);

      expect(
        tasks.map((task) => task.checkpoint.conversationId).toList(),
        <String>['newer', 'older'],
      );
    });
  });

  group('AgentRunTaskService', () {
    const boxName = 'agent_runs_tasks_test';
    late Directory tempDir;
    late AgentRunCheckpointStore store;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('omni_agent_tasks_');
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
      required int updatedAtMs,
      String phase = agentRunPhaseInterrupted,
    }) {
      return AgentRunCheckpoint(
        conversationId: conversationId,
        assistantMessageId: 'assistant-$conversationId',
        stepIndex: 1,
        tokensSoFar: 5,
        phase: phase,
        updatedAtMs: updatedAtMs,
      );
    }

    test('aggregates conversations newest first and prunes deleted ones',
        () async {
      await store.save(
        checkpoint(conversationId: 'older', updatedAtMs: 1000),
      );
      await store.save(
        checkpoint(conversationId: 'newest', updatedAtMs: 3000),
      );
      await store.save(
        checkpoint(conversationId: 'deleted', updatedAtMs: 2000),
      );

      final service = AgentRunTaskService(
        store: store,
        resolveConversation: (conversationId) {
          return switch (conversationId) {
            'older' => const AgentRunConversationInfo(
                exists: true,
                title: 'Older task',
              ),
            'newest' => const AgentRunConversationInfo(
                exists: true,
                title: 'Newest task',
              ),
            _ => const AgentRunConversationInfo.missing(),
          };
        },
      );

      final tasks = await service.load();

      expect(
        tasks.map((task) => task.checkpoint.conversationId).toList(),
        <String>['newest', 'older'],
      );
      expect(
        tasks.map((task) => task.conversationTitle).toList(),
        <String>['Newest task', 'Older task'],
      );
      expect(await store.load('deleted'), isNull);
      expect(await store.load('newest'), isNotNull);
    });

    test('keeps the task when the conversation lookup throws', () async {
      await store.save(
        checkpoint(conversationId: 'unknown', updatedAtMs: 1000),
      );

      final service = AgentRunTaskService(
        store: store,
        resolveConversation: (_) => throw StateError('storage not ready'),
      );

      final tasks = await service.load();

      expect(tasks, hasLength(1));
      expect(tasks.single.checkpoint.conversationId, 'unknown');
      expect(await store.load('unknown'), isNotNull);
    });

    test('keeps the task when the lookup explicitly says unknown', () async {
      await store.save(
        checkpoint(conversationId: 'not-ready', updatedAtMs: 1000),
      );

      final service = AgentRunTaskService(
        store: store,
        resolveConversation: (_) =>
            const AgentRunConversationInfo.unknown(),
      );

      final tasks = await service.load();

      expect(tasks, hasLength(1));
      expect(tasks.single.checkpoint.conversationId, 'not-ready');
      expect(await store.load('not-ready'), isNotNull);
    });

    test('marks active conversations without changing the checkpoint', () async {
      await store.save(
        checkpoint(conversationId: 'active', updatedAtMs: 1000),
      );
      await store.save(
        checkpoint(conversationId: 'idle', updatedAtMs: 2000),
      );

      final service = AgentRunTaskService(
        store: store,
        resolveConversation: (_) =>
            const AgentRunConversationInfo(exists: true),
      );

      final tasks = await service.load(
        activeConversationIds: const <String>{'active'},
      );

      expect(tasks.firstWhere((t) => t.checkpoint.conversationId == 'active').isActive, isTrue);
      expect(tasks.firstWhere((t) => t.checkpoint.conversationId == 'idle').isActive, isFalse);
    });

    test('keeps valid tasks when one stale checkpoint cannot be deleted', () async {
      final failingStore = _DeleteFailingStore(<AgentRunCheckpoint>[
        checkpoint(conversationId: 'stale', updatedAtMs: 1000),
        checkpoint(conversationId: 'live', updatedAtMs: 2000),
      ]);
      final service = AgentRunTaskService(
        store: failingStore,
        resolveConversation: (conversationId) =>
            conversationId == 'live'
                ? const AgentRunConversationInfo(exists: true)
                : const AgentRunConversationInfo.missing(),
      );

      final tasks = await service.load();

      expect(tasks, hasLength(1));
      expect(tasks.single.checkpoint.conversationId, 'live');
    });

    test('returns an empty list for an empty journal', () async {
      final service = AgentRunTaskService(
        store: store,
        resolveConversation: (_) =>
            const AgentRunConversationInfo(exists: true),
      );

      expect(await service.load(), isEmpty);
    });
  });
}

class _DeleteFailingStore extends AgentRunCheckpointStore {
  _DeleteFailingStore(this.checkpoints)
    : super(boxName: 'agent_runs_delete_failure_test');

  final List<AgentRunCheckpoint> checkpoints;

  @override
  Future<List<AgentRunCheckpoint>> listAll() async => checkpoints;

  @override
  Future<void> delete(String conversationId) async {
    throw StateError('checkpoint store is locked');
  }
}
