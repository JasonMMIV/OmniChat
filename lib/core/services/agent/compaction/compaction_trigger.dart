// Compaction trigger evaluation (IMPORT_PLAN_COWORK.md P1-2).
//
// v1 evaluates triggers only at generation prep, from the real measured
// usage persisted per message (`ChatMessage.promptTokens`). Formula and
// floor come from the plan: `trigger = min(0.7W, W - reserve(W, out))` with
// the seed-table window (learned windows win), and contexts under 140k
// tokens get no speculative compaction. `cache_expiry` is deferred to
// Phase 2 (v1.4).
//
// When the trigger fires, the boundary walk collects the newest verbatim
// tail (K=8 tool-bearing assistant rounds, 10k token budget) in the RAW
// message-list space — the same space as `Conversation.truncateIndex` — and
// the boundary becomes the persisted `compactBeforeIndex` marker. Cutting at
// a raw-message boundary is always pairing-safe: an assistant message's
// tool events replay as one self-contained block at assembly time.
library;

import '../../../models/chat_message.dart';
import 'context_trim.dart';

/// Contexts below this get no speculative compaction: 2 × (20k + 50k).
/// Information loss is not worth it at that scale (AnyBuff
/// DEFAULT_CACHE_EXPIRY_MIN_TOKENS, fixed value per v1.4).
const int compactionFloorTokens = 140_000;

/// Verbatim-tail budget, in estimated tokens (chars/3 ruler).
const int tailBudgetTokens = 10_000;

/// Maximum number of tool-bearing assistant rounds the tail may carry.
const int tailMaxPairs = 8;

/// Estimated tokens of one raw message INCLUDING its tool events. Provided
/// by the caller (generation prep) so this module stays free of
/// ChatService/tool-event plumbing.
typedef RawMessageTokensFn = int Function(ChatMessage message);

/// Whether the raw assistant message carried any tool calls.
typedef HasToolEventsFn = bool Function(ChatMessage message);

class CompactionTriggerResult {
  /// Whether the measured usage is over the trigger.
  final bool overTrigger;

  /// Raw-space boundary for the `compactBeforeIndex` marker: messages
  /// `[0, boundary)` would be compacted, `[boundary, end)` stay live.
  /// `-1` when no compaction should happen.
  final int boundaryIndex;

  const CompactionTriggerResult({
    required this.overTrigger,
    required this.boundaryIndex,
  });

  static const CompactionTriggerResult none = CompactionTriggerResult(
    overTrigger: false,
    boundaryIndex: -1,
  );
}

/// Evaluate the compaction trigger for the raw message list of a
/// conversation. [messages] is the FULL raw list (the live user prompt is
/// the newest entry). [measuredPromptTokens] is the persisted
/// `promptTokens` of the latest assistant message that has one.
CompactionTriggerResult evaluateCompactionTrigger({
  required List<ChatMessage> messages,
  required int? measuredPromptTokens,
  required String modelId,
  required int? learnedWindowTokens,
  required RawMessageTokensFn estimateMessageTokens,
  required HasToolEventsFn hasToolEvents,
}) {
  if (messages.isEmpty) return CompactionTriggerResult.none;
  if (measuredPromptTokens == null || measuredPromptTokens <= 0) {
    return CompactionTriggerResult.none;
  }
  // Floor: no speculative compaction under 140k tokens.
  if (measuredPromptTokens < compactionFloorTokens) {
    return CompactionTriggerResult.none;
  }

  final seed = learnedWindowTokens == null ? seedWindowForModel(modelId) : null;
  final window = resolveContextWindowTokens(modelId, learned: learnedWindowTokens);
  final trigger = compactionTriggerTokens(window, seed?.outputTokens);
  if (measuredPromptTokens <= trigger) {
    return CompactionTriggerResult(
      overTrigger: false,
      boundaryIndex: -1,
    );
  }

  // Boundary walk (AnyBuff splitTail semantics): the live user prompt and
  // everything after it are always kept verbatim; the walk runs over the
  // history BEFORE the live prompt, newest-first, and stops at the previous
  // user prompt (the tail is the current turn's work — older turns are
  // fully summarized), under the tail budget and pair cap.
  var lastUserIndex = -1;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role == 'user') {
      lastUserIndex = i;
      break;
    }
  }
  if (lastUserIndex < 0) {
    // No live user prompt (should not happen at generation prep).
    return CompactionTriggerResult(overTrigger: true, boundaryIndex: -1);
  }

  var boundary = lastUserIndex; // tail = [boundary, end)
  var pairs = 0;
  var tokens = 0;
  for (var i = lastUserIndex - 1; i >= 0; i--) {
    final message = messages[i];
    if (message.role == 'user') break; // never cross a user prompt
    if (message.role == 'assistant' && hasToolEvents(message)) {
      if (pairs >= tailMaxPairs) break;
      pairs++;
    }
    final cost = estimateMessageTokens(message);
    if (tokens + cost > tailBudgetTokens) break;
    tokens += cost;
    boundary = i;
  }

  if (boundary <= 0) {
    return CompactionTriggerResult(overTrigger: true, boundaryIndex: -1);
  }

  // Snap the boundary back to a version-group start so collapsing versions
  // independently on either side can never split a group.
  while (boundary > 0 && _sameGroup(messages[boundary - 1], messages[boundary])) {
    boundary--;
  }
  if (boundary <= 0) {
    return CompactionTriggerResult(overTrigger: true, boundaryIndex: -1);
  }

  return CompactionTriggerResult(overTrigger: true, boundaryIndex: boundary);
}

bool _sameGroup(ChatMessage a, ChatMessage b) {
  final ga = a.groupId ?? a.id;
  final gb = b.groupId ?? b.id;
  return ga == gb;
}
