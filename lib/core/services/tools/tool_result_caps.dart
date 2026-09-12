// Workspace zero-residue plan (PLAN_WORKSPACE_ZERO_RESIDUE.md Phase 1.1).
//
// Replaces the retired P1-4 long-output externalization: oversized tool
// results are capped IN MEMORY (head/tail, AnyBuff `BoundedOutputBuffer`
// shape) instead of being persisted under `{workspace}/.omnichat/`. The
// workspace stays clean; the model re-queries the source instead of paging
// through a persisted dump.
//
// Budget contract (2026-09-12 review fix): the capped payload — head, marker
// AND re-query guidance included — must fit inside [capThresholdChars]. The
// transport backstop re-caps every tool message it sees, so a payload that
// overshoots the budget gets its middle (marker + guidance) silently cut and
// its reported size rewritten to the capped length. Staying inside the budget
// keeps both the guidance and the true size intact on the wire.
//
// Single truncation path: the transport-level backstop
// (`ChatApiService._truncateToolResultText`) delegates to [capBare], so every
// oversized tool result takes the same shape exactly once.
//
// Pure Dart (no Flutter imports) so it can be unit-tested without bindings.

/// In-memory cap for oversized tool results (PLAN_WORKSPACE_ZERO_RESIDUE.md
/// Phase 1). Head/tail split mirrors the retired transport backstop so the
/// on-wire shape is unchanged for results that previously fell through to it.
class ToolResultCaps {
  ToolResultCaps._();

  /// Results longer than this are capped. Matches the API tool-result budget
  /// that the transport backstop historically used.
  static const int capThresholdChars = 32768;

  /// Marker inserted between the kept head and tail.
  static const String truncationMarker =
      '[... tool output truncated — {KB} KB total ...]';

  /// Prefix of [truncationMarker] — identifies an already-capped payload.
  static const String truncationMarkerPrefix = '[... tool output truncated';

  /// Recognition window for payloads capped by the pre-2026-09-12 code, whose
  /// marker + guidance sat ~183 chars ABOVE the budget. Anything carrying the
  /// marker inside this window passes through untouched; the window stays
  /// bounded so a document that merely quotes the marker text can never
  /// smuggle an unbounded payload past the cap.
  static const int alreadyCappedSlackChars = 256;

  /// Guidance appended after the marker, per tool family.
  static const String fileToolGuidance =
      'Re-query the source instead: use file_read with offset/limit to page '
      'through the file, or file_search to locate the relevant section.';

  static const String searchToolGuidance =
      'Re-run the search with narrower parameters (more specific query, '
      'lower max_results) to retrieve the specific portion you need.';

  static const String genericGuidance =
      'Re-run the tool with narrower parameters to retrieve the specific '
      'portion you need.';

  /// Cap [result] to [capThresholdChars]: head + marker + tool-family
  /// re-query guidance + tail. Returns [result] unchanged when it does not
  /// exceed the threshold, or when it is already capped. Pure function —
  /// never touches disk.
  static String cap({required String toolName, required String result}) {
    if (result.length <= capThresholdChars) return result;
    if (_alreadyCapped(result)) return result;

    return _truncate(
      result,
      block: '${_marker(result.length)}\n\n${_guidanceFor(toolName)}',
    );
  }

  /// Transport-level backstop alias (same shape, no guidance): kept as a
  /// named entry point so `ChatApiService._truncateToolResultText` and the
  /// handler-level cap share one implementation.
  static String capBare(String result) {
    if (result.length <= capThresholdChars) return result;
    if (_alreadyCapped(result)) return result;

    return _truncate(result, block: _marker(result.length));
  }

  /// Head + [block] + tail, sized so the total never exceeds
  /// [capThresholdChars] (4 = the two `\n\n` separators around [block]).
  /// Overshooting that budget is what let the transport backstop cut the
  /// marker and guidance out of the middle (2026-09-12 review, F1).
  static String _truncate(String result, {required String block}) {
    final contentBudget = capThresholdChars - block.length - 4;
    final headLen = contentBudget ~/ 2;
    final tailLen = contentBudget - headLen;
    final head = result.substring(0, headLen);
    final tail = result.substring(result.length - tailLen);
    return '$head\n\n$block\n\n$tail';
  }

  static String _marker(int originalLength) => truncationMarker.replaceFirst(
    '{KB}',
    '${(originalLength / 1024).round()}',
  );

  static bool _alreadyCapped(String result) =>
      result.length <= capThresholdChars + alreadyCappedSlackChars &&
      result.contains(truncationMarkerPrefix);

  static String _guidanceFor(String toolName) {
    if (toolName.startsWith('file_')) return fileToolGuidance;
    if (toolName == 'search_web') return searchToolGuidance;
    return genericGuidance;
  }
}
