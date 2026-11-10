// write_todos data model — the shared contract for the tool handler, the
// conversation-event projection and the UI cards
// (docs/write_todos_improvement_plan.md §2.1/§2.2/§2.6).
//
// The latest successful `write_todos` conversation event is the ONLY truth:
// there is no separate todo store. Every reader of a `write_todos` input or
// result goes through this module so one payload can never be interpreted
// three different ways.
//
// Design notes:
// - Lenient input parsing (Anybuff `coerceToArray` semantics): a single
//   object or a stringified JSON array is coerced before validation.
// - Strict canonical parsing: only a well-formed `todo_snapshot` JSON result
//   is trusted verbatim; anything else is rebuilt from the raw arguments.
// - Any invalid item rejects the WHOLE input (§2.2.1) — a malformed call must
//   never silently clear or rewrite the current plan.
// - Booleans are parsed strictly: `"false"` must never become `true`
//   (the `Boolean()` defect documented in Anybuff §1.8.2).
library;

import 'dart:convert';

const String todoToolName = 'write_todos';

const String todoStatusPending = 'pending';
const String todoStatusInProgress = 'in_progress';
const String todoStatusCompleted = 'completed';

/// Plan caps (§2.2.2). Centralized so the JSON schema, the handler and the
/// projection can never drift apart. Tunable per prompt budget.
const int todoMaxItems = 50;
const int todoMaxItemChars = 2000;
const int todoMaxTotalChars = 8000;

/// Tool-result type marker for canonical snapshots (§2.2.3).
const String todoSnapshotType = 'todo_snapshot';

class TodoItem {
  final String content;
  final String status; // pending | in_progress | completed

  const TodoItem({required this.content, required this.status});

  bool get isCompleted => status == todoStatusCompleted;
  bool get isInProgress => status == todoStatusInProgress;

  Map<String, dynamic> toJson() => {'content': content, 'status': status};

  @override
  bool operator ==(Object other) =>
      other is TodoItem && other.content == content && other.status == status;

  @override
  int get hashCode => Object.hash(content, status);
}

// ---------------------------------------------------------------------------
// Status / boolean normalization
// ---------------------------------------------------------------------------

/// Maps a raw status (including common aliases) to the canonical three-state
/// vocabulary. Returns null when the value is not parseable — the caller must
/// treat that as an invalid item (§2.2.1), never silently `pending`.
String? canonicalTodoStatus(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case todoStatusPending:
    case 'open':
    case 'todo':
    case 'not started':
      return todoStatusPending;
    case todoStatusInProgress:
    case 'doing':
    case 'active':
    case 'current':
    case 'wip':
      return todoStatusInProgress;
    case todoStatusCompleted:
    case 'done':
    case 'complete':
    case 'finished':
      return todoStatusCompleted;
    default:
      return null;
  }
}

