import '../agent/approval.dart' as approval;
import '../logging/flutter_logger.dart';
import 'ask_user_models.dart';
import 'storage/message_part_codec.dart';
import 'todo_service.dart';

/// Log-only tools that must never be replayed as call/result pairs (§9.5.2).
///
/// * `write_todos` — its snapshot is injected at the system-prompt tail.
/// * `workspace_snapshot` — retired P1-5 affordance, still present in old
///   persisted history.
const Set<String> kNonReplayableToolNames = <String>{
  todoToolName,
  'workspace_snapshot',
};

/// One replayable tool call/result pair.
class ToolReplayPair {
  const ToolReplayPair({
    required this.event,
    required this.toolName,
    required this.toolCallId,
    required this.content,
  });

  /// The persisted legacy event map, for reasoning-echo extras.
  final Map<String, dynamic> event;

  final String toolName;
  final String toolCallId;

  /// Non-null tool result. For `denied` this is the denial protocol JSON that
  /// the model sees as the tool result.
  final String content;
}

/// Synthetic stable id for legacy events without an id. Mirrors the pre-M3
/// builder so existing histories keep the same call ids.
String syntheticToolCallId(String messageId, int index) {
  final prefix = messageId.substring(
    0,
    messageId.length < 8 ? messageId.length : 8,
  );
  return 'call_${prefix}_$index';
}

/// Infers a legacy approval state from the persisted protocol JSON when the
/// event has no `approvalState` (older history). Returns [kApprovalAuto] when
/// the content is not a protocol payload.
String _effectiveApprovalState(String? rawState, String? content) {
  final normalized = normalizeApprovalState(rawState);
  if (normalized != kApprovalAuto || content == null) return normalized;

  final parsed = approval.parseApprovalContent(content);
  if (parsed != null) {
    return parsed['type'] == approval.approvalRequiredType
        ? kApprovalPending
        : kApprovalDenied;
  }
  final ask = parseAskUserContent(content);
  if (ask != null && ask['type'] == askUserPendingType) {
    return kApprovalPending;
  }
  return normalized;
}

/// Filters a persisted event list down to the call/result pairs that may be
/// replayed to a model (§9.5.2).
///
/// * `pending` and `interrupted` are omitted as a pair: no call and no result.
/// * `denied` is replayed with its denial JSON (the one approval-protocol
///   shape that is model-facing). A null-content denial is omitted and logged.
/// * `completed` requires content; a null-content completed event is treated
///   as corruption and skipped rather than emitting a dangling call.
/// * Duplicate non-empty ids are dropped after the first pair so every call
///   has exactly one matching result.
///
/// Status is derived from `approvalState` plus content. When the state is
/// absent (legacy history), the persisted `approval_required` / `ask_user_pending`
/// protocol type is treated as pending and `approval_denied` as denied. This
/// is exactly what the SQLite importer stored in `message_parts.status`, so the
/// same helper serves both backends.
List<ToolReplayPair> buildToolReplayPairs(
  List<Map<String, dynamic>> events, {
  required String messageId,
}) {
  final pairs = <ToolReplayPair>[];
  final seenIds = <String>{};
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    final name = (event['name'] ?? '').toString().trim();
    if (name.isEmpty) continue;
    if (kNonReplayableToolNames.contains(name)) continue;

    final rawContent = event['content'];
    final content = rawContent is String ? rawContent : null;
    final approvalState = _effectiveApprovalState(
      event['approvalState']?.toString(),
      content,
    );
    final status = deriveLegacyToolPartStatus(
      approvalState: approvalState,
      content: content,
    );
    if (!isReplayablePartStatus(status)) continue;
    if (content == null) {
      if (status == kPartStatusDenied) {
        FlutterLogger.log(
          'Dropped denied tool part for $messageId ($name): null content.',
          tag: 'chat-replay',
        );
      }
      continue;
    }

    final rawId = (event['id'] ?? '').toString().trim();
    final id = rawId.isNotEmpty ? rawId : syntheticToolCallId(messageId, i);
    if (!seenIds.add(id)) {
      FlutterLogger.log(
        'Dropped duplicate tool call id $id for $messageId ($name).',
        tag: 'chat-replay',
      );
      continue;
    }
    pairs.add(
      ToolReplayPair(
        event: event,
        toolName: name,
        toolCallId: id,
        content: content,
      ),
    );
  }
  return pairs;
}
