// L0 tool-result middle pruner (IMPORT_PLAN_COWORK.md P1-2).
//
// Ported from deepseek-harness compaction-tool-result-pruner/config.ts:
// results over 8192 chars keep a 4096-char head and a 1024-char tail with a
// marker in the middle. Applied to replayed tool events and cross-turn
// `role:'tool'` messages at the `buildApiMessages` exit; the existing 32KB
// head/tail truncation in `chat_api_service` stays as the extreme-value
// backstop. Pure Dart, idempotent, non-destructive (mutates only the
// assembled projection, never Hive history).
library;

/// Results longer than this (chars) get middle-pruned.
const int toolResultPruneThresholdChars = 8192;

/// Chars kept from the head of a pruned result.
const int toolResultPruneHeadChars = 4096;

/// Chars kept from the tail of a pruned result.
const int toolResultPruneTailChars = 1024;

const String toolResultPruneMarker = '\n[... tool result middle pruned ...]\n';

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

/// Surrogate-safe cut: never split a UTF-16 surrogate pair at [index].
int _safeCutIndex(String text, int index) {
  if (index <= 0) return 0;
  if (index >= text.length) return text.length;
  if (_isHighSurrogate(text.codeUnitAt(index - 1)) &&
      _isLowSurrogate(text.codeUnitAt(index))) {
    return index - 1;
  }
  return index;
}

/// Returns the pruned text, or `null` when [content] is at or below the
/// threshold (also covers already-pruned results — the pruned form is
/// ~5.2k chars, well under the threshold, so re-pruning is a no-op).
String? pruneToolResultText(String content) {
  if (content.length <= toolResultPruneThresholdChars) return null;
  final headEnd = _safeCutIndex(content, toolResultPruneHeadChars);
  final head = content.substring(0, headEnd);
  final tailStart =
      _safeCutIndex(content, content.length - toolResultPruneTailChars);
  final tail = tailStart < headEnd ? '' : content.substring(tailStart);
  return '$head$toolResultPruneMarker$tail';
}

/// L0 pass over a neutral message list: middle-prune every `role:'tool'`
/// content string in place.
void applyToolResultMiddlePrune(List<Map<String, dynamic>> messages) {
  for (final m in messages) {
    if (m['role'] != 'tool') continue;
    final content = m['content'];
    if (content is! String) continue;
    final pruned = pruneToolResultText(content);
    if (pruned != null) m['content'] = pruned;
  }
}
