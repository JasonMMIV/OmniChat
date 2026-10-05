// 過程收褶（process folding）— 分組純邏輯。PLAN_PROCESS_FOLDING.md Phase 1。
//
// Port of AnyBuff's process folding (desktop/src/renderer/src/utils/
// chat-groups.ts) degenerate case: in OmniChat every thinking + tool block
// of one work segment lives inside a single assistant message BEFORE the
// body text, so the "maximal run between two body blocks" collapses to at
// most ONE group per assistant message. The header flips
// 處理中.../Working… → 已完成/Worked via [ProcessGroupModel.live]; the fold
// follows [resolveProcessOpen] (explicit pin > forced-open > follow run).
//
// Pure Dart — no Flutter imports. The UI shell renders [ProcessGroupModel]
// and maps [ToolEntry.tool.index] back onto the caller's full tool part list
// (arguments, provider badges, special cards) without importing UI types
// here. Unit-tested in test/process_group_logic_test.dart.
library;

import '../../../core/services/agent/approval.dart';
import '../../../core/services/chat/ask_user_models.dart';

/// Never rendered inside the group (mirrors the pre-folding
/// chat_message_widget filters): builtin_search surfaces via the bottom
/// citations summary card instead; workspace_snapshot is the removed P1-5
/// legacy log-only tool that old conversations may still persist.
const String _builtinSearchToolName = 'builtin_search';
const String _legacyWorkspaceSnapshotToolName = 'workspace_snapshot';

/// View of one thinking segment (the call site's `ReasoningSegment`).
class ProcessThought {
  final String text;

  /// Still generating (`finishedAt == null && text non-empty` at the call
  /// site). Empty-text thoughts never render, even while loading — the
  /// answer bubble's streaming dots carry the "started, nothing yet" affordance.
  final bool loading;

  /// Index of the first tool call that occurs after this segment starts
  /// (`ReasoningSegment.toolStartIndex` passthrough).
  final int toolStartIndex;

  /// Card passthrough (2026-10-05 revision: the thinking rows keep the
  /// caller's ORIGINAL reasoning-card presentation inside the group — icon
  /// header, individual expand/collapse — and fold with the group like the
  /// tool cards do). The elapsed timer is deliberately NOT per-card: it lives
  /// on the group header only (see `ProcessGroupCard.startAt`), so a message
  /// with several thinking blocks never stacks several timers.
  final bool expanded;
  final void Function()? onToggle;

  const ProcessThought({
    required this.text,
    required this.loading,
    this.toolStartIndex = 0,
    this.expanded = true,
    this.onToggle,
  });
}

/// View of one tool part for grouping purposes. [index] is the part's
/// position in the caller's tool list — the UI shell re-renders the full
/// part through that back-reference.
class ProcessTool {
  final int index;
  final String toolName;
  final bool loading;

  /// Needs the user's hands right now (approval awaiting a decision /
  /// unanswered ask_user). Such cards bypass [showToolCards] and force the
  /// group open (B1).
  final bool requiresUserAction;

  const ProcessTool({
    required this.index,
    required this.toolName,
    this.loading = false,
    this.requiresUserAction = false,
  });
}

/// One row inside the folded group, in timeline order.
sealed class ProcessEntry {
  const ProcessEntry();
}

/// A thinking segment rendered through the caller's ORIGINAL reasoning card
/// (2026-10-05 revision: per-card header/expand stay, per-card timer removed —
/// the group header carries the one elapsed timer; the group only folds and
/// unfolds the rows). [streaming] is the segment's loading verdict.
class ThoughtEntry extends ProcessEntry {
  final String text;
  final bool streaming;
  final bool expanded;
  final void Function()? onToggle;
  const ThoughtEntry({
    required this.text,
    required this.streaming,
    this.expanded = true,
    this.onToggle,
  });
}

/// A tool row rendered through the caller's full part (the pre-folding
/// `_ToolCallItem` look, special cards included).
class ToolEntry extends ProcessEntry {
  final ProcessTool tool;
  const ToolEntry({required this.tool});
}

class ProcessGroupModel {
  /// Interleaved thinking/tool rows in timeline order.
  final List<ProcessEntry> entries;

  /// true → header shows 處理中.../Working… (with the bounce dots);
  /// false → 已完成/Worked. Finished segments never flash live.
  final bool live;

  /// B1: contains an approval-pending / unanswered ask_user card — the group
  /// must stay open and the header stays live regardless of the user's pin.
  final bool forcedOpen;

  /// B3: false → nothing survived the filters; render no group at all
  /// (never an empty collapsible shell).
  final bool visible;

  const ProcessGroupModel({
    required this.entries,
    required this.live,
    required this.forcedOpen,
    required this.visible,
  });
}

