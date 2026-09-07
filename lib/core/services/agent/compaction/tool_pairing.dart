// Pairing-safe cut selection for neutral OpenAI-format message lists
// (IMPORT_PLAN_COWORK.md P1-2 切點安全).
//
// An assistant message carrying `tool_calls` must be followed by every one
// of its `role:'tool'` results — a cut that lands between them produces a
// request providers reject (§3.11 配對完整性的演算法化保證). This module is the
// shared counter: R0's trim cut points and any other tail-keep walk go
// through it. Pure Dart.
library;

bool _isToolResult(Map<String, dynamic> message) =>
    message['role'] == 'tool';

/// True when a tail starting at [index] keeps every `role:'tool'` result
/// together with the assistant `tool_calls` message that precedes it. A tail
/// may never START on a tool result — its call would stay behind the cut.
bool isLegalTailStart(List<Map<String, dynamic>> messages, int index) {
  if (index < 0 || index > messages.length) return false;
  if (index == messages.length) return true;
  return !_isToolResult(messages[index]);
}

/// Advance [index] forward to the nearest legal tail start (skipping any
/// dangling `role:'tool'` results whose call would remain behind the cut).
/// Returns `messages.length` when only dangling results remain.
int firstLegalTailStart(List<Map<String, dynamic>> messages, int index) {
  var i = index;
  while (i < messages.length && _isToolResult(messages[i])) {
    i++;
  }
  return i;
}

/// True when cutting the list at [index] (keeping `[index, length)`) cannot
/// split a tool-call/result pair. Equivalent to [isLegalTailStart].
bool isLegalCutIndex(List<Map<String, dynamic>> messages, int index) =>
    isLegalTailStart(messages, index);
