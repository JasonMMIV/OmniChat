import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import '../../../models/file_record.dart';
import '../../../models/workspace_config.dart';
import 'app_database.dart';
import 'message_part_codec.dart';

/// Thrown when a mature database contains a part that violates the replay
/// contract (for example a `completed` row with null content). Never repaired
/// silently.
class ChatStorageCorruptionException implements Exception {
  const ChatStorageCorruptionException(this.message);

  final String message;

  @override
  String toString() => 'ChatStorageCorruptionException: $message';
}

/// Typed repository over `chat_v2.sqlite`. Every multi-row mutation runs in a
/// transaction; children cascade from `conversations`.
class ChatRepository {
  ChatRepository(this.db);

  final AppDatabase db;

  // ---------------------------------------------------------------------------
  // Conversations
  // ---------------------------------------------------------------------------

  Future<List<Conversation>> listConversations() async {
    final rows = await (db.select(
      db.conversationRows,
    )..orderBy([(t) => OrderingTerm.desc(t.updatedAtMs)])).get();
    final idsByConversation = await _messageIdsByConversation();
    return [
      for (final row in rows)
        _conversationFromRow(
          row,
          idsByConversation[row.id] ?? const <String>[],
        ),
    ];
  }

  Future<Conversation?> getConversation(String id) async {
    final row = await (db.select(
      db.conversationRows,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final ids = await messageIdsFor(id);
    return _conversationFromRow(row, ids);
  }

  Future<List<String>> messageIdsFor(String conversationId) async {
    final query = db.selectOnly(db.messageRows)
      ..addColumns([db.messageRows.id])
      ..where(db.messageRows.conversationId.equals(conversationId))
      ..orderBy([OrderingTerm.asc(db.messageRows.ordinal)]);
    final rows = await query.get();
    return [
      for (final row in rows)
        if (row.read(db.messageRows.id) != null) row.read(db.messageRows.id)!,
    ];
  }

  Future<Map<String, List<String>>> _messageIdsByConversation() async {
    final query = db.selectOnly(db.messageRows)
      ..addColumns([
        db.messageRows.id,
        db.messageRows.conversationId,
        db.messageRows.ordinal,
      ])
      ..orderBy([
        OrderingTerm.asc(db.messageRows.conversationId),
        OrderingTerm.asc(db.messageRows.ordinal),
      ]);
    final rows = await query.get();
    final result = <String, List<String>>{};
    for (final row in rows) {
      final conversationId = row.read(db.messageRows.conversationId);
      final id = row.read(db.messageRows.id);
      if (conversationId == null || id == null) continue;
      (result[conversationId] ??= <String>[]).add(id);
    }
    return result;
  }

  /// Inserts or updates a conversation. [isRecovered] is only written when
  /// explicitly supplied, so a generic save of a recovered conversation does
  /// not clear the recovery flag (deferred review R4).
  Future<void> upsertConversation(
    Conversation conversation, {
    bool? isRecovered,
  }) async {
    final row = _conversationRow(conversation, isRecovered ?? false);
    final companion = ConversationRowsCompanion(
      id: Value(row.id),
      title: Value(row.title),
      createdAtMs: Value(row.createdAtMs),
      updatedAtMs: Value(row.updatedAtMs),
      assistantId: Value(row.assistantId),
      isPinned: Value(row.isPinned),
      truncateIndex: Value(row.truncateIndex),
      compactBeforeIndex: Value(row.compactBeforeIndex),
      summary: Value(row.summary),
      lastSummarizedMessageCount: Value(row.lastSummarizedMessageCount),
      mcpServerIdsJson: Value(row.mcpServerIdsJson),
      versionSelectionsJson: Value(row.versionSelectionsJson),
      isRecovered: isRecovered == null
          ? const Value.absent()
          : Value(isRecovered),
    );
    await db.into(db.conversationRows).insertOnConflictUpdate(companion);
  }

  Future<void> renameConversation(String id, String title) async {
    await (db.update(db.conversationRows)..where((t) => t.id.equals(id))).write(
      ConversationRowsCompanion(
        title: Value(title),
        updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> setConversationPinned(String id, bool pinned) async {
    await (db.update(db.conversationRows)..where((t) => t.id.equals(id))).write(
      ConversationRowsCompanion(isPinned: Value(pinned)),
    );
  }

  Future<void> setConversationAssistant(String id, String? assistantId) async {
    await (db.update(db.conversationRows)..where((t) => t.id.equals(id))).write(
      ConversationRowsCompanion(
        assistantId: Value(assistantId),
        updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> setConversationMcpServers(
    String id,
    List<String> serverIds,
  ) async {
    await (db.update(db.conversationRows)..where((t) => t.id.equals(id))).write(
      ConversationRowsCompanion(
        mcpServerIdsJson: Value(jsonEncode(serverIds)),
        updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> setConversationSummary(
    String id,
    String? summary,
    int lastSummarizedMessageCount,
  ) async {
    await (db.update(db.conversationRows)..where((t) => t.id.equals(id))).write(
      ConversationRowsCompanion(
        summary: Value(summary),
        lastSummarizedMessageCount: Value(lastSummarizedMessageCount),
      ),
    );
  }

  Future<void> setConversationIndexes(
    String id, {
    required int truncateIndex,
    required int compactBeforeIndex,
  }) async {
    await (db.update(db.conversationRows)..where((t) => t.id.equals(id))).write(
      ConversationRowsCompanion(
        truncateIndex: Value(truncateIndex),
        compactBeforeIndex: Value(compactBeforeIndex),
        updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> setVersionSelections(
    String conversationId,
    Map<String, int> selections,
  ) async {
    await (db.update(
      db.conversationRows,
    )..where((t) => t.id.equals(conversationId))).write(
      ConversationRowsCompanion(
        versionSelectionsJson: Value(jsonEncode(selections)),
        updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<int> deleteConversation(String id) async {
    return (db.delete(db.conversationRows)..where((t) => t.id.equals(id))).go();
  }

  Future<int> deleteConversations(Iterable<String> ids) async {
    final unique = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return 0;
    return db.transaction(() async {
      var deleted = 0;
      for (final id in unique) {
        deleted += await deleteConversation(id);
      }
      return deleted;
    });
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<List<ChatMessage>> getMessages(String conversationId) async {
    final rows =
        await (db.select(db.messageRows)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
            .get();
    return rows.map(_messageFromRow).toList();
  }

  Future<ChatMessage?> getMessage(String id) async {
    final row = await (db.select(
      db.messageRows,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _messageFromRow(row);
  }

  /// Every message in the database ordered by conversation and ordinal. The
  /// storage facade uses this once at startup to preserve the synchronous
  /// `getMessages` API while never loading tool bodies eagerly.
  /// Contents that can reference upload files. The SQL filter avoids loading
  /// ordinary message bodies just to run orphan-upload cleanup.
  Future<List<String>> attachmentBearingMessageContents() async {
    final rows = await db
        .customSelect(
          "SELECT content FROM messages WHERE content LIKE ? "
          "OR content LIKE ?",
          variables: <Variable<Object>>[
            const Variable<String>('%[image:%'),
            const Variable<String>('%[file:%'),
          ],
        )
        .get();
    return [for (final row in rows) row.read<String>('content')];
  }

  Future<List<ChatMessage>> allMessages() async {
    final rows =
        await (db.select(db.messageRows)..orderBy([
              (t) => OrderingTerm.asc(t.conversationId),
              (t) => OrderingTerm.asc(t.ordinal),
            ]))
            .get();
    return rows.map(_messageFromRow).toList();
  }

  /// Restores a conversation and its messages in one transaction. Messages
  /// whose conversation id differs are attached to the restored conversation
  /// (a backup can carry a stale id), and rows no longer present are removed.
  Future<void> restoreConversation(
    Conversation conversation,
    List<ChatMessage> messages,
  ) async {
    await db.transaction(() async {
      await upsertConversation(conversation);
      final keep = messages.map((m) => m.id).toSet();
      final existing = await (db.select(
        db.messageRows,
      )..where((t) => t.conversationId.equals(conversation.id))).get();
      for (final row in existing) {
        if (keep.contains(row.id)) continue;
        await (db.delete(
          db.messageRows,
        )..where((t) => t.id.equals(row.id))).go();
      }
      for (var i = 0; i < messages.length; i++) {
        final message = messages[i].conversationId == conversation.id
            ? messages[i]
            : messages[i].copyWith(conversationId: conversation.id);
        await _insertMessage(message, i);
      }
    });
  }

  Future<int> messageCount(String conversationId) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM messages WHERE conversation_id = ?',
          variables: [Variable.withString(conversationId)],
        )
        .getSingle();
    return row.read<int>('c');
  }

  /// Appends a message at `max(ordinal)+1` and touches the conversation in one
  /// transaction.
  Future<ChatMessage> appendMessage(
    ChatMessage message, {
    bool touchConversation = true,
  }) async {
    return db.transaction(() async {
      final next = await _nextOrdinal(message.conversationId);
      await _insertMessage(message, next);
      if (touchConversation) {
        await _touchConversation(message.conversationId);
      }
      return message;
    });
  }

  /// Import path: explicit ordinal and no `updated_at` bump.
  Future<void> insertMessageAt(ChatMessage message, int ordinal) async {
    await _insertMessage(message, ordinal);
  }

  Future<void> updateMessage(
    String messageId, {
    String? content,
    int? totalTokens,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    DateTime? processFinishedAt,
    DateTime? processStartedAt,
    String? translation,
    String? reasoningSegmentsJson,
    String? aiTeamProposalsJson,
  }) async {
    final companion = MessageRowsCompanion(
      content: content == null ? const Value.absent() : Value(content),
      totalTokens: totalTokens == null
          ? const Value.absent()
          : Value(totalTokens),
      promptTokens: promptTokens == null
          ? const Value.absent()
          : Value(promptTokens),
      completionTokens: completionTokens == null
          ? const Value.absent()
          : Value(completionTokens),
      cachedTokens: cachedTokens == null
          ? const Value.absent()
          : Value(cachedTokens),
      isStreaming: isStreaming == null
          ? const Value.absent()
          : Value(isStreaming),
      reasoningText: reasoningText == null
          ? const Value.absent()
          : Value(reasoningText),
      reasoningStartAtMs: reasoningStartAt == null
          ? const Value.absent()
          : Value(reasoningStartAt.millisecondsSinceEpoch),
      reasoningFinishedAtMs: reasoningFinishedAt == null
          ? const Value.absent()
          : Value(reasoningFinishedAt.millisecondsSinceEpoch),
      processFinishedAtMs: processFinishedAt == null
          ? const Value.absent()
          : Value(processFinishedAt.millisecondsSinceEpoch),
      processStartedAtMs: processStartedAt == null
          ? const Value.absent()
          : Value(processStartedAt.millisecondsSinceEpoch),
      translation: translation == null
          ? const Value.absent()
          : Value(translation),
      reasoningSegmentsJson: reasoningSegmentsJson == null
          ? const Value.absent()
          : Value(reasoningSegmentsJson),
      aiTeamProposalsJson: aiTeamProposalsJson == null
          ? const Value.absent()
          : Value(aiTeamProposalsJson),
    );
    await (db.update(
      db.messageRows,
    )..where((t) => t.id.equals(messageId))).write(companion);
  }

  /// Deletes one version of a message group, moves a remaining version into the
  /// removed slot, renumbers contiguously, and clamps both conversation
  /// indices in one transaction.
  Future<bool> deleteMessage(String messageId) async {
    return db.transaction(() async {
      final row = await (db.select(
        db.messageRows,
      )..where((t) => t.id.equals(messageId))).getSingleOrNull();
      if (row == null) return false;

      final conversationId = row.conversationId;
      final ids = await messageIdsFor(conversationId);
      final removedIndex = ids.indexOf(messageId);
      final groupId = row.groupId ?? row.id;

      await (db.delete(
        db.messageRows,
      )..where((t) => t.id.equals(messageId))).go();

      var finalIds = List<String>.of(ids)..remove(messageId);
      // Only promote a remaining version that sits at or after the removed
      // slot. An earlier version must never jump across an intervening reply
      // in a non-contiguous group (deferred review R1).
      if (removedIndex >= 0 && removedIndex < finalIds.length) {
        for (var i = removedIndex; i < finalIds.length; i++) {
          final candidate = finalIds[i];
          final candidateRow = await (db.select(
            db.messageRows,
          )..where((t) => t.id.equals(candidate))).getSingleOrNull();
          if (candidateRow == null) continue;
          if ((candidateRow.groupId ?? candidateRow.id) != groupId) continue;
          finalIds.removeAt(i);
          finalIds.insert(removedIndex, candidate);
          break;
        }
      }

      await _renumberMessages(conversationId, finalIds);

      final conversation = await (db.select(
        db.conversationRows,
      )..where((t) => t.id.equals(conversationId))).getSingleOrNull();
      if (conversation != null) {
        final count = finalIds.length;
        final newTruncate = _clampIndex(
          conversation.truncateIndex,
          removedIndex,
          count,
        );
        final newCompact = _clampIndex(
          conversation.compactBeforeIndex,
          removedIndex,
          count,
        );
        // A selection pointing at the deleted version must not survive it
        // (deferred review R2): choose the nearest lower remaining version,
        // then the nearest higher, then clear the group entry.
        final selections = decodeIntMap(conversation.versionSelectionsJson);
        if (selections.containsKey(groupId)) {
          final remaining =
              await (db.select(db.messageRows)..where(
                    (t) =>
                        t.conversationId.equals(conversationId) &
                        (t.groupId.equals(groupId) |
                            (t.groupId.isNull() & t.id.equals(groupId))),
                  ))
                  .get();
          if (remaining.isEmpty) {
            selections.remove(groupId);
          } else if (selections[groupId] == row.version) {
            final lower =
                remaining
                    .where((candidate) => candidate.version < row.version)
                    .toList()
                  ..sort((a, b) => b.version.compareTo(a.version));
            final higher =
                remaining
                    .where((candidate) => candidate.version > row.version)
                    .toList()
                  ..sort((a, b) => a.version.compareTo(b.version));
            selections[groupId] =
                (lower.isNotEmpty ? lower.first : higher.first).version;
          }
        }
        await (db.update(
          db.conversationRows,
        )..where((t) => t.id.equals(conversationId))).write(
          ConversationRowsCompanion(
            truncateIndex: Value(newTruncate),
            compactBeforeIndex: Value(newCompact),
            versionSelectionsJson: Value(jsonEncode(selections)),
          ),
        );
      }
      return true;
    });
  }

  Future<void> appendMessageVersion({
    required String groupId,
    required ChatMessage message,
  }) async {
    await db.transaction(() async {
      final next = await _nextOrdinal(message.conversationId);
      // The caller's group id is authoritative; a message carrying a null or
      // different group id must not land outside the requested group (R3).
      final normalized = message.groupId == groupId
          ? message
          : message.copyWith(groupId: groupId);
      await _insertMessage(normalized, next);
      final conversation = await (db.select(
        db.conversationRows,
      )..where((t) => t.id.equals(message.conversationId))).getSingleOrNull();
      if (conversation != null) {
        final selections = decodeIntMap(conversation.versionSelectionsJson);
        selections[groupId] = normalized.version;
        await (db.update(
          db.conversationRows,
        )..where((t) => t.id.equals(message.conversationId))).write(
          ConversationRowsCompanion(
            versionSelectionsJson: Value(jsonEncode(selections)),
            updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Tool parts (message_parts)
  // ---------------------------------------------------------------------------

  /// Mirrors `ChatService.upsertToolEvent` on top of independently addressable
  /// rows: id match first, then the first `pending` same-name placeholder.
  /// Interrupted/denied rows are never reused by the no-id fallback.
  Future<MessagePartRow> upsertToolEvent({
    required String assistantMessageId,
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    String? approvalState,
    Map<String, dynamic>? extras,
  }) async {
    return db.transaction(() async {
      final cleanId = id.trim();
      MessagePartRow? existing;

      if (cleanId.isNotEmpty) {
        existing =
            await (db.select(db.messageParts)
                  ..where(
                    (t) =>
                        t.messageId.equals(assistantMessageId) &
                        t.toolCallId.equals(cleanId),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.ordinal)])
                  ..limit(1))
                .getSingleOrNull();
      }
      existing ??=
          await (db.select(db.messageParts)
                ..where(
                  (t) =>
                      t.messageId.equals(assistantMessageId) &
                      t.toolName.equals(name) &
                      t.status.equals(kPartStatusPending) &
                      (t.content.isNull() | t.content.equals('')),
                )
                ..orderBy([(t) => OrderingTerm.asc(t.ordinal)])
                ..limit(1))
              .getSingleOrNull();

      final now = DateTime.now().millisecondsSinceEpoch;
      final resolvedApproval = normalizeApprovalState(
        approvalState ?? existing?.approvalState,
      );
      final existingMetadata = decodeJsonMap(existing?.metadataJson)
        ..remove('legacyKeys')
        ..remove('legacyArguments')
        ..remove('legacyContentSerialized');

      final mergedMetadata = <String, dynamic>{...existingMetadata};
      if (extras != null) {
        for (final key in kPreservedToolEventExtraKeys) {
          final value = extras[key];
          if (value == null) continue;
          mergedMetadata[key] = value;
        }
      }
      for (final key in kToolEventColumnKeys) {
        mergedMetadata.remove(key);
      }

      // Preserve the no-id placeholder's id when the incoming upsert has none,
      // so a later id-aware result lands on the same row.
      final resolvedId = cleanId.isNotEmpty
          ? cleanId
          : (existing?.toolCallId ?? '');
      final status = deriveRuntimeToolPartStatus(
        approvalState: resolvedApproval,
        content: content,
      );

      if (existing != null) {
        await (db.update(
          db.messageParts,
        )..where((t) => t.partId.equals(existing!.partId))).write(
          MessagePartsCompanion(
            toolCallId: Value(resolvedId.isEmpty ? null : resolvedId),
            toolName: Value(name),
            argumentsJson: Value(canonicalJsonEncode(arguments)),
            content: Value(content),
            status: Value(status),
            approvalState: Value(resolvedApproval),
            metadataJson: Value(
              mergedMetadata.isEmpty
                  ? null
                  : canonicalJsonEncode(mergedMetadata),
            ),
            updatedAtMs: Value(now),
          ),
        );
        return (await (db.select(
          db.messageParts,
        )..where((t) => t.partId.equals(existing!.partId))).getSingle());
      }

      final nextOrdinal = await _nextPartOrdinal(assistantMessageId);
      final partId = await db
          .into(db.messageParts)
          .insert(
            MessagePartsCompanion.insert(
              messageId: assistantMessageId,
              ordinal: nextOrdinal,
              kind: kToolPartKind,
              toolCallId: Value(resolvedId.isEmpty ? null : resolvedId),
              toolName: Value(name),
              argumentsJson: Value(canonicalJsonEncode(arguments)),
              content: Value(content),
              status: Value(status),
              approvalState: Value(resolvedApproval),
              metadataJson: Value(
                mergedMetadata.isEmpty
                    ? null
                    : canonicalJsonEncode(mergedMetadata),
              ),
              createdAtMs: now,
              updatedAtMs: now,
            ),
          );
      return (await (db.select(
        db.messageParts,
      )..where((t) => t.partId.equals(partId))).getSingle());
    });
  }

  Future<bool> setToolEventApprovalState({
    required String assistantMessageId,
    required String id,
    required String approvalState,
    String? content,
  }) async {
    return db.transaction(() async {
      MessagePartRow? row;
      final cleanId = id.trim();
      if (cleanId.isEmpty) {
        // Legacy no-id events are stored with a NULL tool_call_id. Prefer the
        // newest pending row, then the newest no-id row of any status.
        row =
            await (db.select(db.messageParts)
                  ..where(
                    (t) =>
                        t.messageId.equals(assistantMessageId) &
                        (t.toolCallId.isNull() | t.toolCallId.equals('')) &
                        t.status.equals(kPartStatusPending),
                  )
                  ..orderBy([(t) => OrderingTerm.desc(t.ordinal)])
                  ..limit(1))
                .getSingleOrNull();
        row ??=
            await (db.select(db.messageParts)
                  ..where(
                    (t) =>
                        t.messageId.equals(assistantMessageId) &
                        (t.toolCallId.isNull() | t.toolCallId.equals('')),
                  )
                  ..orderBy([(t) => OrderingTerm.desc(t.ordinal)])
                  ..limit(1))
                .getSingleOrNull();
      } else {
        row =
            await (db.select(db.messageParts)
                  ..where(
                    (t) =>
                        t.messageId.equals(assistantMessageId) &
                        t.toolCallId.equals(cleanId),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.ordinal)])
                  ..limit(1))
                .getSingleOrNull();
      }
      if (row == null) return false;
      final current = row;

      final normalized = normalizeApprovalState(approvalState);
      final newContent = content ?? current.content;
      final status = deriveRuntimeToolPartStatus(
        approvalState: normalized,
        content: newContent,
      );
      await (db.update(
        db.messageParts,
      )..where((t) => t.partId.equals(current.partId))).write(
        MessagePartsCompanion(
          approvalState: Value(normalized),
          content: Value(newContent),
          status: Value(status),
          updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return true;
    });
  }

  /// Replaces the whole part list for a message (`setToolEvents`). Runtime
  /// callers use this for import/restore paths where the source list is
  /// authoritative; rows are inserted at their list index.
  Future<void> replaceToolEvents(
    String messageId,
    List<ToolPartDraft> drafts,
  ) async {
    await db.transaction(() async {
      final existing =
          await (db.select(db.messageParts)
                ..where((t) => t.messageId.equals(messageId))
                ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
              .get();

      // Match each draft to an existing row so repeated streaming writes keep
      // the row (and part_id) stable instead of delete-then-insert. Prefer a
      // non-empty tool_call_id, then the same-name no-id placeholder.
      final used = <int>{};
      final matches = List<MessagePartRow?>.filled(drafts.length, null);
      for (var i = 0; i < drafts.length; i++) {
        final draft = drafts[i];
        MessagePartRow? match;
        final id = draft.toolCallId;
        if (id != null && id.isNotEmpty) {
          for (final row in existing) {
            if (used.contains(row.partId)) continue;
            if (row.toolCallId == id) {
              match = row;
              break;
            }
          }
        }
        if (match == null) {
          for (final row in existing) {
            if (used.contains(row.partId)) continue;
            if ((row.toolCallId == null || row.toolCallId!.isEmpty) &&
                row.toolName == draft.toolName) {
              match = row;
              break;
            }
          }
        }
        if (match != null) used.add(match.partId);
        matches[i] = match;
      }

      for (final row in existing) {
        if (used.contains(row.partId)) continue;
        await (db.delete(
          db.messageParts,
        )..where((t) => t.partId.equals(row.partId))).go();
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      const tempOrdinalOffset = 1000000;
      for (final row in existing) {
        if (!used.contains(row.partId)) continue;
        await (db.update(
          db.messageParts,
        )..where((t) => t.partId.equals(row.partId))).write(
          MessagePartsCompanion(ordinal: Value(tempOrdinalOffset + row.partId)),
        );
      }

      for (var i = 0; i < drafts.length; i++) {
        final draft = drafts[i];
        final match = matches[i];
        if (match != null) {
          await (db.update(
            db.messageParts,
          )..where((t) => t.partId.equals(match.partId))).write(
            MessagePartsCompanion(
              ordinal: Value(i),
              toolCallId: Value(draft.toolCallId),
              toolName: Value(draft.toolName),
              argumentsJson: Value(draft.argumentsJson),
              content: Value(draft.content),
              status: Value(draft.status),
              approvalState: Value(draft.approvalState),
              metadataJson: Value(draft.metadataJson),
              updatedAtMs: Value(now),
            ),
          );
          continue;
        }
        await db
            .into(db.messageParts)
            .insert(
              MessagePartsCompanion.insert(
                messageId: messageId,
                ordinal: i,
                kind: kToolPartKind,
                toolCallId: Value(draft.toolCallId),
                toolName: Value(draft.toolName),
                argumentsJson: Value(draft.argumentsJson),
                content: Value(draft.content),
                status: Value(draft.status),
                approvalState: Value(draft.approvalState),
                metadataJson: Value(draft.metadataJson),
                createdAtMs: now,
                updatedAtMs: now,
              ),
            );
      }
    });
  }

  /// Full legacy-shaped events for model replay, ordered by ordinal.
  Future<List<Map<String, dynamic>>> getToolEvents(
    String assistantMessageId,
  ) async {
    final rows =
        await (db.select(db.messageParts)
              ..where((t) => t.messageId.equals(assistantMessageId))
              ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
            .get();
    return [
      for (final row in rows)
        if (row.kind == kToolPartKind)
          toolEventFromStoredPart(
            toolCallId: row.toolCallId,
            toolName: row.toolName,
            argumentsJson: row.argumentsJson,
            content: row.content,
            approvalState: row.approvalState ?? kApprovalAuto,
            metadataJson: row.metadataJson,
          ),
    ];
  }

  /// Parses the completed search tool results for one message into citation
  /// rows. Only search parts are read; the timeline never loads the rest of
  /// the message's tool bodies for the sources card.
  Future<List<Map<String, dynamic>>> getSearchCitations(
    String assistantMessageId,
  ) async {
    final rows =
        await (db.select(db.messageParts)
              ..where(
                (t) =>
                    t.messageId.equals(assistantMessageId) &
                    t.toolName.isIn(const ['search_web', 'builtin_search']) &
                    t.status.equals(kPartStatusCompleted),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.ordinal)]))
            .get();
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final row in rows) {
      final content = row.content;
      if (content == null || content.isEmpty) continue;
      try {
        final decoded = jsonDecode(content);
        if (decoded is! Map) continue;
        final items = decoded['items'];
        if (items is! List) continue;
        for (final item in items) {
          if (item is! Map) continue;
          final map = item.map((k, v) => MapEntry(k.toString(), v));
          final key = (map['id'] ?? map['url'] ?? '').toString();
          if (key.isNotEmpty && !seen.add(key)) continue;
          out.add(map);
        }
      } catch (_) {}
    }
    return out;
  }

  /// Summary-only view for the timeline. Completed bodies never leave SQLite.
  Future<List<ToolPartSummary>> getToolPartSummaries(
    String assistantMessageId,
  ) async {
    final contentLength = FunctionCallExpression<int>('length', [
      db.messageParts.content,
    ]);
    final argumentsLength = FunctionCallExpression<int>('length', [
      db.messageParts.argumentsJson,
    ]);
    final argumentsPreview = FunctionCallExpression<String>('substr', [
      db.messageParts.argumentsJson,
      const Constant(1),
      const Constant(256),
    ]);
    const eagerContent = CustomExpression<String>(
      "CASE WHEN message_parts.status IN ('pending', 'denied') "
      "OR message_parts.tool_name = 'ask_user' "
      'THEN message_parts.content END',
    );
    const eagerArguments = CustomExpression<String>(
      "CASE WHEN message_parts.status IN ('pending', 'denied') "
      "OR message_parts.tool_name IN ('ask_user', 'write_todos') "
      'THEN message_parts.arguments_json END',
    );
    final searchProvider = _metadataText(r'$.searchProvider');
    final searchFallbackFrom = _metadataText(r'$.searchFallbackFrom');
    final webFetchSource = _metadataText(r'$.webFetchSource');
    final query = db.selectOnly(db.messageParts)
      ..addColumns([
        db.messageParts.partId,
        db.messageParts.messageId,
        db.messageParts.ordinal,
        db.messageParts.toolCallId,
        db.messageParts.toolName,
        db.messageParts.approvalState,
        db.messageParts.status,
        db.messageParts.updatedAtMs,
        eagerContent,
        eagerArguments,
        searchProvider,
        searchFallbackFrom,
        webFetchSource,
        contentLength,
        argumentsLength,
        argumentsPreview,
      ])
      ..where(
        db.messageParts.messageId.equals(assistantMessageId) &
            db.messageParts.kind.equals(kToolPartKind),
      )
      ..orderBy([OrderingTerm.asc(db.messageParts.ordinal)]);

    final rows = await query.get();
    return [
      for (final row in rows)
        _summaryFromRow(
          row,
          contentLength: contentLength,
          argumentsLength: argumentsLength,
          argumentsPreview: argumentsPreview,
          eagerContent: eagerContent,
          eagerArguments: eagerArguments,
          searchProvider: searchProvider,
          searchFallbackFrom: searchFallbackFrom,
          webFetchSource: webFetchSource,
        ),
    ];
  }

  FunctionCallExpression<String> _metadataText(String path) {
    return FunctionCallExpression<String>('json_extract', [
      db.messageParts.metadataJson,
      Constant(path),
    ]);
  }

  Future<List<ToolPartSummary>> getToolPartSummariesForMessages(
    Iterable<String> messageIds,
  ) async {
    final ids = messageIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const <ToolPartSummary>[];
    final contentLength = FunctionCallExpression<int>('length', [
      db.messageParts.content,
    ]);
    final argumentsLength = FunctionCallExpression<int>('length', [
      db.messageParts.argumentsJson,
    ]);
    final argumentsPreview = FunctionCallExpression<String>('substr', [
      db.messageParts.argumentsJson,
      const Constant(1),
      const Constant(256),
    ]);
    const eagerContent = CustomExpression<String>(
      "CASE WHEN message_parts.status IN ('pending', 'denied') "
      "OR message_parts.tool_name = 'ask_user' "
      'THEN message_parts.content END',
    );
    const eagerArguments = CustomExpression<String>(
      "CASE WHEN message_parts.status IN ('pending', 'denied') "
      "OR message_parts.tool_name IN ('ask_user', 'write_todos') "
      'THEN message_parts.arguments_json END',
    );
    final searchProvider = _metadataText(r'$.searchProvider');
    final searchFallbackFrom = _metadataText(r'$.searchFallbackFrom');
    final webFetchSource = _metadataText(r'$.webFetchSource');

    final result = <ToolPartSummary>[];
    for (var start = 0; start < ids.length; start += 500) {
      final chunk = ids.sublist(
        start,
        start + 500 > ids.length ? ids.length : start + 500,
      );
      final query = db.selectOnly(db.messageParts)
        ..addColumns([
          db.messageParts.partId,
          db.messageParts.messageId,
          db.messageParts.ordinal,
          db.messageParts.toolCallId,
          db.messageParts.toolName,
          db.messageParts.approvalState,
          db.messageParts.status,
          db.messageParts.updatedAtMs,
          eagerContent,
          eagerArguments,
          searchProvider,
          searchFallbackFrom,
          webFetchSource,
          contentLength,
          argumentsLength,
          argumentsPreview,
        ])
        ..where(
          db.messageParts.messageId.isIn(chunk) &
              db.messageParts.kind.equals(kToolPartKind),
        )
        ..orderBy([
          OrderingTerm.asc(db.messageParts.messageId),
          OrderingTerm.asc(db.messageParts.ordinal),
        ]);
      final rows = await query.get();
      result.addAll([
        for (final row in rows)
          _summaryFromRow(
            row,
            contentLength: contentLength,
            argumentsLength: argumentsLength,
            argumentsPreview: argumentsPreview,
            eagerContent: eagerContent,
            eagerArguments: eagerArguments,
            searchProvider: searchProvider,
            searchFallbackFrom: searchFallbackFrom,
            webFetchSource: webFetchSource,
          ),
      ]);
    }
    return result;
  }

  /// Loads a single part's full arguments and content on expand. Accepts a part
  /// id or a tool call id (first match by ordinal).
  Future<Map<String, dynamic>?> loadToolEventDetail({
    required String assistantMessageId,
    int? partId,
    String? toolCallId,
  }) async {
    if (partId == null && toolCallId == null) return null;
    final query = db.select(db.messageParts)
      ..where((t) {
        if (partId != null) {
          return t.messageId.equals(assistantMessageId) &
              t.partId.equals(partId);
        }
        return t.messageId.equals(assistantMessageId) &
            t.toolCallId.equals(toolCallId!);
      })
      ..orderBy([(t) => OrderingTerm.asc(t.ordinal)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return toolEventFromStoredPart(
      toolCallId: row.toolCallId,
      toolName: row.toolName,
      argumentsJson: row.argumentsJson,
      content: row.content,
      approvalState: row.approvalState ?? kApprovalAuto,
      metadataJson: row.metadataJson,
    );
  }

  /// Full replayable parts for a bounded set of message ids, ordered.
  Future<Map<String, List<MessagePartRow>>> replayablePartsForMessages(
    Iterable<String> messageIds,
  ) async {
    final ids = messageIds.where((id) => id.isNotEmpty).toSet().toList();
    final result = <String, List<MessagePartRow>>{};
    if (ids.isEmpty) return result;
    for (var start = 0; start < ids.length; start += 500) {
      final chunk = ids.sublist(
        start,
        start + 500 > ids.length ? ids.length : start + 500,
      );
      final rows =
          await (db.select(db.messageParts)
                ..where(
                  (t) =>
                      t.messageId.isIn(chunk) &
                      t.status.isIn([kPartStatusCompleted, kPartStatusDenied]),
                )
                ..orderBy([
                  (t) => OrderingTerm.asc(t.messageId),
                  (t) => OrderingTerm.asc(t.ordinal),
                ]))
              .get();
      for (final row in rows) {
        (result[row.messageId] ??= <MessagePartRow>[]).add(row);
      }
    }
    return result;
  }

  Future<int> _nextPartOrdinal(String messageId) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(ordinal), -1) + 1 AS next FROM message_parts '
          'WHERE message_id = ?',
          variables: [Variable.withString(messageId)],
        )
        .getSingle();
    return row.read<int>('next');
  }

  ToolPartSummary _summaryFromRow(
    TypedResult row, {
    required Expression<int> contentLength,
    required Expression<int> argumentsLength,
    required Expression<String> argumentsPreview,
    required Expression<String> eagerContent,
    required Expression<String> eagerArguments,
    required Expression<String> searchProvider,
    required Expression<String> searchFallbackFrom,
    required Expression<String> webFetchSource,
  }) {
    final status = row.read(db.messageParts.status) ?? kPartStatusPending;
    final contentChars = row.read(contentLength) ?? 0;
    final approval = row.read(db.messageParts.approvalState) ?? kApprovalAuto;
    final eager = row.read(eagerContent);
    return ToolPartSummary(
      partId: row.read(db.messageParts.partId)!,
      messageId: row.read(db.messageParts.messageId)!,
      ordinal: row.read(db.messageParts.ordinal)!,
      toolCallId: row.read(db.messageParts.toolCallId),
      toolName: row.read(db.messageParts.toolName),
      approvalState: approval,
      status: status,
      contentLengthChars: contentChars,
      argumentsLengthChars: row.read(argumentsLength) ?? 0,
      argumentsPreview: row.read(argumentsPreview),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read(db.messageParts.updatedAtMs) ?? 0,
      ),
      eagerContent: eager,
      eagerArgumentsJson: row.read(eagerArguments),
      searchProvider: row.read(searchProvider),
      searchFallbackFrom: row.read(searchFallbackFrom),
      webFetchSource: row.read(webFetchSource),
    );
  }

  // ---------------------------------------------------------------------------
  // Provider artifacts (Gemini thought signature)
  // ---------------------------------------------------------------------------

  Future<String?> getProviderArtifact(String messageId, String kind) async {
    final row =
        await (db.select(db.providerArtifacts)..where(
              (t) => t.messageId.equals(messageId) & t.kind.equals(kind),
            ))
            .getSingleOrNull();
    return row?.payload;
  }

  /// All artifacts of one kind (currently the Gemini thought signatures) for
  /// the startup cache.
  Future<Map<String, String>> allProviderArtifactsOfKind(String kind) async {
    final rows = await (db.select(
      db.providerArtifacts,
    )..where((t) => t.kind.equals(kind))).get();
    return {for (final row in rows) row.messageId: row.payload};
  }

  Future<void> setProviderArtifact(
    String messageId,
    String kind,
    String payload,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.providerArtifacts)
        .insertOnConflictUpdate(
          ProviderArtifactRow(
            messageId: messageId,
            kind: kind,
            payload: payload,
            createdAtMs: now,
            updatedAtMs: now,
          ),
        );
  }

  Future<void> deleteProviderArtifact(String messageId, String kind) async {
    await (db.delete(
      db.providerArtifacts,
    )..where((t) => t.messageId.equals(messageId) & t.kind.equals(kind))).go();
  }

  // ---------------------------------------------------------------------------
  // File records
  // ---------------------------------------------------------------------------

  Future<List<FileRecord>> getFileRecords(String messageId) async {
    final rows =
        await (db.select(db.messageFileRecords)
              ..where((t) => t.messageId.equals(messageId))
              ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
            .get();
    return [
      for (final row in rows)
        FileRecord(
          path: row.path,
          fileName: row.fileName ?? '',
          sizeBytes: row.sizeBytes,
          createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAtMs),
        ),
    ];
  }

  /// All file records grouped by message for the startup cache.
  Future<Map<String, List<FileRecord>>> allFileRecordsGrouped() async {
    final rows =
        await (db.select(db.messageFileRecords)..orderBy([
              (t) => OrderingTerm.asc(t.messageId),
              (t) => OrderingTerm.asc(t.ordinal),
            ]))
            .get();
    final result = <String, List<FileRecord>>{};
    for (final row in rows) {
      (result[row.messageId] ??= <FileRecord>[]).add(
        FileRecord(
          path: row.path,
          fileName: row.fileName ?? '',
          sizeBytes: row.sizeBytes,
          createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAtMs),
        ),
      );
    }
    return result;
  }

  Future<void> upsertFileRecord(String messageId, FileRecord record) async {
    await db.transaction(() async {
      final existing =
          await (db.select(db.messageFileRecords)..where(
                (t) =>
                    t.messageId.equals(messageId) & t.path.equals(record.path),
              ))
              .getSingleOrNull();
      if (existing != null) {
        await (db.update(
          db.messageFileRecords,
        )..where((t) => t.id.equals(existing.id))).write(
          MessageFileRecordsCompanion(
            fileName: Value(record.fileName),
            sizeBytes: Value(record.sizeBytes),
            createdAtMs: Value(record.createdAt.millisecondsSinceEpoch),
          ),
        );
        return;
      }
      final ordinalRow = await db
          .customSelect(
            'SELECT COALESCE(MAX(ordinal), -1) + 1 AS next '
            'FROM message_file_records WHERE message_id = ?',
            variables: [Variable.withString(messageId)],
          )
          .getSingle();
      await db
          .into(db.messageFileRecords)
          .insert(
            MessageFileRecordsCompanion.insert(
              messageId: messageId,
              ordinal: ordinalRow.read<int>('next'),
              path: record.path,
              fileName: Value(record.fileName),
              sizeBytes: Value(record.sizeBytes),
              createdAtMs: record.createdAt.millisecondsSinceEpoch,
            ),
          );
    });
  }

  Future<void> replaceFileRecords(
    String messageId,
    List<FileRecord> records,
  ) async {
    await db.transaction(() async {
      await (db.delete(
        db.messageFileRecords,
      )..where((t) => t.messageId.equals(messageId))).go();
      for (var i = 0; i < records.length; i++) {
        final record = records[i];
        await db
            .into(db.messageFileRecords)
            .insert(
              MessageFileRecordsCompanion.insert(
                messageId: messageId,
                ordinal: i,
                path: record.path,
                fileName: Value(record.fileName),
                sizeBytes: Value(record.sizeBytes),
                createdAtMs: record.createdAt.millisecondsSinceEpoch,
              ),
            );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Workspace bindings
  // ---------------------------------------------------------------------------

  Future<WorkspaceConfig?> getWorkspaceBinding(String conversationId) async {
    final row = await (db.select(
      db.conversationWorkspaceBindings,
    )..where((t) => t.conversationId.equals(conversationId))).getSingleOrNull();
    if (row == null) return null;
    try {
      return WorkspaceConfig.fromJson(jsonDecode(row.configJson));
    } catch (_) {
      return null;
    }
  }

  /// All workspace bindings for the startup cache.
  Future<Map<String, WorkspaceConfig>> allWorkspaceBindings() async {
    final rows = await db.select(db.conversationWorkspaceBindings).get();
    final result = <String, WorkspaceConfig>{};
    for (final row in rows) {
      try {
        result[row.conversationId] = WorkspaceConfig.fromJson(
          jsonDecode(row.configJson),
        );
      } catch (_) {
        // A malformed binding is skipped; the conversation falls back to the
        // project/default workspace chain.
      }
    }
    return result;
  }

  Future<void> setWorkspaceBinding(
    String conversationId,
    WorkspaceConfig config,
  ) async {
    await db
        .into(db.conversationWorkspaceBindings)
        .insertOnConflictUpdate(
          ConversationWorkspaceBindingRow(
            conversationId: conversationId,
            configJson: jsonEncode(config.toJson()),
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  Future<void> deleteWorkspaceBinding(String conversationId) async {
    await (db.delete(
      db.conversationWorkspaceBindings,
    )..where((t) => t.conversationId.equals(conversationId))).go();
  }

  // ---------------------------------------------------------------------------
  // Forking
  // ---------------------------------------------------------------------------

  /// Clones messages, parts, provider artifacts, file records, and the
  /// workspace binding with fresh ids/ordinals in one transaction. Unlike the
  /// Hive implementation this includes tool parts (§9.4).
  Future<Conversation> forkConversation({
    required String title,
    required String? assistantId,
    required List<ChatMessage> sourceMessages,
    Map<String, int>? versionSelections,
  }) async {
    return db.transaction(() async {
      final sourceConversationId = sourceMessages.isEmpty
          ? null
          : sourceMessages.first.conversationId;
      final now = DateTime.now();
      final convo = Conversation(
        title: title,
        assistantId: assistantId,
        createdAt: now,
        updatedAt: now,
        versionSelections: Map<String, int>.from(
          versionSelections ?? const <String, int>{},
        ),
      );
      await upsertConversation(convo);
      final clonedIds = <String>[];

      for (var i = 0; i < sourceMessages.length; i++) {
        final src = sourceMessages[i];
        final clone = ChatMessage(
          role: src.role,
          content: src.content,
          timestamp: src.timestamp,
          modelId: src.modelId,
          providerId: src.providerId,
          totalTokens: src.totalTokens,
          promptTokens: src.promptTokens,
          completionTokens: src.completionTokens,
          cachedTokens: src.cachedTokens,
          conversationId: convo.id,
          isStreaming: false,
          reasoningText: src.reasoningText,
          reasoningStartAt: src.reasoningStartAt,
          reasoningFinishedAt: src.reasoningFinishedAt,
          translation: src.translation,
          reasoningSegmentsJson: src.reasoningSegmentsJson,
          groupId: src.groupId,
          version: src.version,
          aiTeamProposalsJson: src.aiTeamProposalsJson,
          processStartedAt: src.processStartedAt,
          processFinishedAt: src.processFinishedAt,
        );
        await _insertMessage(clone, i);
        clonedIds.add(clone.id);

        final parts =
            await (db.select(db.messageParts)
                  ..where((t) => t.messageId.equals(src.id))
                  ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
                .get();
        for (final part in parts) {
          await db
              .into(db.messageParts)
              .insert(
                MessagePartsCompanion.insert(
                  messageId: clone.id,
                  ordinal: part.ordinal,
                  kind: part.kind,
                  toolCallId: Value(part.toolCallId),
                  toolName: Value(part.toolName),
                  argumentsJson: Value(part.argumentsJson),
                  content: Value(part.content),
                  status: Value(part.status),
                  approvalState: Value(part.approvalState),
                  metadataJson: Value(part.metadataJson),
                  createdAtMs: part.createdAtMs,
                  updatedAtMs: part.updatedAtMs,
                ),
              );
        }
        final artifacts = await (db.select(
          db.providerArtifacts,
        )..where((t) => t.messageId.equals(src.id))).get();
        for (final artifact in artifacts) {
          await setProviderArtifact(clone.id, artifact.kind, artifact.payload);
        }
        final records =
            await (db.select(db.messageFileRecords)
                  ..where((t) => t.messageId.equals(src.id))
                  ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
                .get();
        for (final record in records) {
          await upsertFileRecord(
            clone.id,
            FileRecord(
              path: record.path,
              fileName: record.fileName ?? '',
              sizeBytes: record.sizeBytes,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                record.createdAtMs,
              ),
            ),
          );
        }
      }

      if (sourceConversationId != null) {
        final binding = await getWorkspaceBinding(sourceConversationId);
        if (binding != null) {
          await setWorkspaceBinding(convo.id, binding);
        }
      }
      // The Hive facade returns a conversation with its messageIds populated;
      // callers navigate straight to the fork, so an empty list would render
      // an empty conversation until a reload.
      return convo.copyWith(messageIds: clonedIds);
    });
  }

  // ---------------------------------------------------------------------------
  // Startup repair
  // ---------------------------------------------------------------------------

  /// Clears stale streaming flags and interrupts parts with no result. A part
  /// still waiting for approval is never flipped.
  Future<({int messages, int parts})> repairStaleStreaming() async {
    final messages = await db.customUpdate(
      'UPDATE messages SET is_streaming = 0 WHERE is_streaming = 1',
      updates: {db.messageRows},
    );
    final parts = await db.customUpdate(
      "UPDATE message_parts SET status = 'interrupted' "
      'WHERE content IS NULL '
      "AND status <> 'denied' "
      "AND (approval_state IS NULL OR approval_state <> 'pending')",
      updates: {db.messageParts},
    );
    return (messages: messages, parts: parts);
  }

  // ---------------------------------------------------------------------------
  // Migration metadata and quarantine
  // ---------------------------------------------------------------------------

  Future<Map<String, String>> readMigrationMeta() async {
    final rows = await db.select(db.migrationMeta).get();
    return {for (final row in rows) row.key: row.value};
  }

  Future<void> putMigrationMeta(Map<String, String> values) async {
    await db.transaction(() async {
      for (final entry in values.entries) {
        await db
            .into(db.migrationMeta)
            .insertOnConflictUpdate(
              MigrationMetaRow(key: entry.key, value: entry.value),
            );
      }
    });
  }

  Future<int> insertQuarantine({
    required String sourceBox,
    String? sourceKey,
    String? payloadJson,
    String? payloadSha256,
    required String error,
  }) async {
    return db
        .into(db.legacyQuarantine)
        .insert(
          LegacyQuarantineCompanion.insert(
            sourceBox: sourceBox,
            sourceKey: Value(sourceKey),
            payloadJson: Value(payloadJson),
            payloadSha256: Value(payloadSha256),
            error: error,
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  Future<int> quarantineCount() async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS c FROM legacy_quarantine')
        .getSingle();
    return row.read<int>('c');
  }

  Future<List<LegacyQuarantineRow>> readQuarantine() async {
    return db.select(db.legacyQuarantine).get();
  }

  // ---------------------------------------------------------------------------
  // Aggregates for migration validation
  // ---------------------------------------------------------------------------

  Future<ChatStorageCounts> counts() async {
    Future<int> count(String table) async {
      final row = await db
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle();
      return row.read<int>('c');
    }

    return ChatStorageCounts(
      conversations: await count('conversations'),
      messages: await count('messages'),
      parts: await count('message_parts'),
      providerArtifacts: await count('provider_artifacts'),
      fileRecords: await count('message_file_records'),
      workspaceBindings: await count('conversation_workspace_bindings'),
      quarantined: await count('legacy_quarantine'),
    );
  }

  Future<PayloadByteSums> payloadByteSums() async {
    Future<int> sum(String sql) async {
      final row = await db.customSelect(sql).getSingle();
      return row.read<int>('s');
    }

    return PayloadByteSums(
      messageContentBytes: await sum(
        'SELECT COALESCE(SUM(length(CAST(content AS BLOB))), 0) AS s '
        'FROM messages',
      ),
      partContentBytes: await sum(
        'SELECT COALESCE(SUM(length(CAST(content AS BLOB))), 0) AS s '
        'FROM message_parts',
      ),
      argumentBytes: await sum(
        'SELECT COALESCE(SUM(length(CAST(arguments_json AS BLOB))), 0) AS s '
        'FROM message_parts',
      ),
    );
  }

  Future<int> maxMessageOrdinal(String conversationId) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(ordinal), -1) AS m FROM messages '
          'WHERE conversation_id = ?',
          variables: [Variable.withString(conversationId)],
        )
        .getSingle();
    return row.read<int>('m');
  }

  Future<List<MessageRow>> allMessageRows() =>
      (db.select(db.messageRows)..orderBy([
            (t) => OrderingTerm.asc(t.conversationId),
            (t) => OrderingTerm.asc(t.ordinal),
          ]))
          .get();

  Future<List<MessagePartRow>> partsForMessage(String messageId) =>
      (db.select(db.messageParts)
            ..where((t) => t.messageId.equals(messageId))
            ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
          .get();

  Future<List<MessagePartRow>> allPartsBatch(List<String> messageIds) async {
    final result = <MessagePartRow>[];
    for (var start = 0; start < messageIds.length; start += 500) {
      final chunk = messageIds.sublist(
        start,
        start + 500 > messageIds.length ? messageIds.length : start + 500,
      );
      final rows =
          await (db.select(db.messageParts)
                ..where((t) => t.messageId.isIn(chunk))
                ..orderBy([
                  (t) => OrderingTerm.asc(t.messageId),
                  (t) => OrderingTerm.asc(t.ordinal),
                ]))
              .get();
      result.addAll(rows);
    }
    return result;
  }

  Future<List<String>> duplicateMessageOrdinals() async {
    final rows = await db
        .customSelect(
          'SELECT conversation_id, ordinal, COUNT(*) AS c FROM messages '
          'GROUP BY conversation_id, ordinal HAVING c > 1',
        )
        .get();
    return [
      for (final row in rows)
        '${row.read<String>('conversation_id')}#${row.read<int>('ordinal')}',
    ];
  }

  Future<List<String>> duplicatePartOrdinals() async {
    final rows = await db
        .customSelect(
          'SELECT message_id, ordinal, COUNT(*) AS c FROM message_parts '
          'GROUP BY message_id, ordinal HAVING c > 1',
        )
        .get();
    return [
      for (final row in rows)
        '${row.read<String>('message_id')}#${row.read<int>('ordinal')}',
    ];
  }

  Future<List<String>> invalidConversationIndexes() async {
    final rows = await db
        .customSelect(
          'SELECT c.id AS id, c.truncate_index AS t, c.compact_before_index AS b, '
          '(SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS n '
          'FROM conversations c',
        )
        .get();
    final bad = <String>[];
    for (final row in rows) {
      final id = row.read<String>('id');
      final t = row.read<int>('t');
      final b = row.read<int>('b');
      final n = row.read<int>('n');
      final tOk = t == -1 || (t >= 0 && t <= n);
      final bOk = b == -1 || (b >= 0 && b <= n);
      if (!tOk || !bOk) bad.add('$id (truncate=$t, compact=$b, messages=$n)');
    }
    return bad;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<int> _nextOrdinal(String conversationId) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(ordinal), -1) + 1 AS next FROM messages '
          'WHERE conversation_id = ?',
          variables: [Variable.withString(conversationId)],
        )
        .getSingle();
    return row.read<int>('next');
  }

  Future<void> _insertMessage(ChatMessage message, int ordinal) async {
    await db
        .into(db.messageRows)
        .insertOnConflictUpdate(_messageRow(message, ordinal));
  }

  Future<void> _touchConversation(String conversationId) async {
    await (db.update(
      db.conversationRows,
    )..where((t) => t.id.equals(conversationId))).write(
      ConversationRowsCompanion(
        updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// Two-phase renumber: shift by a temporary offset, then assign 0..n-1, so
  /// `UNIQUE(conversation_id, ordinal)` can never collide mid-update.
  Future<void> _renumberMessages(
    String conversationId,
    List<String> orderedIds,
  ) async {
    const offset = 1000000;
    await db.customUpdate(
      'UPDATE messages SET ordinal = ordinal + ? WHERE conversation_id = ?',
      variables: [
        Variable.withInt(offset),
        Variable.withString(conversationId),
      ],
      updates: {db.messageRows},
    );
    for (var i = 0; i < orderedIds.length; i++) {
      await db.customUpdate(
        'UPDATE messages SET ordinal = ? WHERE id = ?',
        variables: [Variable.withInt(i), Variable.withString(orderedIds[i])],
        updates: {db.messageRows},
      );
    }
  }

  int _clampIndex(int index, int removedIndex, int newCount) {
    if (index < 0) return -1;
    if (newCount == 0) return -1;
    var value = removedIndex >= 0 && index > removedIndex ? index - 1 : index;
    if (value > newCount) value = newCount;
    if (value < 0) value = 0;
    return value;
  }

  ConversationRow _conversationRow(Conversation c, bool isRecovered) {
    return ConversationRow(
      id: c.id,
      title: c.title,
      createdAtMs: c.createdAt.millisecondsSinceEpoch,
      updatedAtMs: c.updatedAt.millisecondsSinceEpoch,
      assistantId: c.assistantId,
      isPinned: c.isPinned,
      truncateIndex: c.truncateIndex,
      compactBeforeIndex: c.compactBeforeIndex,
      summary: c.summary,
      lastSummarizedMessageCount: c.lastSummarizedMessageCount,
      mcpServerIdsJson: jsonEncode(c.mcpServerIds),
      versionSelectionsJson: jsonEncode(c.versionSelections),
      isRecovered: isRecovered,
    );
  }

  MessageRow _messageRow(ChatMessage m, int ordinal) {
    return MessageRow(
      id: m.id,
      conversationId: m.conversationId,
      ordinal: ordinal,
      role: m.role,
      content: m.content,
      timestampMs: m.timestamp.millisecondsSinceEpoch,
      modelId: m.modelId,
      providerId: m.providerId,
      totalTokens: m.totalTokens,
      promptTokens: m.promptTokens,
      completionTokens: m.completionTokens,
      cachedTokens: m.cachedTokens,
      // The importer normalizes this to false; live placeholders keep their
      // streaming flag so the UI can show the in-progress state.
      isStreaming: m.isStreaming,
      reasoningText: m.reasoningText,
      reasoningStartAtMs: m.reasoningStartAt?.millisecondsSinceEpoch,
      reasoningFinishedAtMs: m.reasoningFinishedAt?.millisecondsSinceEpoch,
      translation: m.translation,
      reasoningSegmentsJson: m.reasoningSegmentsJson,
      groupId: m.groupId,
      version: m.version,
      aiTeamProposalsJson: m.aiTeamProposalsJson,
      processStartedAtMs: m.processStartedAt?.millisecondsSinceEpoch,
      processFinishedAtMs: m.processFinishedAt?.millisecondsSinceEpoch,
    );
  }

  Conversation _conversationFromRow(
    ConversationRow row,
    List<String> messageIds,
  ) {
    return Conversation(
      id: row.id,
      title: row.title,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAtMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAtMs),
      messageIds: List<String>.of(messageIds),
      isPinned: row.isPinned,
      mcpServerIds: decodeStringList(row.mcpServerIdsJson),
      assistantId: row.assistantId,
      truncateIndex: row.truncateIndex,
      versionSelections: decodeIntMap(row.versionSelectionsJson),
      summary: row.summary,
      lastSummarizedMessageCount: row.lastSummarizedMessageCount,
      compactBeforeIndex: row.compactBeforeIndex,
    );
  }

  ChatMessage _messageFromRow(MessageRow row) {
    return ChatMessage(
      id: row.id,
      role: row.role,
      content: row.content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row.timestampMs),
      modelId: row.modelId,
      providerId: row.providerId,
      totalTokens: row.totalTokens,
      promptTokens: row.promptTokens,
      completionTokens: row.completionTokens,
      cachedTokens: row.cachedTokens,
      conversationId: row.conversationId,
      isStreaming: row.isStreaming,
      reasoningText: row.reasoningText,
      reasoningStartAt: row.reasoningStartAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.reasoningStartAtMs!),
      reasoningFinishedAt: row.reasoningFinishedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.reasoningFinishedAtMs!),
      translation: row.translation,
      reasoningSegmentsJson: row.reasoningSegmentsJson,
      groupId: row.groupId,
      version: row.version,
      aiTeamProposalsJson: row.aiTeamProposalsJson,
      processStartedAt: row.processStartedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.processStartedAtMs!),
      processFinishedAt: row.processFinishedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.processFinishedAtMs!),
    );
  }
}

Map<String, dynamic> _decodeMapOrEmpty(String? raw) {
  final decoded = decodeJsonValue(raw);
  if (decoded is! Map) return <String, dynamic>{};
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

List<String> decodeStringList(String? raw) {
  final decoded = decodeJsonValue(raw);
  if (decoded is! List) return const <String>[];
  return [for (final value in decoded) value.toString()];
}

Map<String, int> decodeIntMap(String? raw) {
  final map = _decodeMapOrEmpty(raw);
  final result = <String, int>{};
  map.forEach((key, value) {
    if (value is num) result[key] = value.toInt();
  });
  return result;
}

class ChatStorageCounts {
  const ChatStorageCounts({
    required this.conversations,
    required this.messages,
    required this.parts,
    required this.providerArtifacts,
    required this.fileRecords,
    required this.workspaceBindings,
    required this.quarantined,
  });

  final int conversations;
  final int messages;
  final int parts;
  final int providerArtifacts;
  final int fileRecords;
  final int workspaceBindings;
  final int quarantined;

  Map<String, int> toJson() => {
    'conversations': conversations,
    'messages': messages,
    'parts': parts,
    'provider_artifacts': providerArtifacts,
    'file_records': fileRecords,
    'workspace_bindings': workspaceBindings,
    'quarantined': quarantined,
  };
}

class PayloadByteSums {
  const PayloadByteSums({
    required this.messageContentBytes,
    required this.partContentBytes,
    required this.argumentBytes,
  });

  final int messageContentBytes;
  final int partContentBytes;
  final int argumentBytes;

  Stream<int> get values => Stream<int>.fromIterable([
    messageContentBytes,
    partContentBytes,
    argumentBytes,
  ]);

  Map<String, int> toJson() => {
    'message_content_bytes': messageContentBytes,
    'part_content_bytes': partContentBytes,
    'argument_bytes': argumentBytes,
  };
}
