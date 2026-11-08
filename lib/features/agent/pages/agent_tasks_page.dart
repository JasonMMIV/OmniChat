import 'package:flutter/material.dart';

import '../../../core/services/agent/checkpoint/agent_run_checkpoint_store.dart';
import '../../../core/services/agent/checkpoint/agent_run_task.dart';
import '../../../core/services/agent/checkpoint/agent_run_task_service.dart';
import '../../../l10n/app_localizations.dart';
import '../widgets/agent_tasks_view.dart';

/// P3-3: mobile / full-page entry to the unfinished agent runs.
class AgentTasksPage extends StatelessWidget {
  const AgentTasksPage({
    super.key,
    required this.onResumeTask,
    this.store,
    this.resolveConversation,
    this.activeConversationIds = const <String>{},
  });

  final Future<bool> Function(AgentRunTask task) onResumeTask;
  final AgentRunCheckpointStore? store;
  final AgentRunConversationResolver? resolveConversation;
  final Set<String> activeConversationIds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.agentTasksTitle)),
      body: SafeArea(
        child: AgentTasksView(
          store: store,
          resolveConversation: resolveConversation,
          activeConversationIds: activeConversationIds,
          onOpenTask: (task) async {
            final opened = await onResumeTask(task);
            if (opened && context.mounted) {
              final navigator = Navigator.of(context);
              if (navigator.canPop()) navigator.pop();
            }
            return opened;
          },
        ),
      ),
    );
  }
}
