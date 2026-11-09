// Current-plan UI (Phase 3 of docs/write_todos_improvement_plan.md).
//
// - [TodoPlanSheet] — read-only view of the projected plan (the latest
//   successful `write_todos` event), with a user-initiated clear that appends
//   a real `write_todos(todos: [])` event to the conversation.
// - [TodoPlanLiveDock] — compact composer-adjacent dock shown only while a
//   run is in progress; it disappears on finish while the transcript card
//   stays (Anybuff `todo-panel-dock` parity).
//
// Both read the same [TodoState] projection; there is no local todo store.

import 'package:flutter/material.dart';

import '../../../core/services/chat/storage/message_part_codec.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../home/controllers/streaming_content_notifier.dart';
import 'chat_message_widget.dart' show ToolUIPart;

/// Builds the latest plan state from in-memory tool parts (live run or
/// restored summaries). Mirrors the projection's success rules: pending,
/// interrupted, denied and `tool_error` parts never advance the state; a
/// canonical snapshot wins over the raw arguments, which are parsed leniently
/// so older partial payloads still render.
TodoState? todoStateFromToolParts(List<ToolUIPart>? parts) {
  if (parts == null || parts.isEmpty) return null;
  TodoState? state;
  for (final part in parts) {
    if (part.toolName != todoToolName) continue;
    if (part.status == kPartStatusPending ||
        part.status == kPartStatusInterrupted ||
        part.status == kPartStatusDenied) {
      continue;
    }
    if (isTodoToolErrorContent(part.content)) continue;
    final snapshot = parseTodoSnapshotContent(part.content);
    if (snapshot != null && snapshot.hasItems) {
      state = TodoState(items: snapshot.items, hasExplicitState: true);
      continue;
    }
    final parsed = parseTodoListInput(
      part.arguments['todos'],
      dropInvalidItems: true,
    );
    if (parsed.isValid) {
      state = TodoState(items: parsed.items, hasExplicitState: true);
    }
  }
  return state;
}

/// Bottom sheet showing the conversation's current plan.
class TodoPlanSheet extends StatefulWidget {
  const TodoPlanSheet({
    super.key,
    required this.loadPlan,
    this.clearPlan,
    this.isRunning = false,
  });

  final Future<TodoState?> Function() loadPlan;

  /// Appends the clear event. Null disables the clear action (read-only view).
  final Future<bool> Function()? clearPlan;

  final bool isRunning;

  static Future<void> show(
    BuildContext context, {
    required Future<TodoState?> Function() loadPlan,
    Future<bool> Function()? clearPlan,
    bool isRunning = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => TodoPlanSheet(
        loadPlan: loadPlan,
        clearPlan: clearPlan,
        isRunning: isRunning,
      ),
    );
  }

  @override
  State<TodoPlanSheet> createState() => _TodoPlanSheetState();
}

