import 'agent_run_checkpoint.dart';

/// Why an unfinished agent run is still listed in the P3-3 task surface.
enum AgentRunTaskReason {
  /// A tool call is waiting for an approval decision.
  approval,

  /// The run paused on an `ask_user` question card.
  askUser,

  /// The run failed after at least one durable boundary.
  interrupted,

  /// The process died mid-run (or the app is still running it).
  running,

  /// The kernel stopped at `max_steps` / `token_budget`.
  softStopped,
}

/// A checkpoint paired with its user-facing reason and conversation title.
///
/// The checkpoint remains the authoritative payload; this wrapper only adds
/// presentation context so the task list can be sorted and rendered.
class AgentRunTask {
  const AgentRunTask({
    required this.checkpoint,
    required this.reason,
    this.conversationTitle,
    this.isActive = false,
  });

  final AgentRunCheckpoint checkpoint;
  final AgentRunTaskReason reason;
  final String? conversationTitle;

  /// True when this app still has a generation running for the conversation.
  /// The checkpoint stays on disk until the terminal handler clears it, so the
  /// journal alone cannot distinguish an active run from a crash.
  final bool isActive;

  bool get requiresUserAction =>
      reason == AgentRunTaskReason.approval ||
      reason == AgentRunTaskReason.askUser;

  /// The pending tool the user should see first. Ask-user wins over approval
  /// in [reason], so the displayed name must follow that same priority rather
  /// than simply taking the first journal entry.
  AgentRunPendingTool? get primaryPendingTool {
    if (checkpoint.pendingTools.isEmpty) return null;
    if (reason == AgentRunTaskReason.askUser) {
      for (final tool in checkpoint.pendingTools) {
        if (tool.isAskUser) return tool;
      }
    } else if (reason == AgentRunTaskReason.approval) {
      for (final tool in checkpoint.pendingTools) {
        if (tool.isApproval) return tool;
      }
    }
    return checkpoint.pendingTools.first;
  }

  /// Newest first. The journal keeps one row per conversation.
  static int compareNewestFirst(AgentRunTask a, AgentRunTask b) =>
      b.checkpoint.updatedAtMs.compareTo(a.checkpoint.updatedAtMs);

  static AgentRunTask fromCheckpoint(
    AgentRunCheckpoint checkpoint, {
    String? conversationTitle,
    bool isActive = false,
  }) {
    return AgentRunTask(
      checkpoint: checkpoint,
      reason: _reasonFor(checkpoint),
      conversationTitle: conversationTitle,
      isActive: isActive,
    );
  }

  static AgentRunTaskReason _reasonFor(AgentRunCheckpoint checkpoint) {
    switch (checkpoint.phase) {
      case agentRunPhasePaused:
        // ask_user wins when a row somehow carries both kinds: the question
        // card is the action the user must answer first.
        for (final tool in checkpoint.pendingTools) {
          if (tool.isAskUser) return AgentRunTaskReason.askUser;
        }
        for (final tool in checkpoint.pendingTools) {
          if (tool.isApproval) return AgentRunTaskReason.approval;
        }
        return AgentRunTaskReason.interrupted;
      case agentRunPhaseSoftStopped:
        return AgentRunTaskReason.softStopped;
      case agentRunPhaseRunning:
        return AgentRunTaskReason.running;
      case agentRunPhaseInterrupted:
      default:
        return AgentRunTaskReason.interrupted;
    }
  }
}
