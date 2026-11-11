// P1-3 Cowork tool cards (IMPORT_PLAN_COWORK.md P1-3; shapes ported from
// kelivo `ask_user_input_v0` + the write_todos plan card):
//
// - [TodoPlanCard] — renders the `write_todos` tool call as a plan card:
//   header (icon + title + N/M pill + collapse), three-state checklist,
//   auto-collapse to a summary once every item is completed.
// - [AskUserCard] — renders `ask_user`: interactive single/multi answer form
//   with an auto-added Other free-text field and Skip; collapses to an
//   answered summary once the tool event carries the answer JSON.
//
// The cards take primitive parameters (no ToolUIPart dependency) so the
// widget library stays acyclic.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/services/agent/approval.dart';
import '../../../core/services/chat/ask_user_models.dart';
import '../../../core/services/chat/storage/message_part_codec.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../core/services/shell/tool_run_registry.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../tools/tool_presentation.dart';
import 'chat_message_widget.dart' show ToolUIPart;

/// Parsed todo arguments shared by the plan card. Lenient with per-item
/// dropping: legacy histories may contain partially invalid arguments that
/// the handler would now reject outright, and the card must still render
/// their valid entries (老對話不能因為新驗證而變空白).
List<TodoItem> todosFromArguments(Map<String, dynamic> arguments) =>
    parseTodoListInput(arguments['todos'], dropInvalidItems: true).items;

/// Parsed ask_user arguments (normalized questions) for the answer form.
List<AskUserQuestion> questionsFromArguments(Map<String, dynamic> arguments) =>
    normalizeAskUserQuestions(arguments['questions']);

// ============================================================================
// TodoPlanCard
// ============================================================================

class TodoPlanCard extends StatefulWidget {
  final Map<String, dynamic> arguments;

  /// Tool result: canonical `todo_snapshot` JSON, a `tool_error` payload, or
  /// null while the result is unknown (live / lazy body).
  final String? content;

  /// True only while the tool part is really executing (handler not yet
  /// returned). The spinner tracks this + [status] — never `content == null`
  /// (§2.4.1 of docs/write_todos_improvement_plan.md).
  final bool loading;

  /// Persisted part status (`pending`/`completed`/`interrupted`/`denied`),
  /// or null for a live part.
  final String? status;

  /// False when a restored summary has not loaded the full body yet. The
  /// card renders from [arguments] in that case instead of spinning.
  final bool contentLoaded;

  /// True for the newest plan card on the active branch. Only that card
  /// starts expanded; older plans stay folded (§2.4.2).
  final bool isLatestPlan;

  const TodoPlanCard({
    super.key,
    required this.arguments,
    required this.content,
    this.loading = false,
    this.status,
    this.contentLoaded = true,
    this.isLatestPlan = true,
  });

  @override
  State<TodoPlanCard> createState() => _TodoPlanCardState();
}

class _TodoPlanCardState extends State<TodoPlanCard> {
  bool _expanded = true;
  final Set<int> _expandedItems = <int>{};

  /// Resolved card inputs (§2.4.1): canonical snapshot items first
  /// (`changed=true` results carry the normalized list the model actually
  /// wrote), then the lenient argument parse; `tool_error` content is an
  /// error state, never a valid plan. Resolved ONCE per build — callers
  /// reuse the returned error map instead of re-decoding the body.
  static (List<TodoItem>, bool cleared, Map<String, dynamic>? error)
  _resolveCard(TodoPlanCard card) {
    final error = _parseToolError(card.content);
    if (error != null) return (const <TodoItem>[], false, error);
    final snapshot = parseTodoSnapshotContent(card.content);
    if (snapshot != null && snapshot.hasItems) {
      return (snapshot.items, snapshot.cleared && snapshot.items.isEmpty, null);
    }
    final todos = todosFromArguments(card.arguments);
    return (todos, todos.isEmpty && (snapshot?.cleared ?? false), null);
  }

  (List<TodoItem>, bool, Map<String, dynamic>?) _resolve() =>
      _resolveCard(widget);

