// Mid-run compaction (IMPORT_PLAN_COWORK.md P1-2 / P0-2 Phase-1 hooks).
//
// The prep-time trigger evaluates once before a run starts; a long-running
// agent loop can still cross the trigger mid-flight. The kernel's
// `onRoundStart` hook carries `tokensSoFar` (cumulative usage across
// rounds), so the same formula is re-evaluated at every round boundary
// (plan §P1-2: "mid-run 重評估留給 kernel onRoundStart hook（已帶
// tokensSoFar，公式直接復用）").
//
// When the trigger fires, the OLDER portion of the loop's working message
// list — everything before the newest verbatim tail — is rewritten into the
// same deterministic `<conversation_summary>` envelope the prep-time L1
// path produces, IN PLACE on the working list. This is a projection only
// (ADR-A6): the Hive history is never touched; the kernel simply sends the
// next round from the rewritten list, and the messages the loop appends
// afterwards keep the list structurally valid.
//
// Pure Dart: no Hive, no ChatService, no Flutter.
library;

import 'compaction_trigger.dart';
import 'context_trim.dart';
import 'history_compactor.dart';
import 'tool_pairing.dart';

/// Re-evaluate the compaction trigger for a running agent loop and, when it
/// fires, compact the older history of the kernel's working message list in
/// place. Returns `true` when the list was rewritten.
///
/// [messages] is the loop's working list — the assembled apiMessages (with
/// the system message at index 0) plus the rounds' appended neutral
/// assistant/tool messages. [tokensSoFar] is the cumulative token usage the
/// kernel has observed so far (the conservative proxy for the next round's
/// prompt size). The formula, floor, tail budget and pair caps are the
/// prep-time ones, reused verbatim.
bool applyMidRunCompaction(
  List<Map<String, dynamic>> messages, {
  required int tokensSoFar,
  required String modelId,
  required int? learnedWindowTokens,
  String? nextActionOverride,
}) {
  if (messages.isEmpty) return false;

  // Floor: no speculative compaction under 140k tokens — the same fixed
  // floor as prep-time evaluation (v1.4).
  if (tokensSoFar < compactionFloorTokens) return false;

  final seed = learnedWindowTokens == null ? seedWindowForModel(modelId) : null;
  final window =
      resolveContextWindowTokens(modelId, learned: learnedWindowTokens);
  final trigger = compactionTriggerTokens(window, seed?.outputTokens);
  if (tokensSoFar <= trigger) return false;

  // The system message (index 0 of the assembled apiMessages) is never
  // compacted — system prompts and injections must survive every round.
  final start = messages.first['role'] == 'system' ? 1 : 0;
  if (messages.length - start < 2) return false;

  // Tail walk (AnyBuff splitTail semantics), newest-first over the working
  // list: the tail keeps the current turn's work verbatim and stops at the
  // last user prompt (older turns are summarized), under the same tail
  // budget and pair caps as the prep-time boundary walk.
  var lastUser = -1;
  for (var i = messages.length - 1; i >= start; i--) {
    if (messages[i]['role'] == 'user') {
      lastUser = i;
      break;
    }
  }
  // No user prompt in the working list: nothing anchors the tail — skip
  // rather than summarize the turn still in progress.
  if (lastUser < start) return false;

  var boundary = lastUser;
  var pairs = 0;
  var tokens = 0;
  for (var i = lastUser - 1; i >= start; i--) {
    final message = messages[i];
    final role = message['role'];
    if (role == 'user') break; // never cross a user prompt
    if (role == 'assistant' && _hasToolCalls(message)) {
      if (pairs >= tailMaxPairs) break;
      pairs++;
    }
    final cost = _estimateTokens(message);
    if (tokens + cost > tailBudgetTokens) break;
    tokens += cost;
    boundary = i;
  }

  // Pairing safety (shared counter): a tail may never start on a dangling
  // `role:'tool'` result whose call would remain behind the cut.
  boundary = firstLegalTailStart(messages, boundary);
  if (boundary <= start) return false;

  final summary = compactHistoryMessages(
    messages.sublist(start, boundary),
    nextActionOverride: nextActionOverride,
  );
  if (summary == null) return false;

  final head = <Map<String, dynamic>>[
    if (start == 1) messages.first,
    summary,
  ];
  final tail = messages.sublist(boundary);
  messages
    ..clear()
    ..addAll(head)
    ..addAll(tail);
  return true;
}

bool _hasToolCalls(Map<String, dynamic> message) {
  final calls = message['tool_calls'];
  return calls is List && calls.isNotEmpty;
}

/// chars/3 ruler over the wire-relevant text of a neutral message (content
/// plus encoded tool-call arguments).
int _estimateTokens(Map<String, dynamic> message) {
  var chars = 0;
  final content = message['content'];
  if (content is String) chars += content.length;
  final calls = message['tool_calls'];
  if (calls is List) {
    for (final c in calls) {
      if (c is! Map) continue;
      final fn = c['function'];
      if (fn is! Map) continue;
      chars += '${fn['name'] ?? ''}'.length;
      chars += '${fn['arguments'] ?? ''}'.length;
    }
  }
  return (chars / charsPerToken).ceil();
}
