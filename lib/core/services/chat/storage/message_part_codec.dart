import 'dart:convert';

/// Phase-1 `message_parts.kind` for tool calls/results.
const String kToolPartKind = 'tool';

/// `provider_artifacts.kind` for the Gemini thought signature of a message.
const String kGeminiThoughtSignatureKind = 'gemini_thought_signature';

/// Closed approval-state set (`message_parts.approval_state`). Unknown/null
/// values are normalized to [kApprovalAuto].
const String kApprovalAuto = 'auto';
const String kApprovalPending = 'pending';
const String kApprovalApproved = 'approved';
const String kApprovalDenied = 'denied';
const String kApprovalAnswered = 'answered';

/// Closed status set (`message_parts.status`).
const String kPartStatusPending = 'pending';
const String kPartStatusCompleted = 'completed';
const String kPartStatusInterrupted = 'interrupted';
const String kPartStatusDenied = 'denied';

const Set<String> kPartStatuses = <String>{
  kPartStatusPending,
  kPartStatusCompleted,
  kPartStatusInterrupted,
  kPartStatusDenied,
};

const Set<String> kApprovalStates = <String>{
  kApprovalAuto,
  kApprovalPending,
  kApprovalApproved,
  kApprovalDenied,
  kApprovalAnswered,
};

/// Event keys that have a dedicated `message_parts` column and must never be
/// duplicated into `metadata_json`.
const Set<String> kToolEventColumnKeys = <String>{
  'id',
  'name',
  'arguments',
  'content',
  'approvalState',
};

/// UI-only / replay-only event extras carried by the existing writers. They
/// live in `metadata_json` (there is no dedicated column) and survive result
/// upserts, mirroring `ChatService.preservedToolEventExtraKeys`.
const List<String> kPreservedToolEventExtraKeys = <String>[
  'searchProvider',
  'searchFallbackFrom',
  'webFetchSource',
  'reasoning_content',
  'reasoning_details',
];

/// Normalizes a legacy approval state to the closed set. `null` and unknown
/// strings become [kApprovalAuto]; there is no `rejected` state.
String normalizeApprovalState(Object? raw) {
  if (raw == null) return kApprovalAuto;
  final value = raw.toString().trim();
  return kApprovalStates.contains(value) ? value : kApprovalAuto;
}

/// Status derivation used by the one-time Hive import (§6.1/§7.4): the
/// approval lifecycle wins over content presence, and an approved/answered
/// event without a result is an interruption, not a pending placeholder.
String deriveLegacyToolPartStatus({
  required String approvalState,
  required String? content,
}) {
  switch (approvalState) {
    case kApprovalPending:
      return kPartStatusPending;
    case kApprovalDenied:
      return kPartStatusDenied;
    case kApprovalApproved:
    case kApprovalAnswered:
      return content == null ? kPartStatusInterrupted : kPartStatusCompleted;
    default:
      return content == null ? kPartStatusInterrupted : kPartStatusCompleted;
  }
}

/// Status derivation used by runtime upserts (§9.4). A fresh, no-result
/// placeholder is `pending`; completion requires content.
String deriveRuntimeToolPartStatus({
  required String approvalState,
  required String? content,
}) {
  switch (approvalState) {
    case kApprovalPending:
      return kPartStatusPending;
    case kApprovalDenied:
      return kPartStatusDenied;
    case kApprovalApproved:
    case kApprovalAnswered:
    case kApprovalAuto:
      return content == null ? kPartStatusPending : kPartStatusCompleted;
    default:
      return content == null ? kPartStatusPending : kPartStatusCompleted;
  }
}

/// Whether a part may be replayed to a model as a tool call/result pair
/// (§9.5.2). `pending` and `interrupted` are omitted as a pair.
bool isReplayablePartStatus(String status) =>
    status == kPartStatusCompleted || status == kPartStatusDenied;

/// A decoded legacy tool event, ready to be inserted as `message_parts`.
class ToolPartDraft {
  const ToolPartDraft({
    required this.toolCallId,
    required this.toolName,
    required this.argumentsJson,
    required this.content,
    required this.approvalState,
    required this.status,
    required this.metadataJson,
  });

  final String? toolCallId;
  final String? toolName;
  final String argumentsJson;
  final String? content;
  final String approvalState;
  final String status;

  /// `null` when the event carried no unmapped keys.
  final String? metadataJson;
}