  static Map<String, dynamic>? _parseToolError(String? content) {
    if (content == null || content.isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map && decoded['type']?.toString() == 'tool_error') {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }

  static String? _errorMessageOf(Map<String, dynamic>? error) {
    if (error == null) return null;
    final message = error['message']?.toString().trim();
    if (message != null && message.isNotEmpty) return message;
    final code = error['error']?.toString().trim();
    return (code == null || code.isEmpty) ? null : code;
  }

  @override
  void initState() {
    super.initState();
    _expanded = widget.isLatestPlan && !_allCompleted(_resolve().$1);
  }

  @override
  void didUpdateWidget(covariant TodoPlanCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A newer snapshot may complete the plan — collapse to the summary.
    final wasAllDone = _allCompleted(_resolveCard(oldWidget).$1);
    final isAllDone = _allCompleted(_resolve().$1);
    if (isAllDone && !wasAllDone) {
      _expanded = false;
    }
    // This card became the newest plan (a later plan was deleted or a new
    // turn started) — open it unless it is already fully done.
    if (widget.isLatestPlan && !oldWidget.isLatestPlan && !isAllDone) {
      _expanded = true;
    }
    // A newer plan took over — keep only the latest card expanded (§2.4.2).
    if (!widget.isLatestPlan && oldWidget.isLatestPlan && !isAllDone) {
      _expanded = false;
    }
  }

  static bool _allCompleted(List<TodoItem> todos) =>
      todos.isNotEmpty && todos.every((t) => t.isCompleted);

  Widget _buildItem(AppLocalizations l10n, int index, TodoItem t) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor = isDark
        ? const Color(0xFF9E9EA4)
        : const Color(0xFF7E7F83);
    final expanded = _expandedItems.contains(index);
    final longContent = t.content.length > 160;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Center(
              child: t.isCompleted
                  ? Icon(Lucide.CheckCircle, size: 15, color: cardTextColor)
                  : t.isInProgress
                  ? Icon(Lucide.circleDot, size: 15, color: cardTextColor)
                  : Icon(Lucide.Circle, size: 15, color: cardTextColor),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.content,
                  maxLines: expanded ? null : 4,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    color: t.isCompleted
                        ? cardTextColor.withValues(alpha: 0.7)
                        : cardTextColor,
                    decoration: t.isCompleted
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
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        expanded ? l10n.todoPlanCollapse : l10n.todoPlanExpand,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cardTextColor.withValues(alpha: 0.85),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor = isDark
        ? const Color(0xFF9E9EA4)
        : const Color(0xFF7E7F83);

    final resolved = _resolve();
    final todos = resolved.$1;
    final cleared = resolved.$2;
    final error = resolved.$3;
    final completed = todos.where((t) => t.isCompleted).length;

    // §2.4.1: the spinner tracks status/loading only. A restored completed
    // card with a lazy body renders from its arguments instead of spinning
    // forever (the old `content == null` bug).
    final isPending = widget.loading || widget.status == kPartStatusPending;
    final isInterrupted = widget.status == kPartStatusInterrupted;
    final errorMessage = _errorMessageOf(error);

    return IosCardPress(
      borderRadius: BorderRadius.circular(10),
      baseColor: Colors.transparent,
      pressedScale: 1.0,
      duration: const Duration(milliseconds: 260),
      onTap: () => setState(() => _expanded = !_expanded),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              isPending
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          cardTextColor,
                        ),
                      ),
                    )
                  : SizedBox(
                      width: 18,
                      height: 18,
                      child: Center(
                        child: Icon(
                          error != null
                              ? Lucide.XCircle
                              : isInterrupted
                              ? Lucide.CircleAlert
                              : Lucide.ListChecks,
                          size: 18,
                          color: cardTextColor,
                        ),
                      ),
                    ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.todoCardTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                    color: cardTextColor,
                  ),
                ),
              ),
              if (todos.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    // Whisper-level tint matching the search_web provider
                    // badge (_SearchProviderBadge): 6% background, 70%
                    // text — the pill must recede behind the answer.
                    color: cardTextColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    l10n.todoCardCompleted(completed, todos.length),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cardTextColor.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: cardTextColor,
              ),
            ],
          ),
          // Status is part of the header contract: a collapsed card must
          // still say failed/interrupted/cleared instead of looking like a
          // normal plan (§2.4.2). Detail stays behind the expand toggle.
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              l10n.todoCardError,
              style: TextStyle(fontSize: 12, color: cardTextColor),
            ),
            if (_expanded && errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  errorMessage,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: cardTextColor.withValues(alpha: 0.7),
                  ),
                ),
              ),
          ] else if (isInterrupted) ...[
            const SizedBox(height: 6),
            Text(
              l10n.todoCardInterrupted,
              style: TextStyle(fontSize: 12, color: cardTextColor),
            ),
          ] else if (cleared) ...[
            const SizedBox(height: 6),
            Text(
              l10n.todoCardCleared,
              style: TextStyle(fontSize: 12, color: cardTextColor),
            ),
          ],
          if (_expanded && todos.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (var i = 0; i < todos.length; i++)
              _buildItem(l10n, i, todos[i]),
          ] else if (!isPending &&
              todos.isEmpty &&
              !cleared &&
              error == null &&
              !isInterrupted)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.todoCardWaiting,
                style: TextStyle(fontSize: 12, color: cardTextColor),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// ApprovalToolCard (P1-1)
