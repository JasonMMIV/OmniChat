// Mid-run compaction (IMPORT_PLAN_COWORK.md P1-2 / P0-2 Phase-1 hooks).
//
// The prep-time trigger evaluates once before a run starts; a long-running
// agent loop can still cross the trigger mid-flight. The kernel's
// `onRoundStart` hook carries cumulative `tokensSoFar` (a budget signal, not
// a prompt size); the driver estimates the next prompt from the working list
// and the last measured `usage.promptTokens`, then re-runs the same formula at
// every round boundary.
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

import '../../model_catalog/model_catalog.dart';
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
/// assistant/tool messages. [promptTokens] is the estimated size of the NEXT
/// round's prompt (see [estimateCompactionPromptTokens]); it is deliberately
/// not the kernel's cumulative usage counter. The formula, floor, tail budget
/// and pair caps are the prep-time ones, reused verbatim.
bool applyMidRunCompaction(
  List<Map<String, dynamic>> messages, {
  required int promptTokens,
  required String modelId,
  required int? learnedWindowTokens,
  String? providerId,
  String? host,
  int? userContextWindow,
  int? userMaxOutput,
  String? nextActionOverride,
}) {
  if (messages.isEmpty) return false;

  final window = resolveContextWindowTokens(
    modelId,
    userOverride: userContextWindow,
    learned: learnedWindowTokens,
    providerId: providerId,
    host: host,
  );
  final outputTokens = (userMaxOutput != null && userMaxOutput > 0)
      ? userMaxOutput
      : ModelCatalog.instance?.outputTokens(
          modelId,
          providerId: providerId,
          host: host,
        );
  final trigger = compactionTriggerTokens(window, outputTokens);
  // The trigger already caps the 140k floor at the model's own window, so
  // "above the trigger" is the complete condition here.
  if (promptTokens <= trigger) return false;

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

  final head = <Map<String, dynamic>>[if (start == 1) messages.first, summary];
  final tail = messages.sublist(boundary);
  messages
    ..clear()
    ..addAll(head)
    ..addAll(tail);
  return true;
}

/// Estimate the size of the next round's prompt for mid-run compaction.
///
/// The kernel's `tokensSoFar` is cumulative across rounds and must never be
/// used here: a 6-round run with a 100k prompt would otherwise look like
/// 600k. The measured prompt is the last round's real `usage.promptTokens`;
/// the working-list estimate covers the tool results appended since then.
int estimateCompactionPromptTokens({
  required List<Map<String, dynamic>> messages,
  required int measuredPromptTokens,
}) {
  final estimated = estimateApiMessagesTokens(messages);
  return estimated > measuredPromptTokens ? estimated : measuredPromptTokens;
}

/// Mid-run entry point used by the kernel hook. It derives the prompt-size
/// input and applies the same floor/trigger/boundary rules as the pure
/// compactor, so callers cannot accidentally feed the cumulative counter.
bool maybeApplyMidRunCompaction(
  List<Map<String, dynamic>> messages, {
  required int measuredPromptTokens,
  required bool enabled,
  required String modelId,
  required int? learnedWindowTokens,
  String? providerId,
  String? host,
  int? userContextWindow,
  int? userMaxOutput,
}) {
  if (!enabled) return false;
  return applyMidRunCompaction(
    messages,
    promptTokens: estimateCompactionPromptTokens(
      messages: messages,
      measuredPromptTokens: measuredPromptTokens,
    ),
    modelId: modelId,
    learnedWindowTokens: learnedWindowTokens,
    providerId: providerId,
    host: host,
    userContextWindow: userContextWindow,
    userMaxOutput: userMaxOutput,
  );
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