/// Fold one assistant message's thinking segments + tool parts into the
/// process group model. Mirrors the pre-folding mixed-content builder
/// (segment order preserved; each segment owns the tool range
/// `[toolStartIndex, next.toolStartIndex)` with the same clamping; the
/// no-segments fallback path puts every tool into one implicit range).
ProcessGroupModel buildProcessGroup({
  required List<ProcessThought> thoughts,
  required List<ProcessTool> tools,
  required bool isStreaming,
  required bool hasAnswerText,
  required bool showThinkingCards,
  required bool showToolCards,
}) {
  final entries = <ProcessEntry>[];

  void addTool(ProcessTool tool) {
    if (tool.toolName == _builtinSearchToolName) return;
    if (tool.toolName == _legacyWorkspaceSnapshotToolName) return;
    // B1: interactive cards (approval pending / unanswered ask_user) are
    // control surfaces, not process display — they bypass showToolCards so
    // the resume pipeline can never be folded away.
    if (!showToolCards && !tool.requiresUserAction) return;
    entries.add(ToolEntry(tool: tool));
  }

  if (thoughts.isEmpty) {
    for (final tool in tools) {
      addTool(tool);
    }
  } else {
    for (int i = 0; i < thoughts.length; i++) {
      final thought = thoughts[i];
      if (showThinkingCards && thought.text.trim().isNotEmpty) {
        entries.add(
          ThoughtEntry(
            text: thought.text,
            streaming: thought.loading,
            expanded: thought.expanded,
            onToggle: thought.onToggle,
          ),
        );
      }
      int start = thought.toolStartIndex;
      final int end = (i < thoughts.length - 1)
          ? thoughts[i + 1].toolStartIndex
          : tools.length;
      if (start < 0) start = 0;
      if (start > tools.length) start = tools.length;
      final int clampedEnd = end.clamp(start, tools.length);
      for (int k = start; k < clampedEnd; k++) {
        addTool(tools[k]);
      }
    }
  }

  final bool forcedOpen = tools.any((t) => t.requiresUserAction);
  final bool live =
      forcedOpen ||
      (isStreaming &&
          (entries.any((e) => e is ToolEntry && e.tool.loading) ||
              entries.any((e) => e is ThoughtEntry && e.streaming) ||
              !hasAnswerText));

  return ProcessGroupModel(
    entries: entries,
    live: live,
    forcedOpen: forcedOpen,
    visible: entries.isNotEmpty,
  );
}

/// Fold state for one group — port of AnyBuff `isGroupOpen` with the
/// OmniChat contracts layered on top:
///
/// 1. B1: a group holding an approval-pending / unanswered ask_user card is
///    forced open and ignores the user's pin (the resume pipeline needs the
///    card on screen).
/// 2. Explicit pin: once the user has toggled the group manually, their
///    choice wins forever — a pinned-open group stays open after the run
///    ends; a pinned-collapsed one never auto-opens.
/// 3. B2: with no pin and `autoCollapse == true` (the existing default), the
///    group follows the run — open while live, folded again once finished;
///    `autoCollapse == false` keeps the group open after the run ends (the
///    label still flips to 已完成/Worked).
bool resolveProcessOpen({
  required bool? explicitOpen,
  required bool forcedOpen,
  required bool live,
  required bool autoCollapse,
}) {
  if (forcedOpen) return true;
  if (explicitOpen != null) return explicitOpen;
  return live || !autoCollapse;
}

/// Start anchor for the process group header's elapsed timer: the first
/// PROCESS event — the first tool call or the first thinking token, whichever
/// comes first ([processStartedAt]). [reasoningStartAt] is only the first
/// *thinking* token, so anchoring on it alone silently drops the leading tool
/// time of a tool-only or tool-first turn (and shows no timer at all when the
/// model never thinks). Null on rows written before the field existed
/// (Hive field 21, 2026-10-05) — the reasoning start is then the best anchor
/// available, i.e. the pre-revision behaviour.
DateTime? resolveProcessStartAt({
  required DateTime? processStartedAt,
  required DateTime? reasoningStartAt,
}) {
  return processStartedAt ?? reasoningStartAt;
}

/// End anchor for the process group header's elapsed timer.
///
/// While [live] the timer counts (null → the shell ticks against the wall
/// clock). Once the run is over it must freeze at the moment the PROCESS
/// ended — the last thinking segment / tool call finished — not at
/// `reasoningFinishedAt`, which is stamped as soon as thinking pauses
/// (before the tools run). Anchoring there would make a message with tools
/// rewind its own timer: it counts up to 11.4s while the tool runs, then
/// snaps back to the 2.0s thinking span the moment the group completes.
///
/// [processFinishedAt] is null on messages persisted before the field existed
/// (Hive field 20, 2026-10-05) and for runs with no process group; those fall
/// back to the thinking end, i.e. the pre-revision behaviour.
DateTime? resolveProcessFinishedAt({
  required bool live,
  required DateTime? processFinishedAt,
  required DateTime? reasoningFinishedAt,
}) {
  if (live) return null;
  return processFinishedAt ?? reasoningFinishedAt;
}

/// Whether one tool part needs the user's hands right now:
///
/// - `ask_user` question without an answer payload yet — null/empty content
///   while the run is paused, or a pending-type payload;
/// - `approval_required` protocol content that is not terminal —
///   `approval_denied` and the approval-timeout error are recorded states;
///   the run already resumed with the structured error JSON.
///
/// Pure predicate over the persisted tool-event content (manual §3.14 §2
/// five-state machine) so the UI shell stays a thin renderer.
bool toolRequiresUserAction({
  required String toolName,
  required String? content,
}) {
  if (toolName == askUserToolName) {
    final parsed = parseAskUserContent(content);
    return parsed == null || parsed['type'] != askUserAnswerType;
  }
  final approval = parseApprovalContent(content);
  if (approval == null) return false;
  if (approval['type'] == approvalDeniedType) return false;
  if ((approval['error'] ?? '').toString() == 'approval_timeout') return false;
  return true;
}
