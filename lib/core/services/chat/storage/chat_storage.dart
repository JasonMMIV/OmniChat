import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import '../../../models/file_record.dart';
import '../../../models/workspace_config.dart';
import 'message_part_codec.dart';

/// Persisted-preview bound for `file_read` results (existing writer policy).
const int kMaxPersistedFileReadResultChars = 8192;

/// Applies the existing `file_read` persisted-preview policy. Shared by the
/// facade and the Hive backend so both agree byte-for-byte; the SQLite backend
/// receives already-bounded values from the facade.
String? boundPersistedToolResult(String name, String? content) {
  if (name != 'file_read' ||
      content == null ||
      content.length <= kMaxPersistedFileReadResultChars) {
    return content;
  }
  const marker = '\n\n...[file_read result persisted preview]...\n\n';
  final available = kMaxPersistedFileReadResultChars - marker.length;
  final headLength = available ~/ 2;
  final tailLength = available - headLength;
  return '${content.substring(0, headLength)}$marker'
      '${content.substring(content.length - tailLength)}';
}

/// Normalizes a tool event for persistence: non-string content becomes null
/// and `file_read` content is bounded.
Map<String, dynamic> boundPersistedToolEvent(Map<String, dynamic> event) {
  final bounded = Map<String, dynamic>.from(event);
  final content = bounded['content'];
  bounded['content'] = boundPersistedToolResult(
    bounded['name']?.toString() ?? '',
    content is String ? content : null,
  );
  return bounded;
}

/// Which persistence backend the chat facade is currently using.
enum ChatStorageBackend { hive, sqlite }

/// Thrown by the synchronous facade cache when data was never loaded. A cache
/// miss must never be mistaken for "loaded and empty" (§9.2).
///
/// The async entry points that need model replay must call
/// [ChatStorage.ensureConversationLoaded] / [ChatStorage.ensureToolEventsLoaded]
/// before invoking a synchronous builder. There is deliberately no synchronous
/// retry.
class ChatStorageNotLoadedException implements Exception {
  const ChatStorageNotLoadedException(this.what);

  final String what;

  @override
  String toString() =>
      'ChatStorageNotLoadedException: $what is not loaded; '
      'await the matching ensure...Loaded call first.';
}

/// Persistence contract behind [ChatService] (§9.1).
///
/// Draft conversations stay in the facade: both backends only ever see
/// persisted conversations. Reads are synchronous and cache-backed; writes are
/// asynchronous and update the cache in the same operation.
///
/// Message bodies and tool events are deliberately *not* part of the startup
/// cache: they are loaded per conversation with [ensureConversationLoaded] /
/// [ensureToolEventsLoaded], and [getMessages]/[getToolEvents] fail closed for
/// content that was never loaded. An empty list therefore always means
/// "loaded and genuinely empty".
abstract class ChatStorage {
  ChatStorageBackend get backend;

  /// Opens the backend and populates the metadata cache. Message bodies are
  /// loaded per conversation by [ensureConversationLoaded].
  Future<void> initialize();

  /// Closes the backend. Never deletes data.
  Future<void> dispose();

  // ---------------------------------------------------------------------------
  // Reads (synchronous, cache backed)
  // ---------------------------------------------------------------------------

  /// Conversations ordered by `updatedAt` descending.
  List<Conversation> listConversations();

  Conversation? getConversation(String id);

  /// Messages for [conversationId] in storage order. An unknown conversation
  /// returns an empty list; a known-but-unloaded conversation fails closed with
  /// [ChatStorageNotLoadedException], never a misleading empty list.
  List<ChatMessage> getMessages(String conversationId);

  /// Loaded messages only. Call [ensureAllMessagesLoaded] first when a caller
  /// legitimately needs every conversation (backup, stats, cleanup).
  Iterable<ChatMessage> allMessages();

  /// True when every known conversation has its messages in the cache.
  bool get allMessagesLoaded;

  /// Whether [conversationId]'s messages are currently cached.
  bool isConversationLoaded(String conversationId);

  /// Message contents that may reference upload files, without loading every
  /// conversation into the message cache.
  Future<Iterable<String>> attachmentBearingMessageContents();

  List<Map<String, dynamic>> getToolEvents(String assistantMessageId);

  /// Timeline summaries for one message. Never carries a completed tool body;
  /// pending/denied and card-critical tools carry their eager payload.
  ///
  /// Fails closed with [ChatStorageNotLoadedException] when the summaries for
  /// the message were never loaded. Opening a conversation calls
  /// [ensureConversationLoaded] first.
  List<ToolPartSummary> getToolPartSummaries(String assistantMessageId);