class _TodoPlanSheetState extends State<TodoPlanSheet> {
  TodoState? _state;
  bool _loading = true;
  bool _failed = false;
  bool _clearing = false;
  final Set<int> _expandedItems = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await widget.loadPlan();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _confirmClear() async {
    final clearPlan = widget.clearPlan;
    if (clearPlan == null || _clearing) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.todoPlanClearConfirmTitle),
        content: Text(l10n.todoPlanClearConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.todoPlanClear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    final ok = await clearPlan();
    if (!mounted) return;
    setState(() {
      _clearing = false;
      if (ok) {
        _state = const TodoState(items: <TodoItem>[], hasExplicitState: true);
      }
    });
    showAppSnackBar(
      context,
      message: ok ? l10n.todoPlanClearedSnack : l10n.todoPlanClearFailed,
      type: ok ? NotificationType.success : NotificationType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final state = _state;
    final items = state?.items ?? const <TodoItem>[];
    final total = items.length;
    final completed = items.where((t) => t.isCompleted).length;
    final hasActivePlan = state != null && !state.isCleared && total > 0;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Lucide.ListChecks, size: 18, color: cs.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.todoPlanTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                        Text(
                          hasActivePlan
                              ? l10n.todoCardCompleted(completed, total)
                              : state?.isCleared == true
                              ? l10n.todoPlanClearedTitle
                              : l10n.todoPlanEmptyTitle,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.3,
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.isRunning)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        l10n.todoPlanRunning,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: l10n.homePageCancel,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(
                      Lucide.X,
                      size: 18,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (hasActivePlan)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value: total == 0 ? 0 : completed / total,
                    backgroundColor: cs.onSurface.withValues(alpha: 0.08),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      cs.primary.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: _buildBody(context, l10n, state),
              ),
            ),
            if (hasActivePlan && widget.clearPlan != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    // Clearing mid-run can be overwritten by the in-flight
                    // turn and races the stream's tool-list snapshot.
                    onPressed: _clearing || widget.isRunning
                        ? null
                        : _confirmClear,
                    style: TextButton.styleFrom(
                      foregroundColor: cs.error,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    icon: _clearing
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                cs.error,
                              ),
                            ),
                          )
                        : const Icon(Lucide.Eraser, size: 15),
                    label: Text(l10n.todoPlanClear),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    TodoState? state,
  ) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_failed) {
      return _EmptyPlan(
        icon: Lucide.CircleAlert,
        title: l10n.todoPlanLoadFailed,
        body: l10n.todoPlanEmptyBody,
        color: cs.error,
      );
    }
    if (state == null) {
      return _EmptyPlan(
        icon: Lucide.ListChecks,
        title: l10n.todoPlanEmptyTitle,
        body: l10n.todoPlanEmptyBody,
        color: cs.onSurface.withValues(alpha: 0.55),
      );
    }
    if (state.isCleared) {
      return _EmptyPlan(
        icon: Lucide.Eraser,
        title: l10n.todoPlanClearedTitle,
        body: l10n.todoPlanClearedBody,
        color: cs.onSurface.withValues(alpha: 0.55),
      );
    }

    final items = state.items;
    final inProgress = <int>[];
    final pending = <int>[];
    final completed = <int>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.isCompleted) {
        completed.add(i);
      } else if (item.isInProgress) {
        inProgress.add(i);
      } else {
        pending.add(i);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inProgress.isNotEmpty) ...[
          _SectionLabel(l10n.todoPlanInProgressSection),
          for (final i in inProgress) _buildItem(context, i, items[i]),
          const SizedBox(height: 10),
        ],
        if (pending.isNotEmpty) ...[
          _SectionLabel(l10n.todoPlanPendingSection),
          for (final i in pending) _buildItem(context, i, items[i]),
          const SizedBox(height: 10),
        ],
        if (completed.isNotEmpty) ...[
          _SectionLabel(l10n.todoPlanCompletedSection),
          for (final i in completed) _buildItem(context, i, items[i]),
        ],
        if (state.updatedAt != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                Lucide.History,
                size: 13,
                color: cs.onSurface.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 5),
              Text(
                l10n.todoPlanUpdatedAt(
                  _formatUpdatedAt(context, state.updatedAt!),
                ),
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildItem(BuildContext context, int index, TodoItem item) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final expanded = _expandedItems.contains(index);
    final longContent = item.content.length > 160;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              item.isCompleted
                  ? Lucide.CheckCircle
                  : item.isInProgress
                  ? Lucide.circleDot
                  : Lucide.Circle,
              size: 16,
              color: item.isCompleted
                  ? cs.onSurface.withValues(alpha: 0.4)
                  : item.isInProgress
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.content,
                  maxLines: expanded ? null : 4,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    color: item.isCompleted
                        ? cs.onSurface.withValues(alpha: 0.5)
                        : cs.onSurface,
                    decoration: item.isCompleted
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                if (longContent)
                  GestureDetector(
                    onTap: () => setState(() {
                      if (expanded) {
                        _expandedItems.remove(index);
                      } else {
                        _expandedItems.add(index);
                      }
                    }),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        expanded ? l10n.todoPlanCollapse : l10n.todoPlanExpand,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: cs.primary.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatUpdatedAt(BuildContext context, DateTime at) {
    final local = at.toLocal();
    final material = MaterialLocalizations.of(context);
    final date = material.formatShortDate(local);
    final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    return '$date $time';
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
          color: cs.onSurface.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

class _EmptyPlan extends StatelessWidget {
  const _EmptyPlan({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 8),
      child: Column(
        children: [
          Icon(icon, size: 30, color: color.withValues(alpha: 0.5)),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact plan dock above the composer, visible only while a run streams.
class TodoPlanLiveDock extends StatelessWidget {
  const TodoPlanLiveDock({
    super.key,
    required this.visible,
    required this.streamingMessageId,
    required this.toolParts,
    required this.notifier,
    this.onTap,
  });

  final bool visible;
  final String? streamingMessageId;
  final Map<String, List<ToolUIPart>> toolParts;
  final StreamingContentNotifier? notifier;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final messageId = streamingMessageId;
    final contentNotifier = notifier;
    if (messageId == null || contentNotifier == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<StreamingContentData>(
      valueListenable: contentNotifier.getNotifier(messageId),
      builder: (context, _, __) {
        final state = todoStateFromToolParts(toolParts[messageId]);
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: state == null || state.items.isEmpty
              ? const SizedBox(width: double.infinity)
              : _TodoPlanDockCard(state: state, onTap: onTap),
        );
      },
    );
  }
}

class _TodoPlanDockCard extends StatelessWidget {
  const _TodoPlanDockCard({required this.state, this.onTap});

  final TodoState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final items = state.items;
    final total = items.length;
    final completed = items.where((t) => t.isCompleted).length;
    TodoItem? current;
    for (final item in items) {
      if (item.isInProgress) {
        current = item;
        break;
      }
    }
    if (current == null) {
      for (final item in items) {
        if (!item.isCompleted) {
          current = item;
          break;
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Material(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        value: total == 0 ? 0 : completed / total,
                        backgroundColor: cs.onSurface.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          cs.primary.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.todoPlanTitle,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.3,
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            current?.content ??
                                l10n.todoCardCompleted(completed, total),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.25,
                              fontWeight: FontWeight.w500,
                              color: cs.onSurface.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$completed/$total',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Lucide.ChevronRight,
                      size: 15,
                      color: cs.onSurface.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