/// Strict boolean parse for the `completed` alias (§2.2.1): `"false"` and
/// `"0"` must map to `false`, never truthy-coerced. Returns null when the
/// value is not a recognizable boolean.
bool? parseTodoBool(Object? raw) {
  if (raw is bool) return raw;
  if (raw is num) {
    if (raw == 1) return true;
    if (raw == 0) return false;
    return null;
  }
  switch ((raw ?? '').toString().trim().toLowerCase()) {
    case 'true':
    case '1':
    case 'yes':
      return true;
    case 'false':
    case '0':
    case 'no':
      return false;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Lenient input parsing (tool arguments)
// ---------------------------------------------------------------------------

/// One rejected item of a `write_todos` call (§2.2.1: any invalid item
/// rejects the whole input; the error carries index + reason).
class TodoInvalidItem {
  final int index;
  final String reason;

  const TodoInvalidItem(this.index, this.reason);

  Map<String, dynamic> toJson() => {'index': index, 'reason': reason};
}

class TodoListParseResult {
  /// Canonical items (coerced / aliased / capped). Empty when the input was
  /// rejected or explicitly cleared.
  final List<TodoItem> items;

  /// Normalization notes that mean the canonical list DIFFERS from the raw
  /// input (aliases, defaulted status). These drive [changed] and ride the
  /// `changed=true` result.
  final List<String> warnings;

  /// Advisory notes that do NOT change the canonical list (e.g. several
  /// in_progress items). Reported to the model but never flip [changed]
  /// (§2.2.3).
  final List<String> advisoryWarnings;

  /// Non-empty ⇒ the whole input is rejected (`invalid_todos`).
  final List<TodoInvalidItem> invalidItems;

  /// True when items or characters were dropped due to the caps.
  final bool truncated;

  /// True when shape-level coercion happened (single object / stringified
  /// JSON) — the canonical list differs from what the model literally sent.
  final bool coerced;

  const TodoListParseResult({
    required this.items,
    required this.warnings,
    required this.advisoryWarnings,
    required this.invalidItems,
    required this.truncated,
    required this.coerced,
  });

  bool get isValid => invalidItems.isEmpty;

  /// The canonical list differs from the raw input (coercion / alias /
  /// truncation). Pure advisory warnings (e.g. several in_progress items) do
  /// NOT count as changed (§2.2.3).
  bool get changed => coerced || truncated || warnings.isNotEmpty;
}

/// Lenient + strict-item parse of the model's `todos` argument. Accepts:
/// - a JSON array of items,
/// - a single item object (wrapped),
/// - a stringified JSON array / object.
/// Any invalid item ⇒ [TodoListParseResult.isValid] is false and the caller
/// must reject the whole call while KEEPING the previous plan.
TodoListParseResult parseTodoListInput(
  Object? raw, {
  int maxItems = todoMaxItems,
  int maxItemChars = todoMaxItemChars,
  int maxTotalChars = todoMaxTotalChars,
  bool dropInvalidItems = false,
}) {
  TodoListParseResult reject(String reason) => TodoListParseResult(
        items: const <TodoItem>[],
        warnings: const <String>[],
        advisoryWarnings: const <String>[],
        invalidItems: <TodoInvalidItem>[TodoInvalidItem(0, reason)],
        truncated: false,
        coerced: false,
      );

  List<dynamic> list;
  var coerced = false;
  if (raw is List) {
    list = raw;
  } else if (raw is Map) {
    // Single object → wrap in an array (Anybuff coerceToArray).
    list = <Object>[raw];
    coerced = true;
  } else if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return reject('missing_todos');
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    if (decoded is List) {
      list = decoded;
      coerced = true;
    } else if (decoded is Map) {
      list = <Object>[decoded];
      coerced = true;
    } else {
      return reject('unparseable_json');
    }
  } else {
    // null / missing key / unexpected scalar.
    return reject('missing_todos');
  }

  final items = <TodoItem>[];
  final warnings = <String>[];
  final invalid = <TodoInvalidItem>[];
  var truncated = false;
  var totalChars = 0;
  var inProgressCount = 0;

  for (var i = 0; i < list.length; i++) {
    if (items.length >= maxItems) {
      truncated = true;
      warnings.add('item $i: dropped, maxItems=$maxItems reached');
      break;
    }
    final entry = list[i];
    if (entry is! Map) {
      invalid.add(TodoInvalidItem(i, 'not_an_object'));
      if (dropInvalidItems) {
        warnings.add('item $i: dropped (not_an_object)');
      }
      continue;
    }
    final map = entry.map((k, v) => MapEntry(k.toString(), v));

    // content, with the `task` alias (§2.2.1).
    var content = map['content'];
    if (content == null && map.containsKey('task')) {
      content = map['task'];
      warnings.add("item $i: 'task' normalized to 'content'");
    }
    var contentText = content?.toString().trim() ?? '';
    if (contentText.isEmpty) {
      invalid.add(TodoInvalidItem(i, 'empty_content'));
      if (dropInvalidItems) {
        warnings.add('item $i: dropped (empty_content)');
      }
      continue;
    }

    // status, with the `completed` alias. `status` wins when both exist.
    String status;
    final rawStatus = map['status'];
    if (rawStatus != null) {
      final canonical = canonicalTodoStatus(rawStatus.toString());
      if (canonical == null) {
        invalid.add(TodoInvalidItem(i, 'invalid_status'));
        if (dropInvalidItems) {
          warnings.add('item $i: dropped (invalid_status)');
        }
        continue;
      }
      if (canonical != rawStatus.toString().trim().toLowerCase()) {
        warnings.add(
          "item $i: status '${rawStatus.toString().trim()}' "
          "normalized to '$canonical'",
        );
      }
      status = canonical;
    } else if (map.containsKey('completed')) {
      final flag = parseTodoBool(map['completed']);
      if (flag == null) {
        invalid.add(TodoInvalidItem(i, 'invalid_completed'));
        if (dropInvalidItems) {
          warnings.add('item $i: dropped (invalid_completed)');
        }
        continue;
      }
      status = flag ? todoStatusCompleted : todoStatusPending;
      warnings.add("item $i: 'completed' normalized to status '$status'");
    } else {
      status = todoStatusPending;
      warnings.add('item $i: missing status defaulted to pending');
    }

    if (contentText.length > maxItemChars) {
      contentText = contentText.substring(0, maxItemChars);
      truncated = true;
      warnings.add('item $i: content truncated to maxItemChars=$maxItemChars');
    }
    if (totalChars + contentText.length > maxTotalChars && items.isNotEmpty) {
      truncated = true;
      warnings.add('item $i: dropped, maxTotalChars=$maxTotalChars reached');
      break;
    }

    if (status == todoStatusInProgress) inProgressCount++;
    totalChars += contentText.length;
    items.add(TodoItem(content: contentText, status: status));
  }

  final advisory = <String>[
    if (inProgressCount > 1)
      '$inProgressCount items are in_progress; '
          'keep exactly one while working',
  ];

  // §2.2.1: any invalid item rejects the WHOLE input — nothing is adopted,
  // the caller keeps the previous plan and answers `invalid_todos`. The UI's
  // legacy-render path opts into [dropInvalidItems] instead so partially
  // valid historical arguments still show their valid entries.
  if (invalid.isNotEmpty && !dropInvalidItems) {
    return TodoListParseResult(
      items: const <TodoItem>[],
      warnings: const <String>[],
      advisoryWarnings: const <String>[],
      invalidItems: List.unmodifiable(invalid),
      truncated: truncated,
      coerced: coerced,
    );
  }

  return TodoListParseResult(
    items: List.unmodifiable(items),
    warnings: List.unmodifiable(warnings),
    advisoryWarnings: List.unmodifiable(advisory),
    invalidItems: const <TodoInvalidItem>[],
    truncated: truncated,
    coerced: coerced,
  );
}

// ---------------------------------------------------------------------------
// Canonical snapshot parsing (tool results)
// ---------------------------------------------------------------------------

class TodoSnapshotData {
  /// Canonical items when the snapshot carries an `items` array; empty
  /// otherwise (compact counts-only result).
  final List<TodoItem> items;

  /// True when the snapshot carried an `items` array (full / changed result).
  final bool hasItems;

  final bool changed;
  final bool cleared;
  final List<String> warnings;
  final String? notice;

  const TodoSnapshotData({
    required this.items,
    required this.hasItems,
    required this.changed,
    required this.cleared,
    required this.warnings,
    required this.notice,
  });
}

/// Strict parse of a persisted `todo_snapshot` tool result (§2.1.2 rule 3/4).
/// Returns null when [content] is not a `todo_snapshot` payload at all, and
/// null when the payload is corrupt (caller falls back to the arguments).
TodoSnapshotData? parseTodoSnapshotContent(String? content) {
  if (content == null || content.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(content);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['type']?.toString() != todoSnapshotType) return null;

  final warnings = <String>[
    for (final w in (decoded['warnings'] as List? ?? const <dynamic>[]))
      w.toString(),
  ];
  final notice = decoded['notice']?.toString();
  final changed = decoded['changed'] == true;
  final cleared = decoded['cleared'] == true;
  final rawItems = decoded['items'];

  if (rawItems is List) {
    final items = <TodoItem>[];
    for (final entry in rawItems) {
      if (entry is! Map) return null; // corrupt canonical payload
      final contentText = (entry['content'] ?? '').toString().trim();
      final status = canonicalTodoStatus(entry['status']?.toString());
      if (contentText.isEmpty || status == null) return null;
      items.add(TodoItem(content: contentText, status: status));
    }
    return TodoSnapshotData(
      items: List.unmodifiable(items),
      hasItems: true,
      changed: changed,
      cleared: cleared,
      warnings: warnings,
      notice: notice,
    );
  }

  // Compact result: counts only, no items key — the caller must rebuild from
  // the event arguments.
  return TodoSnapshotData(
    items: const <TodoItem>[],
    hasItems: false,
    changed: changed,
    cleared: cleared,
    warnings: warnings,
    notice: notice,
  );
}

/// Whether [content] is a `tool_error` payload (a failed write must never
/// advance the projected state, §2.1.2 rule 3).
bool isTodoToolErrorContent(String? content) {
  if (content == null || content.isEmpty) return false;
  try {
    final decoded = jsonDecode(content);
    return decoded is Map && decoded['type']?.toString() == 'tool_error';
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Canonical result building
// ---------------------------------------------------------------------------

Map<String, dynamic> buildTodoCounts(List<TodoItem> items) =>
    <String, int>{
      'total': items.length,
      'pending': items.where((t) => t.status == todoStatusPending).length,
      'inProgress': items.where((t) => t.isInProgress).length,
      'completed': items.where((t) => t.isCompleted).length,
    };

/// Maintenance notice attached to every successful `write_todos` result.
///
/// The all-complete branch deliberately stops asking for another update:
/// telling the model to "continue with the remaining steps" at N/N would
/// contradict the final snapshot and encourage it to invent more work.
String buildTodoProgressNotice({
  required int completed,
  required int total,
  required bool cleared,
}) {
  if (cleared) {
    return 'Plan cleared. Do not resend the old list; call write_todos with a '
        'complete new list only if the task changes or continues.';
  }
  if (total > 0 && completed == total) {
    return 'Plan complete: $completed/$total done. No further write_todos '
        'update is needed unless the task changes.';
  }
  return 'Plan updated: $completed/$total complete. Continue with the '
      'remaining steps. After finishing each step, call write_todos again, '
      'rewrite ALL todos with their current statuses, and mark that step '
      'completed. Keep exactly one item in_progress.';
}

/// Builds the canonical `todo_snapshot` tool-result content (§2.2.3):
/// - `changed=false` real result: no `items` (token-efficient, Anybuff
///   `318ead2df`), the model still has its own tool-call arguments;
/// - `changed=true` real result: canonical `items` + `warnings`;
/// - synthetic trailing state pair: `includeItems: true` + `notice`, so the
///   next turn always sees the full snapshot regardless of result trimming.
/// `<`/`>` are escaped so todo content can never close a tag early (§2.6).
String buildTodoResultContent({
  required List<TodoItem> items,
  required bool changed,
  required bool cleared,
  List<String> warnings = const <String>[],
  bool truncated = false,
  bool includeItems = false,
  String? notice,
}) {
  final map = <String, dynamic>{
    'type': todoSnapshotType,
    'changed': changed,
    if (includeItems || changed)
      'items': <Map<String, dynamic>>[for (final t in items) t.toJson()],
    'counts': buildTodoCounts(items),
    if (warnings.isNotEmpty) 'warnings': List<String>.of(warnings),
    if (truncated) 'truncated': true,
    'cleared': cleared,
    if (notice != null) 'notice': notice,
  };
  return escapeJsonAngleBrackets(jsonEncode(map));
}

/// Escapes literal `<` / `>` in an already-encoded JSON string so injected
/// todo content cannot terminate a tag/block early (§2.6). Round-trips: a
/// JSON parser decodes `\u003c` back into `<`.
String escapeJsonAngleBrackets(String json) => json
    .replaceAll('<', r'\u003c')
    .replaceAll('>', r'\u003e');

// ---------------------------------------------------------------------------
// Synthetic trailing state pair helpers (§2.3.2)
// ---------------------------------------------------------------------------

/// Canonical arguments JSON for a state pair (`{"todos":[...]}`).
String buildTodoStateArgumentsJson(List<TodoItem> items) =>
    escapeJsonAngleBrackets(
      jsonEncode(<String, dynamic>{
        'todos': <Map<String, dynamic>>[for (final t in items) t.toJson()],
      }),
    );

/// Deterministic, time-free id for a state pair whose real `toolCallId` is
/// missing or colliding (§2.3.2: never a timestamp — the same state must keep
/// the same id across retries so the cache prefix stays stable).
String todoStateHashId(List<TodoItem> items, {String seed = ''}) {
  final source = '$seed|${buildTodoStateArgumentsJson(items)}';
  // FNV-1a 32-bit over UTF-16 code units.
  var hash = 0x811c9dc5;
  for (final unit in source.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
    hash ^= (unit >> 8) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'todo_state_${hash.toRadixString(16)}';
}

// ---------------------------------------------------------------------------
// Projection state
// ---------------------------------------------------------------------------

/// The projected plan state of one conversation (§2.1.1).
class TodoState {
  final List<TodoItem> items;

  /// Assistant message that carried the latest successful event.
  final String? sourceMessageId;

  /// Real `toolCallId` of the latest successful event (pair-id preference).
  final String? sourceToolCallId;

  /// True when a successful `write_todos` event exists at all — even for an
  /// explicit clear (`items` empty). Distinguishes "cleared" from "never had
  /// a plan" (§2.1.1).
  final bool hasExplicitState;

  final DateTime? updatedAt;

  const TodoState({
    required this.items,
    required this.hasExplicitState,
    this.sourceMessageId,
    this.sourceToolCallId,
    this.updatedAt,
  });

  bool get isCleared => hasExplicitState && items.isEmpty;
}

// ---------------------------------------------------------------------------
// Compaction summary (§2.6, Anybuff context-pruner §1.8.5)
// ---------------------------------------------------------------------------

String _sanitizeSingleLine(String raw) {
  final flattened = raw.replaceAll(RegExp(r'[\r\n\t\x00-\x1f]+'), ' ').trim();
  return flattened;
}

/// Builds the `Todos: x/y complete. Remaining: ...` knowledge-block summary
/// from the latest successful snapshot. Single-line items, capped count and
/// chars so it can never crowd out Goal/Files/Edits. An explicit clear reads
/// `Todos: cleared` (never `0/0`).
String buildTodoCompactionSummary(
  TodoState? state, {
  int maxRemaining = 8,
  int maxChars = 400,
}) {
  if (state == null) return '';
  if (state.items.isEmpty) {
    return state.hasExplicitState ? 'Todos: cleared' : '';
  }
  final total = state.items.length;
  final done = state.items.where((t) => t.isCompleted).length;
  final remaining = state.items.where((t) => !t.isCompleted).toList();
  final buffer = StringBuffer('Todos: $done/$total complete.');
  if (remaining.isEmpty) {
    buffer.write(' (all done!)');
  } else {
    buffer.write(' Remaining:');
    for (var i = 0; i < remaining.length && i < maxRemaining; i++) {
      buffer.write('\n- ${_sanitizeSingleLine(remaining[i].content)}');
    }
    if (remaining.length > maxRemaining) {
      buffer.write('\n- (+${remaining.length - maxRemaining} more)');
    }
  }
  var text = buffer.toString();
  if (text.length > maxChars) text = '${text.substring(0, maxChars)}…';
  return text;
}

/// First incomplete item of the snapshot — the compaction `Next Action`.
String? todoNextActionOf(TodoState? state) {
  if (state == null) return null;
  for (final t in state.items) {
    if (!t.isCompleted) return t.content;
  }
  return null;
}
