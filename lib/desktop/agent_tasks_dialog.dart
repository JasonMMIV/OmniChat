import 'package:flutter/material.dart';

import '../features/agent/widgets/agent_tasks_view.dart';
import '../core/services/agent/checkpoint/agent_run_task.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';

/// P3-3 desktop entry: the same task list inside an anchored dialog.
Future<void> showAgentTasksDesktopDialog(
  BuildContext context, {
  required Future<bool> Function(AgentRunTask task) onResumeTask,
  Set<String> activeConversationIds = const <String>{},
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final l10n = AppLocalizations.of(ctx)!;
      return Dialog(
        elevation: 12,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 560,
            minWidth: 420,
            maxHeight: 620,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Material(
              color: Theme.of(ctx).colorScheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Row(
                      children: [
                        Text(
                          l10n.agentTasksTitle,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: l10n.sideDrawerCancel,
                          icon: const Icon(Lucide.X),
                          onPressed: () => Navigator.of(ctx).maybePop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: AgentTasksView(
                      activeConversationIds: activeConversationIds,
                      onOpenTask: (task) async {
                        final opened = await onResumeTask(task);
                        if (opened && ctx.mounted) {
                          Navigator.of(ctx).pop();
                        }
                        return opened;
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
