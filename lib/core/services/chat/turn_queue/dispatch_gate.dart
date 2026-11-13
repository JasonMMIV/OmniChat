/// Pure dispatch gate for the turn queue (v1: current conversation only).
///
/// The gate is stateless: every argument is an explicit fact the caller
/// observed at decision time. Keeping it pure lets the race-sensitive cases
/// (approval/ask_user pending, regenerate transitions, cooldowns) be pinned by
/// unit tests instead of guessed at in the controller.
library;

/// Whether the head of [conversationId]'s queue may be dispatched right now.
///
/// Any veto wins; dispatching requires every fact to be clear:
/// - [hasItems]: there is something to dispatch;
/// - [inFlight]: single-flight guard (a dispatch is already running);
/// - [mailboxActive]: a steering run still owns the turn (continuation in
///   progress — the queue must not interleave with it);
/// - [queuePaused]: Stop paused the queue (F10) or repeated failures did;
/// - [internalTransition]: regenerate/resume/approval window (F2/R13);
/// - [checkpointPaused]: the durable journal says a user action is pending
///   (approval / ask_user) — auto-dispatch would hijack the decision (F1/R12);
/// - [isCurrentConversation]: v1 never dispatches in the background;
/// - [cooldownActive]: a failed dispatch is cooling down (R10).
bool canDispatchTurn({
  required bool inFlight,
  required bool mailboxActive,
  required bool queuePaused,
  required bool internalTransition,
  required bool checkpointPaused,
  required bool isCurrentConversation,
  required bool cooldownActive,
  required bool hasItems,
}) {
  if (!hasItems) return false;
  if (inFlight) return false;
  if (mailboxActive) return false;
  if (queuePaused) return false;
  if (internalTransition) return false;
  if (checkpointPaused) return false;
  if (!isCurrentConversation) return false;
  if (cooldownActive) return false;
  return true;
}
