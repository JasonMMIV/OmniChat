import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/services/agent/checkpoint/agent_run_checkpoint_store.dart';
import '../../../core/services/agent/checkpoint/agent_run_task.dart';
import '../../../core/services/agent/checkpoint/agent_run_task_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// P3-3 task surface: every unfinished agent run, newest first.
///
/// The journal is device-local and tiny, so the list is rebuilt on open rather
/// than kept in a second live index. A row either navigates to its timeline
/// card (pending approval / ask_user) or resumes a bare interrupted run; both
/// decisions belong to the caller through [onOpenTask].
class AgentTasksView extends StatefulWidget {
  const AgentTasksView({
    super.key,
    required this.onOpenTask,
    this.store,
    this.resolveConversation,
    this.loadTasks,
    this.activeConversationIds = const <String>{},
  });

  /// Returns true when the row was actually opened/resumed. Callers should
  /// keep the list visible and let the view show an error when this is false.
  final Future<bool> Function(AgentRunTask task) onOpenTask;

  /// Test seams; production uses the singleton store and [ChatService].
  final AgentRunCheckpointStore? store;
  final AgentRunConversationResolver? resolveConversation;
  final Future<List<AgentRunTask>> Function()? loadTasks;

  /// Conversations with a generation currently running in this app instance.
  /// A journal checkpoint alone cannot distinguish an active run from a crash.
  final Set<String> activeConversationIds;

  @override
  State<AgentTasksView> createState() => _AgentTasksViewState();
}

class _AgentTasksViewState extends State<AgentTasksView> {
  List<AgentRunTask> _tasks = const <AgentRunTask>[];
  bool _loading = true;
  bool _loadFailed = false;
  bool _actionFailed = false;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading && mounted) {
      setState(() {
        _loading = true;
        _loadFailed = false;
        _actionFailed = false;
      });
    }
    try {
      final loader = widget.loadTasks;
      final tasks = loader != null
          ? await loader()
          : await _readJournal();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _loading = false;
        _loadFailed = false;
      });
    } catch (e) {
      FlutterLogger.log(
        'Could not load unfinished agent tasks: $e',
        tag: 'agent-checkpoint',
      );
      if (!mounted) return;
      setState(() {
        _tasks = const <AgentRunTask>[];
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<List<AgentRunTask>> _readJournal() {
    final chatService = widget.resolveConversation == null
        ? context.read<ChatService>()
        : null;
    final service = AgentRunTaskService(
      store: widget.store,
      resolveConversation:
          widget.resolveConversation ??
          (conversationId) {
            // `getConversation` also returns null before chat storage is
            // ready. Treat that as unknown, not as a deleted conversation.
            if (chatService == null || !chatService.initialized) {
              return const AgentRunConversationInfo.unknown();
            }
            final conversation = chatService.getConversation(conversationId);
            if (conversation == null) {
              return const AgentRunConversationInfo.missing();
            }
            return AgentRunConversationInfo(
              exists: true,
              title: conversation.title,
            );
          },
    );
    return service.load(activeConversationIds: widget.activeConversationIds);
  }

  Future<void> _open(AgentRunTask task) async {
    if (_opening) return;
    _opening = true;
    try {
      final opened = await widget.onOpenTask(task);
      if (!mounted) return;
      setState(() => _actionFailed = !opened);
    } catch (e) {
      FlutterLogger.log(
        'Could not open unfinished agent task: $e',
        tag: 'agent-checkpoint',
      );
      if (!mounted) return;
      setState(() => _actionFailed = true);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed) {
      return _AgentTasksErrorState(onRetry: _load);
    }
    if (_tasks.isEmpty) {
      return const _AgentTasksEmptyState();
    }
    return Column(
      children: [
        if (_actionFailed) const _AgentTasksActionError(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            itemCount: _tasks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final task = _tasks[index];
              return _AgentTaskTile(task: task, onTap: () => _open(task));
            },
          ),
        ),
      ],
    );
  }
}

class _AgentTaskTile extends StatelessWidget {
  const _AgentTaskTile({required this.task, required this.onTap});

  final AgentRunTask task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.white12 : const Color(0xFFF7F7F9);
    final title = task.conversationTitle?.trim();
    final checkpoint = task.checkpoint;
    final pendingTool = task.primaryPendingTool?.name;
    final action = task.isActive
        ? l10n.agentTasksOpen
        : task.requiresUserAction
        ? l10n.agentTasksReview
        : l10n.agentTasksResume;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.16)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(_iconFor(task), size: 18, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (title == null || title.isEmpty)
                          ? checkpoint.conversationId
                          : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _reasonText(context, task),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurface.withValues(alpha: 0.72),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pendingTool == null
                          ? l10n.agentTasksStep(checkpoint.stepIndex + 1)
                          : l10n.agentTasksPendingTool(pendingTool),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurface.withValues(alpha: 0.52),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      l10n.agentTasksSavedAt(
                        _formatTime(checkpoint.updatedAt),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurface.withValues(alpha: 0.52),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: onTap,
                child: Text(action),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(AgentRunTask task) {
    if (task.isActive) return Lucide.RotateCw;
    return switch (task.reason) {
      AgentRunTaskReason.approval => Lucide.ListChecks,
      AgentRunTaskReason.askUser => Lucide.MessageCircle,
      AgentRunTaskReason.running => Lucide.RotateCw,
      AgentRunTaskReason.softStopped => Lucide.ListChecks,
      AgentRunTaskReason.interrupted => Lucide.History,
    };
  }

  static String _reasonText(BuildContext context, AgentRunTask task) {
    final l10n = AppLocalizations.of(context)!;
    if (task.isActive) return l10n.agentTasksRunning;
    switch (task.reason) {
      case AgentRunTaskReason.approval:
        return l10n.agentTasksReasonApproval;
      case AgentRunTaskReason.askUser:
        return l10n.agentTasksReasonAskUser;
      case AgentRunTaskReason.running:
        return l10n.agentTasksReasonRunning;
      case AgentRunTaskReason.softStopped:
        return switch (task.checkpoint.softStopReason) {
          'max_steps' => l10n.agentTasksReasonSoftStopSteps,
          'token_budget' => l10n.agentTasksReasonSoftStopTokens,
          _ => l10n.agentTasksReasonSoftStopped,
        };
      case AgentRunTaskReason.interrupted:
        return l10n.agentTasksReasonInterrupted;
    }
  }

  static String _formatTime(DateTime dt) {
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }
}

class _AgentTasksErrorState extends StatelessWidget {
  const _AgentTasksErrorState({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Lucide.History,
              size: 36,
              color: cs.error.withValues(alpha: 0.72),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.agentTasksLoadFailed,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Lucide.RotateCw, size: 16),
              label: Text(l10n.agentTasksRetry),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentTasksActionError extends StatelessWidget {
  const _AgentTasksActionError();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        l10n.agentTasksUnavailable,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.35,
          color: cs.onErrorContainer,
        ),
      ),
    );
  }
}

class _AgentTasksEmptyState extends StatelessWidget {
  const _AgentTasksEmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Lucide.ListChecks,
              size: 36,
              color: cs.onSurface.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.agentTasksEmptyTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.agentTasksEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