/// Maps one persisted Hive tool-event map to a `message_parts` row.
///
/// Every key without a dedicated column is preserved in `metadata_json`; the
/// raw payload is never dropped. `arguments` that is not a JSON object is kept
/// under `metadata.legacyArguments` and the column stores `{}` so the column
/// contract (a JSON object string) holds. Non-string content is serialized and
/// flagged (`legacyContentSerialized`) for the defensive legacy path.
ToolPartDraft toolPartDraftFromLegacyEvent(Map<dynamic, dynamic> rawEvent) {
  final event = <String, dynamic>{};
  rawEvent.forEach((key, value) => event[key.toString()] = value);

  final idRaw = event['id'];
  final cleanId = idRaw?.toString().trim() ?? '';
  final nameRaw = event['name'];
  final name = nameRaw?.toString();

  final metadata = <String, dynamic>{};
  final legacyKeys = <String>[];

  final argsRaw = event['arguments'];
  String argumentsJson;
  if (argsRaw is Map) {
    argumentsJson = canonicalJsonEncode(argsRaw);
  } else if (argsRaw == null) {
    argumentsJson = '{}';
  } else {
    argumentsJson = '{}';
    metadata['legacyArguments'] = argsRaw;
    legacyKeys.add('arguments');
  }

  final contentRaw = event['content'];
  String? content;
  if (contentRaw == null) {
    content = null;
  } else if (contentRaw is String) {
    content = contentRaw;
  } else {
    content = _encodeUnknown(contentRaw);
    metadata['legacyContentSerialized'] = true;
  }

  final approvalState = normalizeApprovalState(event['approvalState']);

  for (final entry in event.entries) {
    if (kToolEventColumnKeys.contains(entry.key)) continue;
    metadata[entry.key] = entry.value;
  }
  if (legacyKeys.isNotEmpty) {
    legacyKeys.sort();
    metadata['legacyKeys'] = legacyKeys;
  }

  return ToolPartDraft(
    toolCallId: cleanId.isEmpty ? null : cleanId,
    toolName: name,
    argumentsJson: argumentsJson,
    content: content,
    approvalState: approvalState,
    status: deriveLegacyToolPartStatus(
      approvalState: approvalState,
      content: content,
    ),
    metadataJson: metadata.isEmpty ? null : canonicalJsonEncode(metadata),
  );
}

/// Rebuilds the legacy event map shape from a stored part. The repository and
/// the future facade use this so existing replay/model code keeps its input
/// contract.
Map<String, dynamic> toolEventFromStoredPart({
  required String? toolCallId,
  required String? toolName,
  required String? argumentsJson,
  required String? content,
  required String approvalState,
  required String? metadataJson,
}) {
  final metadata = decodeJsonMap(metadataJson);
  final legacyKeysRaw = metadata.remove('legacyKeys');
  final legacyKeys = legacyKeysRaw is List
      ? legacyKeysRaw.map((e) => e.toString()).toSet()
      : const <String>{};
  metadata.remove('legacyContentSerialized');

  Map<String, dynamic> arguments = const <String, dynamic>{};
  if (legacyKeys.contains('arguments') &&
      metadata.containsKey('legacyArguments')) {
    final raw = metadata.remove('legacyArguments');
    if (raw is Map) {
      arguments = raw.map((k, v) => MapEntry(k.toString(), v));
    }
  } else {
    final decoded = decodeJsonValue(argumentsJson);
    if (decoded is Map) {
      arguments = decoded.map((k, v) => MapEntry(k.toString(), v));
    }
  }

  return <String, dynamic>{
    ...metadata,
    'id': toolCallId ?? '',
    'name': toolName ?? '',
    'arguments': arguments,
    'content': content,
    'approvalState': approvalState,
  };
}

/// Compact part view for the timeline/process group. Never carries a
/// completed tool body; pending/denied approval protocol JSON is included
/// eagerly because the approval card cannot render from a length alone.
/// Tools whose timeline card cannot render from a length/preview alone:
/// the answered `ask_user` card needs the answer JSON and the question
/// arguments, and the todo card needs the full todo list.
const Set<String> kEagerSummaryToolNames = <String>{'ask_user', 'write_todos'};

class ToolPartSummary {
  const ToolPartSummary({
    required this.partId,
    required this.messageId,
    required this.ordinal,
    required this.toolCallId,
    required this.toolName,
    required this.approvalState,
    required this.status,
    required this.contentLengthChars,
    required this.argumentsLengthChars,
    required this.argumentsPreview,
    required this.updatedAt,
    required this.eagerContent,
    required this.eagerArgumentsJson,
    this.searchProvider,
    this.searchFallbackFrom,
    this.webFetchSource,
  });

  final int partId;
  final String messageId;
  final int ordinal;
  final String? toolCallId;
  final String? toolName;
  final String approvalState;
  final String status;
  final int contentLengthChars;
  final int argumentsLengthChars;

  /// First 256 chars of the serialized arguments. May be truncated JSON; the
  /// UI only parses it when it is complete and loads the full arguments on
  /// expand.
  final String? argumentsPreview;
  final DateTime updatedAt;

  /// Approval-protocol JSON for `pending`/`denied` parts and the answer JSON
  /// for `ask_user`; otherwise `null`.
  final String? eagerContent;