// ============================================================================

/// Approval card for a tool call classified as `ask` by the P1-1 policy
/// engine. Shows the parsed concrete absolute path (with an
/// out-of-workspace marker when applicable) plus Approve / Deny. After a
/// decision the card renders the recorded state (approved/denied). MCP tools
/// are never routed here (2026-09-10: the MCP policy source was removed).
class ApprovalToolCard extends StatelessWidget {
  final ToolUIPart part;
  final Map<String, dynamic> approval;
  final bool canResume;

  /// True while the approved call is executing. Buttons are hidden and the
  /// card shows progress so a long shell command cannot invite a second tap.
  final bool executing;

  final Future<void> Function() onApprove;
  final VoidCallback onDeny;

  const ApprovalToolCard({
    super.key,
    required this.part,
    required this.approval,
    required this.canResume,
    this.executing = false,
    required this.onApprove,
    required this.onDeny,
  });

  bool get _isDenied => approval['type'] == approvalDeniedType;
  bool get _isTimeout =>
      (approval['error'] ?? '').toString() == 'approval_timeout';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor = isDark
        ? const Color(0xFF9E9EA4)
        : const Color(0xFF7E7F83);

    final toolName = (approval['tool'] ?? part.toolName).toString();
    // "Approval needed: Write file", not "…: file_write". External MCP tools
    // keep their server-provided id.
    final toolLabel = toolDisplayName(l10n, toolName);
    final resolvedPath = (approval['resolved_path'] ?? '').toString();
    final outside = approval['outside_workspace'] == true;
    final shellCommand = (approval['shell_command'] ?? '').toString();

