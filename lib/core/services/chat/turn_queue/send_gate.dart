/// Pure gates for the queue-first composer (Anybuff queue/Send-now v1).
///
/// These functions are the single source of truth for:
/// - when a composer input may be enqueued for the running turn ([canQueueChatInput]);
/// - when it may be injected into the running turn mid-stream ([canSteerChatInput]);
/// - why the Send now button is unavailable ([sendNowBlockReason]).
///
/// No Flutter imports: the widget/controller layers call these and must not
/// re-derive the conditions (drift between UI and semantics is what broke
/// previous steering plans).
library;

/// Whether [text] + attachments may be enqueued for the active turn.
///
/// Queue accepts text and/or attachments (F9 ruling: the queue also handles
/// attachments so the normal send pipeline can rebake them at dispatch time).
/// The composer is only in "running" mode while [loading] is true; idle input
/// goes through the normal send path instead.
bool canQueueChatInput({
  required bool loading,
  required String text,
  int imageCount = 0,
  int documentCount = 0,
}) {
  if (!loading) return false;
  return text.trim().isNotEmpty || imageCount > 0 || documentCount > 0;
}

/// Whether [text] may be injected into the running turn (Send now).
///
/// Steering is pure-text only: attachments, `/`-prefixed commands and
/// `@profile` delegations must go through the queue so their full context is
/// rebaked by the normal send pipeline instead of being silently dropped
/// mid-turn.
bool canSteerChatInput({
  required bool loading,
  required String text,
  int imageCount = 0,
  int documentCount = 0,
}) {
  if (!loading) return false;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  if (imageCount > 0 || documentCount > 0) return false;
  return !trimmed.startsWith('/') && !trimmed.startsWith('@');
}

/// Why Send now is unavailable; drives the disabled state + tooltip.
enum SendNowBlockReason {
  /// Send now is allowed.
  none,

  /// The composer holds attachments (text may also be present).
  attachments,

  /// The composer text starts with `/` (slash command / skill token).
  command,

  /// The composer text starts with `@profile` (direct subagent delegation).
  delegation,

  /// An AI Team run (proposer or aggregator) is active.
  team,

  /// No active turn or no text — the button is not shown at all.
  inactive,
}

/// Resolves the [SendNowBlockReason] for the current composer state.
///
/// Check order matters: attachments make the input unsteerable even when the
/// team hint also applies (the attachment tooltip is the actionable one).
SendNowBlockReason sendNowBlockReason({
  required bool loading,
  required String text,
  int imageCount = 0,
  int documentCount = 0,
  bool teamActive = false,
}) {
  if (!loading) return SendNowBlockReason.inactive;
  if (imageCount > 0 || documentCount > 0) {
    return SendNowBlockReason.attachments;
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) return SendNowBlockReason.inactive;
  if (teamActive) return SendNowBlockReason.team;
  if (trimmed.startsWith('/')) return SendNowBlockReason.command;
  if (trimmed.startsWith('@')) return SendNowBlockReason.delegation;
  return SendNowBlockReason.none;
}
