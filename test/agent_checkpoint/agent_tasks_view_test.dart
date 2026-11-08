import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_checkpoint.dart';
import 'package:OmniChat/core/services/agent/checkpoint/agent_run_task.dart';
import 'package:OmniChat/features/agent/widgets/agent_tasks_view.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );
  }

  AgentRunTask task({
    String conversationId = 'conv-1',
    String phase = agentRunPhasePaused,
    List<AgentRunPendingTool> pendingTools = const <AgentRunPendingTool>[
      AgentRunPendingTool(
        id: 'call-1',
        name: 'shell_run',
        kind: 'approval',
      ),
    ],
    bool isActive = false,
  }) {
    return AgentRunTask.fromCheckpoint(
      AgentRunCheckpoint(
        conversationId: conversationId,
        assistantMessageId: 'assistant-1',
        stepIndex: 2,
        tokensSoFar: 120,
        phase: phase,
        updatedAtMs: DateTime(2026, 11, 8, 10, 30).millisecondsSinceEpoch,
        pendingTools: pendingTools,
      ),
      conversationTitle: 'Project Alpha',
      isActive: isActive,
    );
  }

  testWidgets('shows the empty state when there is no task', (tester) async {
    await tester.pumpWidget(
      wrap(
        AgentTasksView(
          loadTasks: () async => const <AgentRunTask>[],
          onOpenTask: (_) async => true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Nothing to resume'), findsOneWidget);
  });

  testWidgets('renders a row and invokes the task callback', (tester) async {
    final row = task();

    AgentRunTask? opened;
    await tester.pumpWidget(
      wrap(
        AgentTasksView(
          loadTasks: () async => <AgentRunTask>[row],
          onOpenTask: (task) async {
            opened = task;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Project Alpha'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.text('Pending: shell_run'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pump();

    expect(opened?.checkpoint.conversationId, 'conv-1');
    expect(opened?.reason, AgentRunTaskReason.approval);
  });

  testWidgets('shows an active run as Running/Open', (tester) async {
    final row = task(phase: agentRunPhaseRunning, isActive: true);
    var opened = false;

    await tester.pumpWidget(
      wrap(
        AgentTasksView(
          loadTasks: () async => <AgentRunTask>[row],
          onOpenTask: (_) async {
            opened = true;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);

    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('shows the pending tool that matches ask-user priority', (
    tester,
  ) async {
    final row = task(
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
    );

    await tester.pumpWidget(
      wrap(
        AgentTasksView(
          loadTasks: () async => <AgentRunTask>[row],
          onOpenTask: (_) async => true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Waiting for your answer'), findsOneWidget);
    expect(find.text('Pending: ask_user'), findsOneWidget);
    expect(find.text('Pending: shell_run'), findsNothing);
  });

  testWidgets('keeps the list visible when opening a task fails', (
    tester,
  ) async {
    final row = task();

    await tester.pumpWidget(
      wrap(
        AgentTasksView(
          loadTasks: () async => <AgentRunTask>[row],
          onOpenTask: (_) async => false,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Review'));
    await tester.pump();

    expect(
      find.text('This task is no longer available. Try refreshing the list.'),
      findsOneWidget,
    );
    expect(find.text('Project Alpha'), findsOneWidget);
  });

  testWidgets('shows a retry state instead of an empty list on load failure', (
    tester,
  ) async {
    var attempts = 0;
    final row = task();

    await tester.pumpWidget(
      wrap(
        AgentTasksView(
          loadTasks: () async {
            attempts++;
            if (attempts == 1) throw StateError('journal locked');
            return <AgentRunTask>[row];
          },
          onOpenTask: (_) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text("Couldn't load unfinished tasks."), findsOneWidget);
    expect(find.text('Nothing to resume'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Project Alpha'), findsOneWidget);
  });
}
