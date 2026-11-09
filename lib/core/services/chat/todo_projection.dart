// Todo projection (§2.1 of docs/write_todos_improvement_plan.md): the latest
// successful `write_todos` conversation event IS the current plan. Pure Dart
// over the active message branch — no store, no Flutter provider.
//
// Rules (§2.1.2):
// 1. Only the active (version-collapsed) branch is scanned, in order.
// 2. Only `write_todos` events count.
// 3. Only successful events advance state: the derived part status must be
//    `completed`; a `tool_error` result never changes the state.
//    - A full or `changed=true` `todo_snapshot` result carries the canonical
//      items (strict parse).
//    - A compact counts-only result or a human-readable legacy result is
//      rebuilt from the event arguments (lenient parse).
// 4. Later successful events override earlier ones; within one message the
//    last one wins.
// 5. `todos: []` with success ⇒ cleared state (`hasExplicitState: true`).
//
// Because the state lives in the events, backup/restore, delete, fork and
// version switching are all correct by construction (§2.5.1).
library;

import '../../models/chat_message.dart';
import 'storage/message_part_codec.dart';
import 'todo_models.dart';

/// Projects the current todo state from the active message branch.
///
/// [activeMessages] MUST be `messageBuilderService.collapseVersions(...)`
/// output so regenerate/version switches project the selected branch
/// (§2.1.2). [eventsByMessageId] maps each message id to its persisted tool
/// events (`chatService.getToolEvents`); generation preloads them with
/// `ensureToolEventsLoaded`.
///
/// Returns null when no successful `write_todos` event exists on the branch.
TodoState? projectTodoState({
  required List<ChatMessage> activeMessages,
  required Map<String, List<Map<String, dynamic>>> eventsByMessageId,
  void Function(String message)? onDebugLog,
}) {
  TodoState? state;
  for (final message in activeMessages) {
    final events = eventsByMessageId[message.id];
    if (events == null || events.isEmpty) continue;
    for (final event in events) {
      final name = (event['name'] ?? '').toString();
      if (name != todoToolName) continue;

      final rawContent = event['content'];
      final content = rawContent is String ? rawContent : null;
      final approvalState = normalizeApprovalState(event['approvalState']);
      final status = deriveLegacyToolPartStatus(
        approvalState: approvalState,
        content: content,
      );
      if (status != kPartStatusCompleted) continue;

      if (isTodoToolErrorContent(content)) {
        onDebugLog?.call(
          'todo projection: skipped failed write_todos event in ${message.id}',
        );
        continue;
      }

      // Resolve items: canonical snapshot first (§2.1.2 rule 3), then the
      // lenient argument parse for compact / legacy results. A corrupt
      // snapshot falls back to the arguments; if both fail the event is
      // ignored (it never advances state).
      List<TodoItem>? items;
      final snapshot = parseTodoSnapshotContent(content);
      if (snapshot != null && snapshot.hasItems) {
        items = snapshot.items;
      } else {
        final args = event['arguments'];
        final rawTodos = args is Map ? args['todos'] : null;
        // Read path: this rebuilds ALREADY-PERSISTED data, so a partially
        // invalid legacy list keeps its valid entries (the "reject the whole
        // input" rule §2.2.1 belongs to the write path only). Otherwise a
        // legacy card would show a plan the model never receives.
        final parsed = parseTodoListInput(rawTodos, dropInvalidItems: true);
        if (parsed.isValid) {
          items = parsed.items;
          if (snapshot != null && !snapshot.hasItems) {
            onDebugLog?.call(
              'todo projection: rebuilt compact write_todos result from '
              'arguments in ${message.id}',
            );
          }
        }
      }
      if (items == null) {
        onDebugLog?.call(
          'todo projection: ignored unparseable write_todos event in '
          '${message.id}',
        );
        continue;
      }

      final toolCallId = (event['id'] ?? '').toString().trim();
      state = TodoState(
        items: items,
        sourceMessageId: message.id,
        sourceToolCallId: toolCallId.isEmpty ? null : toolCallId,
        hasExplicitState: true,
        updatedAt: message.timestamp,
      );
    }
  }
  return state;
}