  /// Full arguments for cards that cannot render from a preview
  /// ([kEagerSummaryToolNames]) and for pending/denied approvals.
  final String? eagerArgumentsJson;

  /// UI-only search trace, extracted from `metadata_json` without loading the
  /// whole metadata payload.
  final String? searchProvider;
  final String? searchFallbackFrom;
  final String? webFetchSource;

  bool get contentLoaded => eagerContent != null;
  bool get hasContent => contentLengthChars > 0;

  bool get isPending => status == kPartStatusPending;
  bool get isCompleted => status == kPartStatusCompleted;
  bool get isInterrupted => status == kPartStatusInterrupted;
  bool get isDenied => status == kPartStatusDenied;
}

/// Builds a timeline summary from a legacy-shaped event (Hive backend).
/// Mirrors the SQLite summary query: eager content only for pending/denied and
/// `ask_user`, eager arguments for pending/denied and [kEagerSummaryToolNames].
ToolPartSummary toolPartSummaryFromEvent({
  required Map<String, dynamic> event,
  required String messageId,
  required int ordinal,
}) {
  final name = event['name']?.toString();
  Map<String, dynamic> arguments = const <String, dynamic>{};
  final rawArguments = event['arguments'];
  if (rawArguments is Map) {
    arguments = rawArguments.map((k, v) => MapEntry(k.toString(), v));
  }
  var argumentsJson = '{}';
  try {
    argumentsJson = jsonEncode(arguments);
  } catch (_) {}

  final rawContent = event['content'];
  final content = rawContent is String ? rawContent : null;
  final approvalState = normalizeApprovalState(event['approvalState']);
  final status = deriveLegacyToolPartStatus(
    approvalState: approvalState,
    content: content,
  );
  final eagerContent =
      (status == kPartStatusPending ||
          status == kPartStatusDenied ||
          (name != null && kEagerSummaryToolNames.contains(name)))
      ? content
      : null;
  final eagerArguments =
      (status == kPartStatusPending ||
          status == kPartStatusDenied ||
          (name != null && kEagerSummaryToolNames.contains(name)))
      ? argumentsJson
      : null;
  final rawId = (event['id'] ?? '').toString().trim();

  return ToolPartSummary(
    partId: ordinal,
    messageId: messageId,
    ordinal: ordinal,
    toolCallId: rawId.isEmpty ? null : rawId,
    toolName: name,
    approvalState: approvalState,
    status: status,
    contentLengthChars: content?.length ?? 0,
    argumentsLengthChars: argumentsJson.length,
    argumentsPreview: argumentsJson.length <= 256
        ? argumentsJson
        : argumentsJson.substring(0, 256),
    updatedAt: DateTime.now(),
    eagerContent: eagerContent,
    eagerArgumentsJson: eagerArguments,
    searchProvider: event['searchProvider']?.toString(),
    searchFallbackFrom: event['searchFallbackFrom']?.toString(),
    webFetchSource: event['webFetchSource']?.toString(),
  );
}

/// Canonical JSON: object keys sorted recursively, so source/destination
/// hashes are stable regardless of map insertion order.
String canonicalJsonEncode(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(buffer, value);
  return buffer.toString();
}

void _writeCanonical(StringBuffer buffer, Object? value) {
  if (value == null) {
    buffer.write('null');
    return;
  }
  if (value is String) {
    buffer.write(jsonEncode(value));
    return;
  }
  if (value is bool) {
    buffer.write(value ? 'true' : 'false');
    return;
  }
  if (value is num) {
    if (value is double && (value.isNaN || value.isInfinite)) {
      buffer.write('null');
    } else {
      buffer.write(value.toString());
    }
    return;
  }
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    buffer.write('{');
    var first = true;
    for (final key in keys) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write(jsonEncode(key));
      buffer.write(':');
      _writeCanonical(buffer, value[key]);
    }
    buffer.write('}');
    return;
  }
  if (value is Iterable) {
    buffer.write('[');
    var first = true;
    for (final item in value) {
      if (!first) buffer.write(',');
      first = false;
      _writeCanonical(buffer, item);
    }
    buffer.write(']');
    return;
  }
  buffer.write(jsonEncode(value.toString()));
}

String _encodeUnknown(Object? value) {
  try {
    return canonicalJsonEncode(value);
  } catch (_) {
    return jsonEncode(value.toString());
  }
}

Map<String, dynamic> decodeJsonMap(String? raw) {
  final decoded = decodeJsonValue(raw);
  if (decoded is! Map) return <String, dynamic>{};
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

Object? decodeJsonValue(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// UTF-8 byte length of [value], or 0 for null. Used by migration validation
/// so Dart string lengths never get compared with SQLite `length(TEXT)`.
int utf8Length(String? value) => value == null ? 0 : utf8.encode(value).length;