  /// Loads one part's full arguments/content for an expanded tool card. Reads
  /// only that row; it never marks the whole message's events as loaded.
  Future<Map<String, dynamic>?> loadToolEventDetail({
    required String assistantMessageId,
    required String toolCallId,
  });

  /// Parses the search tool results of one message into citation rows.
  Future<List<Map<String, dynamic>>> getSearchCitations(
    String assistantMessageId,
  );

  String? getGeminiThoughtSignature(String assistantMessageId);

  List<FileRecord> getFileRecords(String messageId);

  WorkspaceConfig? getWorkspaceConfig(String conversationId);

  // ---------------------------------------------------------------------------
  // Async preloads
  // ---------------------------------------------------------------------------

  /// Loads one conversation's messages and timeline *summaries*. Full tool
  /// bodies stay in storage; idempotent, unknown conversation is a no-op.
  Future<void> ensureConversationLoaded(String conversationId);

  /// Loads every conversation's messages. Required only for full-history
  /// operations such as backup, import, stats, and re-import idle checks.
  Future<void> ensureAllMessagesLoaded();

  /// Loads full tool events for the given message ids. Messages without parts
  /// are marked loaded with an empty list.
  Future<void> ensureToolEventsLoaded(Iterable<String> messageIds);

  /// Loads full tool events for every persisted conversation. Required before
  /// backup/export, which legitimately reads every message.
  Future<void> ensureAllToolEventsLoaded();

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<void> putConversation(Conversation conversation);

  Future<void> deleteConversation(String id);

  Future<int> deleteConversations(Iterable<String> ids);

  Future<void> renameConversation(String id, String title);

  Future<void> setConversationPinned(String id, bool pinned);

  Future<void> setConversationSummary(
    String id,
    String? summary,
    int lastSummarizedMessageCount,
  );

  Future<void> setConversationAssistant(String id, String? assistantId);

  Future<void> setConversationMcpServers(String id, List<String> serverIds);

  Future<void> setConversationIndexes(
    String id, {
    required int truncateIndex,
    required int compactBeforeIndex,
  });

  Future<void> setVersionSelections(String id, Map<String, int> selections);

  /// Appends a message at the end of its conversation. When
  /// [touchConversation] is false the conversation `updated_at` is preserved
  /// (restore/merge path).
  Future<ChatMessage> appendMessage(
    ChatMessage message, {
    bool touchConversation = true,
  });

  Future<void> insertMessageAt(ChatMessage message, int ordinal);

  Future<void> addMessageDirectly(String conversationId, ChatMessage message);

  Future<void> restoreConversation(
    Conversation conversation,
    List<ChatMessage> messages,
  );

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
  });

  /// Deletes one message/version, renumbers the conversation, and clamps the
  /// truncate/compact indices. Returns false when the row is missing.
  Future<bool> deleteMessage(String messageId);

  Future<ChatMessage?> appendMessageVersion({
    required String messageId,
    required String content,
  });

  Future<void> setToolEvents(
    String assistantMessageId,
    List<Map<String, dynamic>> events,
  );

  Future<void> upsertToolEvent(
    String assistantMessageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    String? approvalState,
    Map<String, dynamic>? extras,
  });

  Future<bool> setToolEventApprovalState(
    String assistantMessageId, {
    required String id,
    required String approvalState,
    String? content,
  });

  Future<void> setGeminiThoughtSignature(
    String assistantMessageId,
    String signature,
  );

  Future<void> removeGeminiThoughtSignature(String assistantMessageId);

  Future<void> addFileRecord(String messageId, FileRecord record);

  /// Writes `null` to delete the binding.
  Future<void> setWorkspaceConfig(
    String conversationId,
    WorkspaceConfig? config,
  );

  /// Clones messages, parts, artifacts, file records, and the workspace
  /// binding in one transaction.
  Future<Conversation> forkConversation({
    required String title,
    required String? assistantId,
    required List<ChatMessage> sourceMessages,
    Map<String, int>? versionSelections,
  });

  /// Deletes every persisted chat row. The SQLite backend resets the database
  /// through the installation gate (§8.10) while the Hive backend clears its
  /// boxes; neither touches user files.
  Future<void> clearAllData();

  /// Deletes every persisted chat row **without** resetting the installation
  /// or writing the `legacy_import_disabled` sentinel. Backup restore uses
  /// this so a routine restore never blocks the legacy import path.
  Future<void> clearAllRows();

  /// Reclaims free pages (`VACUUM` for SQLite). The Hive backend is a no-op.
  Future<void> optimize();
}
