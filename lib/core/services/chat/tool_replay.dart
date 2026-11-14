import '../agent/approval.dart' as approval;
import '../agent/subagent.dart';
import '../logging/flutter_logger.dart';
import 'ask_user_models.dart';
import 'storage/message_part_codec.dart';
import 'todo_models.dart';

/// Log-only tools that must never be replayed as call/result pairs (§9.5.2).
///
/// * `write_todos` — the latest successful snapshot is re-injected each turn
///   as a synthetic trailing tool pair (conversation tail, §2.3.2 of
///   docs/write_todos_improvement_plan.md); replaying every historical
///   snapshot would balloon the request for no gain.
/// * `workspace_snapshot` — retired P1-5 affordance, still present in old
///   persisted history.
/// * `builtin_search` — UI/citation card for a provider-hosted search. The
///   server already owns that call; replaying it as a client tool produces a
///   dangling `tool_use`/`functionCall` with no matching result.
/// * `delegate_subagent` — user-initiated `@profile` delegation is a UI-only
///   event; the final answer is already the assistant message content, so
///   replaying the event would fabricate a model tool call and duplicate it.
const Set<String> kNonReplayableToolNames = <String>{
  todoToolName,
  'workspace_snapshot',
  'builtin_search',
  delegateSubagentToolName,
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
    final eventId = (event['id'] ?? '').toString().trim();
    // Hosted-search display cards can persist as id `builtin_search` while
    // their display name is `search_web`; match either field.
    if (kNonReplayableToolNames.contains(name) ||
        kNonReplayableToolNames.contains(eventId)) {
      continue;
    }

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
        // P1-5: a helper summary can be 24k chars and would otherwise be
        // replayed in full on every turn. Keep the contract fields + a 2k
        // summary; `session_id` survives so a follow-up can still resume.
        content: name == spawnSubagentToolName
            ? compactSubagentReplay(content)
            : content,
      ),
    );
  }
  return pairs;
}