    return IosCardPress(
      borderRadius: BorderRadius.circular(10),
      baseColor: Colors.transparent,
      pressedScale: 1.0,
      duration: const Duration(milliseconds: 260),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Center(
                  child: Icon(
                    _isDenied ? Lucide.XCircle : Lucide.Shield,
                    size: 18,
                    color: cardTextColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isDenied
                      ? l10n.approvalDeniedTitle(toolLabel)
                      : _isTimeout
                      ? l10n.approvalTimeoutTitle(toolLabel)
                      : executing
                      ? l10n.approvalExecutingTitle(toolLabel)
                      : l10n.approvalPendingTitle(toolLabel),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.normal,
                    color: cardTextColor,
                  ),
                ),
              ),
              if (!_isDenied && !_isTimeout)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    executing
                        ? l10n.approvalExecutingPill
                        : l10n.approvalPendingPill,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (resolvedPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    outside ? Lucide.ExternalLink : Lucide.FileText,
                    size: 14,
                    color: outside ? Colors.orange : cardTextColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      outside
                          ? l10n.approvalOutsideWorkspace(resolvedPath)
                          : resolvedPath,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: cardTextColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // P1-6: the full command is the thing the user is approving — show
          // it verbatim.
          if (shellCommand.isNotEmpty && !_isDenied && !_isTimeout) ...[
            const SizedBox(height: 2),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0x14000000)
                    : const Color(0x0A000000),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.approvalShellCommand,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: cardTextColor.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    shellCommand,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.35,
                      color: cardTextColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
          // P1-1 (2026-11-10): the decision landed and the tool is running;
          // a long command must not look like a dead card.
          if (executing && !_isDenied && !_isTimeout) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(cardTextColor),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.approvalExecuting,
                    style: TextStyle(fontSize: 12, color: cardTextColor),
                  ),
                ),
              ],
            ),
          ],
          // P1-1: unified-diff preview for file_edit calls (before execution).
          if ((approval['preview_diff'] ?? '').toString().trim().isNotEmpty &&
              !_isDenied &&
              !_isTimeout) ...[
            const SizedBox(height: 2),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0x14000000)
                    : const Color(0x0A000000),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                (approval['preview_diff'] ?? '').toString(),
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  height: 1.35,
                  color: cardTextColor,
                ),
              ),
            ),
          ],
          if (!_isDenied && !_isTimeout && canResume && !executing) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDeny,
                  child: Text(
                    l10n.approvalDeny,
                    style: TextStyle(fontSize: 13, color: cardTextColor),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onApprove,
                  child: Text(
                    l10n.approvalApprove,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// P1-6: live shell output on the executing tool card. Reads the
/// process-lifetime ToolRun registry; after a reload the registry is empty
/// and the card falls back to the persisted final tool event (documented
/// degradation — no live tail across restarts).
class ShellLiveTail extends StatelessWidget {
  const ShellLiveTail({
    super.key,
    required this.toolCallId,
    required this.color,
  });

  final String toolCallId;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // The ToolRun may be created after this card's first build (the tool
    // event can render before execute() reaches the registry). Listen to the
    // registry as well as the run so the tail appears without a parent rebuild.
    return AnimatedBuilder(
      animation: ToolRunRegistry.instance,
      builder: (context, _) {
        final run = ToolRunRegistry.instance.findByToolCallId(toolCallId);
        if (run == null) return const SizedBox.shrink();
        return AnimatedBuilder(
          animation: run,
          builder: (context, _) {
            final text = run.tail(lines: 6);
            if (text.trim().isEmpty) return const SizedBox.shrink();
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0x14000000)
                    : const Color(0x0A000000),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                text,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.35,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// AskUserCard
// ============================================================================

class AskUserCard extends StatefulWidget {
  final Map<String, dynamic> arguments;
  final String? content; // pending JSON | answer JSON | null (loading)

  /// Called with the structured answer payload when the user submits (or
  /// skips). Null = read-only rendering (no resume plumbing available).
  final void Function(Map<String, dynamic> payload)? onAnswer;

  const AskUserCard({
    super.key,
    required this.arguments,
    required this.content,
    this.onAnswer,
  });

  @override
  State<AskUserCard> createState() => _AskUserCardState();
}

class _AskUserCardState extends State<AskUserCard> {
  final Map<String, Set<int>> _selected = <String, Set<int>>{};
  final Map<String, TextEditingController> _other =
      <String, TextEditingController>{};
  bool _expanded = true;
  String? _formSignature; // resets selections when a new pending set arrives

  List<AskUserQuestion> get _questions =>
      questionsFromArguments(widget.arguments);

  bool get _answered {
    final parsed = parseAskUserContent(widget.content);
    return parsed != null && parsed['type'] == askUserAnswerType;
  }

  Map<String, Set<int>> _selectionsFor(List<AskUserQuestion> questions) {
    final signature = questions.map((q) => q.id).join('|');
    if (_formSignature != signature) {
      _formSignature = signature;
      for (final c in _other.values) {
        c.dispose();
      }
      _other.clear();
      _selected.clear();
    }
    return _selected;
  }

  bool _canSubmit(List<AskUserQuestion> questions) {
    for (final q in questions) {
      final picked = _selected[q.id]?.isNotEmpty ?? false;
      final other = _other[q.id]?.text.trim().isNotEmpty ?? false;
      if (!picked && !other) return false;
    }
    return questions.isNotEmpty;
  }

  List<AskUserAnswerEntry> _buildAnswers(
    List<AskUserQuestion> questions, {
    required bool skipAll,
  }) {
    return [
      for (final q in questions)
        AskUserAnswerEntry(
          id: q.id,
          question: q.question,
          selected: skipAll
              ? const <String>[]
              : (_selected[q.id] ?? const <int>{})
                    .map((i) => q.options[i])
                    .toList(),
          other: skipAll ? '' : (_other[q.id]?.text.trim() ?? ''),
          skipped: skipAll,
        ),
    ];
  }

  void _submit(List<AskUserQuestion> questions, {required bool skipAll}) {
    if (!skipAll && !_canSubmit(questions)) return;
    widget.onAnswer?.call(
      jsonDecode(
        buildAskUserAnswerContent(_buildAnswers(questions, skipAll: skipAll)),
      ) as Map<String, dynamic>,
    );
  }

  @override
  void dispose() {
    for (final c in _other.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor = isDark
        ? const Color(0xFF9E9EA4)
        : const Color(0xFF7E7F83);
    // ask_user 的內容是給使用者看與作答的（不同於 todo / reasoning / 工具卡
    // 的「隱藏工具與思考過程」淡灰設計），配色恢復為正常內文色，僅標題列
    // （icon＋標題＋收合箭頭）與「已回答」膠囊維持淡灰。
    final bodyTextColor = cs.onSurface;

    final loading = widget.content == null || widget.content!.isEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                loading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            cardTextColor,
                          ),
                        ),
                      )
                    : SizedBox(
                        width: 18,
                        height: 18,
                        child: Center(
                          child: Icon(
                            _answered
                                ? Lucide.MessageCircle
                                : Lucide.FileQuestion,
                            size: 18,
                            color: cardTextColor,
                          ),
                        ),
                      ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.askUserCardTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.normal,
                      color: cardTextColor,
                    ),
                  ),
                ),
                if (_answered)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      // Whisper-level tint matching the search_web provider
                      // badge (_SearchProviderBadge): 6% background, 70%
                      // text — same as the todo plan card's N/M pill.
                      color: cardTextColor.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      l10n.askUserAnswered,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cardTextColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: cardTextColor,
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            _buildBody(context, l10n, cs, cardTextColor, bodyTextColor),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
    Color headerTextColor,
    Color bodyTextColor,
  ) {
    final content = widget.content;
    final parsed = parseAskUserContent(content);

    // Loading: handler has not returned yet.
    if (content == null || content.isEmpty) {
      return Text(
        l10n.askUserPending,
        style: TextStyle(fontSize: 12, color: bodyTextColor),
      );
    }

    // Answered: collapsed summary of the structured answers.
    if (parsed != null && parsed['type'] == askUserAnswerType) {
      final answers = answersFromAnswerContent(parsed);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final a in answers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Center(
                      child: Icon(
                        a.skipped ? Lucide.CircleX : Lucide.CheckCircle,
                        size: 14,
                        color: bodyTextColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${a.question}\n${a.toDisplayText()}',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: bodyTextColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    // Pending (or unparsed content but questions available): answer form.
    final questions = parsed != null && parsed['type'] == askUserPendingType
        ? questionsFromPendingContent(parsed)
        : _questions;
    if (questions.isEmpty) {
      return Text(
        l10n.askUserPending,
        style: TextStyle(fontSize: 12, color: bodyTextColor),
      );
    }
    _selectionsFor(questions); // lazily reset stale form state
    final interactive = widget.onAnswer != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final q in questions) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              q.question,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: bodyTextColor,
              ),
            ),
          ),
          for (var i = 0; i < q.options.length; i++)
            _optionRow(context, q, i, cs, bodyTextColor, interactive),
          _otherRow(context, q, bodyTextColor, interactive),
        ],
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: interactive
                  ? () => _submit(questions, skipAll: true)
                  : null,
              child: Text(
                l10n.askUserSkip,
                style: TextStyle(fontSize: 13, color: bodyTextColor),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: interactive && _canSubmit(questions)
                  ? () => _submit(questions, skipAll: false)
                  : null,
              child: Text(
                l10n.askUserSubmit,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionRow(
    BuildContext context,
    AskUserQuestion q,
    int index,
    ColorScheme cs,
    Color bodyTextColor,
    bool interactive,
  ) {
    final selected = _selected[q.id]?.contains(index) ?? false;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: interactive
          ? () {
              setState(() {
                final set = _selected.putIfAbsent(q.id, () => <int>{});
                if (q.kind == 'single') {
                  set
                    ..clear()
                    ..add(index);
                } else if (!set.add(index)) {
                  set.remove(index);
                }
              });
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: Center(
                child: Icon(
                  q.kind == 'single'
                      ? (selected ? Lucide.CheckCircle : Lucide.Circle)
                      : (selected ? Lucide.CheckSquare : Lucide.Square),
                  size: 16,
                  color: selected ? cs.primary : bodyTextColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                q.options[index],
                style: TextStyle(fontSize: 13, color: bodyTextColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _otherRow(
    BuildContext context,
    AskUserQuestion q,
    Color bodyTextColor,
    bool interactive,
  ) {
    final controller = _other.putIfAbsent(q.id, () => TextEditingController());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: controller,
        enabled: interactive,
        onChanged: (_) => setState(() {}),
        style: TextStyle(fontSize: 13, color: bodyTextColor),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Icon(Lucide.Pencil, size: 16, color: bodyTextColor),
          hintText: AppLocalizations.of(context)!.askUserOther,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
        ),
      ),
    );
  }
}
