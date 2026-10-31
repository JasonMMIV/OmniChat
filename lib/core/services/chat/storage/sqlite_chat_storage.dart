import 'dart:io';

import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import '../../../models/file_record.dart';
import '../../../models/workspace_config.dart';
import 'app_database.dart';
import 'chat_database_files.dart';
import 'chat_maintenance_lock.dart';
import 'chat_repository.dart';
import 'chat_storage.dart';
import 'database_installation_gate.dart';
import 'message_part_codec.dart';

/// SQLite-backed [ChatStorage] backed by `ChatRepository` (§9.2).
///
/// Startup loads conversation metadata, file records, workspace bindings, and
/// Gemini signatures. Message bodies and tool parts are loaded per conversation
/// by [ensureConversationLoaded]; [getMessages] and [getToolEvents] fail closed
/// for anything never loaded. Full-history operations call
/// [ensureAllMessagesLoaded].
///
/// Every write updates the repository and the in-memory cache in the same
/// operation, so the synchronous read API never observes a stale row.
class SqliteChatStorage extends ChatStorage {
  SqliteChatStorage({
    required this.directory,
    required this.appVersion,
    this.background = true,
  }) : files = ChatDatabaseFiles(directory);

  final Directory directory;
  final String appVersion;
  final bool background;
  final ChatDatabaseFiles files;

  late AppDatabase _db;
  late ChatRepository _repo;
  bool _initialized = false;

  final Map<String, Conversation> _conversations = <String, Conversation>{};
  final Map<String, List<ChatMessage>> _messages =
      <String, List<ChatMessage>>{};
  final Set<String> _loadedMessageConversations = <String>{};
  final Map<String, ChatMessage> _messageById = <String, ChatMessage>{};
  final Map<String, List<FileRecord>> _fileRecords =
      <String, List<FileRecord>>{};
  final Map<String, WorkspaceConfig> _workspaceConfigs =
      <String, WorkspaceConfig>{};
  final Map<String, String> _signatures = <String, String>{};
  final Map<String, List<Map<String, dynamic>>> _toolEvents =
      <String, List<Map<String, dynamic>>>{};
  final Set<String> _loadedToolEventMessages = <String>{};
  final Map<String, List<ToolPartSummary>> _toolSummaries =
      <String, List<ToolPartSummary>>{};
  final Set<String> _loadedSummaryMessages = <String>{};

  @override
  ChatStorageBackend get backend => ChatStorageBackend.sqlite;

  ChatRepository get repository => _repo;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _db = AppDatabase.open(files.database, background: background);
    await _db.verifyHealthy();
    _repo = ChatRepository(_db);

    // A process kill between the streaming placeholder and its finish write
    // leaves `is_streaming = 1`; at startup no stream owns any row. The SQLite
    // equivalent also interrupts result-less parts, never a pending approval.
    await _repo.repairStaleStreaming();

    await _reloadAll();
    _initialized = true;
  }

  @override
  Future<void> dispose() async {
    if (!_initialized) return;
    _initialized = false;
    await _db.close();
  }

  /// Re-reads the startup cache after an explicit legacy re-import merged
  /// rows through [repository]. Tool bodies stay lazy.
  Future<void> refreshCache() async {
    if (!_initialized) return;
    final loaded = Set<String>.of(_loadedMessageConversations);
    await _reloadAll();
    for (final conversationId in loaded) {
      if (_conversations.containsKey(conversationId)) {
        await ensureConversationLoaded(conversationId);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  @override
  List<Conversation> listConversations() {
    final conversations = _conversations.values.toList();
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return conversations;
  }

  @override
  Conversation? getConversation(String id) => _conversations[id];

  @override
  List<ChatMessage> getMessages(String conversationId) {
    if (!_conversations.containsKey(conversationId)) {
      return const <ChatMessage>[];
    }
    if (_loadedMessageConversations.contains(conversationId)) {
      return _messages[conversationId] ?? const <ChatMessage>[];
    }
    throw ChatStorageNotLoadedException(
      'messages for conversation $conversationId',
    );
  }

  @override
  Iterable<ChatMessage> allMessages() sync* {
    for (final conversationId in _loadedMessageConversations) {
      yield* _messages[conversationId] ?? const <ChatMessage>[];
    }
  }

  @override
  bool get allMessagesLoaded {
    for (final conversationId in _conversations.keys) {
      if (!_loadedMessageConversations.contains(conversationId)) return false;
    }
    return true;
  }

  @override
  bool isConversationLoaded(String conversationId) =>
      _loadedMessageConversations.contains(conversationId);

  @override
  Future<Iterable<String>> attachmentBearingMessageContents() =>
      _repo.attachmentBearingMessageContents();

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) {
    if (!_loadedToolEventMessages.contains(assistantMessageId)) {
      throw ChatStorageNotLoadedException(
        'tool events for message $assistantMessageId',
      );
    }
    final events = _toolEvents[assistantMessageId];
    if (events == null) return const <Map<String, dynamic>>[];
    // Hand out fresh top-level maps (the Hive backend has always done this);
    // callers must not be able to mutate the cache in place.
    return [for (final event in events) Map<String, dynamic>.of(event)];
  }

  @override
  List<ToolPartSummary> getToolPartSummaries(String assistantMessageId) {
    if (!_loadedSummaryMessages.contains(assistantMessageId)) {
      throw ChatStorageNotLoadedException(
        'tool summaries for message $assistantMessageId',
      );
    }
    return _toolSummaries[assistantMessageId] ?? const <ToolPartSummary>[];
  }

  @override
  Future<Map<String, dynamic>?> loadToolEventDetail({
    required String assistantMessageId,
    required String toolCallId,
  }) async {
    final detail = await _repo.loadToolEventDetail(
      assistantMessageId: assistantMessageId,
      toolCallId: toolCallId,
    );
    if (detail == null) return null;
    // If the message's full event list is already cached, keep it in sync so a
    // second expand or a copy action does not re-read the row. An unloaded
    // message stays unloaded: one detail must not mark the whole list loaded.
    final cached = _toolEvents[assistantMessageId];
    if (cached != null) {
      final index = cached.indexWhere(
        (event) => (event['id']?.toString() ?? '') == toolCallId,
      );
      if (index >= 0) cached[index] = detail;
    }
    return detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getSearchCitations(
    String assistantMessageId,
  ) => _repo.getSearchCitations(assistantMessageId);

  @override
  String? getGeminiThoughtSignature(String assistantMessageId) =>
      _signatures[assistantMessageId];

  @override
  List<FileRecord> getFileRecords(String messageId) =>
      _fileRecords[messageId] ?? const <FileRecord>[];

  @override
  WorkspaceConfig? getWorkspaceConfig(String conversationId) =>
      _workspaceConfigs[conversationId];

  // ---------------------------------------------------------------------------
  // Preloads
  // ---------------------------------------------------------------------------

  @override
  Future<void> ensureConversationLoaded(String conversationId) async {
    if (!_conversations.containsKey(conversationId)) return;
    if (!_loadedMessageConversations.contains(conversationId)) {
      await _reloadMessages(conversationId);
    }
    final messages = _messages[conversationId] ?? const <ChatMessage>[];
    final missing = <String>{
      for (final message in messages)
        if (message.role == 'assistant' &&
            !_loadedSummaryMessages.contains(message.id))
          message.id,
    };
    if (missing.isEmpty) return;
    final summaries = await _repo.getToolPartSummariesForMessages(missing);
    final grouped = <String, List<ToolPartSummary>>{};
    for (final summary in summaries) {
      (grouped[summary.messageId] ??= <ToolPartSummary>[]).add(summary);
    }
    for (final id in missing) {
      _toolSummaries[id] = grouped[id] ?? const <ToolPartSummary>[];
      _loadedSummaryMessages.add(id);
    }
  }

  @override
  Future<void> ensureToolEventsLoaded(Iterable<String> messageIds) async {
    final missing = <String>{
      for (final id in messageIds)
        if (id.isNotEmpty && !_loadedToolEventMessages.contains(id)) id,
    };
    if (missing.isEmpty) return;
    await _reloadToolEvents(missing);
  }

  @override
  Future<void> ensureAllMessagesLoaded() async {
    if (allMessagesLoaded) return;
    final messages = await _repo.allMessages();
    _messages.clear();
    _messageById.clear();
    _loadedMessageConversations.clear();
    for (final conversationId in _conversations.keys) {
      _messages[conversationId] = <ChatMessage>[];
      _loadedMessageConversations.add(conversationId);
    }
    for (final message in messages) {
      (_messages[message.conversationId] ??= <ChatMessage>[]).add(message);
      _messageById[message.id] = message;
    }
  }

  @override
  Future<void> ensureAllToolEventsLoaded() async {
    final ids = <String>{
      for (final messages in _messages.values)
        for (final message in messages)
          if (message.role == 'assistant' && message.id.isNotEmpty) message.id,
    };
    await ensureToolEventsLoaded(ids);
  }

  // ---------------------------------------------------------------------------
  // Conversation writes
  // ---------------------------------------------------------------------------

  @override
  Future<void> putConversation(Conversation conversation) async {
    final isNew = !_conversations.containsKey(conversation.id);
    await _repo.upsertConversation(conversation);
    _conversations[conversation.id] = conversation;
    if (isNew) {
      _messages[conversation.id] = <ChatMessage>[];
      _loadedMessageConversations.add(conversation.id);
    }
  }

  @override
  Future<void> deleteConversation(String id) async {
    await _repo.deleteConversation(id);
    _dropConversationCache(id);
  }

  @override
  Future<int> deleteConversations(Iterable<String> ids) async {
    final unique = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return 0;
    final deleted = await _repo.deleteConversations(unique);
    for (final id in unique) {
      _dropConversationCache(id);
    }
    return deleted;
  }

  @override
  Future<void> renameConversation(String id, String title) async {
    await _repo.renameConversation(id, title);
    final conversation = _conversations[id];
    if (conversation != null) {
      _conversations[id] = conversation.copyWith(
        title: title,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> setConversationPinned(String id, bool pinned) async {
    await _repo.setConversationPinned(id, pinned);
    final conversation = _conversations[id];
    if (conversation != null) {
      _conversations[id] = conversation.copyWith(isPinned: pinned);
    }
  }

  @override
  Future<void> setConversationSummary(
    String id,
    String? summary,
    int lastSummarizedMessageCount,
  ) async {
    await _repo.setConversationSummary(id, summary, lastSummarizedMessageCount);
    final conversation = _conversations[id];
    if (conversation != null) {
      _conversations[id] = conversation.copyWith(
        clearSummary: summary == null,
        summary: summary,
        lastSummarizedMessageCount: lastSummarizedMessageCount,
      );
    }
  }

  @override
  Future<void> setConversationAssistant(String id, String? assistantId) async {
    await _repo.setConversationAssistant(id, assistantId);
    final conversation = _conversations[id];
    if (conversation != null) {
      _conversations[id] = conversation.copyWith(
        assistantId: assistantId,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> setConversationMcpServers(
    String id,
    List<String> serverIds,
  ) async {
    await _repo.setConversationMcpServers(id, serverIds);
    final conversation = _conversations[id];
    if (conversation != null) {
      _conversations[id] = conversation.copyWith(
        mcpServerIds: List.of(serverIds),
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> setConversationIndexes(
    String id, {
    required int truncateIndex,
    required int compactBeforeIndex,
  }) async {
    await _repo.setConversationIndexes(
      id,
      truncateIndex: truncateIndex,
      compactBeforeIndex: compactBeforeIndex,
    );
    final conversation = _conversations[id];
    if (conversation != null) {
      _conversations[id] = conversation.copyWith(
        truncateIndex: truncateIndex,
        compactBeforeIndex: compactBeforeIndex,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> setVersionSelections(
    String id,
    Map<String, int> selections,
  ) async {
    await _repo.setVersionSelections(id, selections);
    final conversation = _conversations[id];
    if (conversation != null) {
      _conversations[id] = conversation.copyWith(
        versionSelections: Map<String, int>.from(selections),
        updatedAt: DateTime.now(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Message writes
  // ---------------------------------------------------------------------------

  @override
  Future<ChatMessage> appendMessage(
    ChatMessage message, {
    bool touchConversation = true,
  }) async {
    await _repo.appendMessage(message, touchConversation: touchConversation);
    final list = _messages[message.conversationId];
    if (list != null && !list.any((m) => m.id == message.id)) {
      list.add(message);
    }
    _messageById[message.id] = message;
    final conversation = _conversations[message.conversationId];
    if (conversation != null) {
      final ids = List<String>.of(conversation.messageIds);
      if (!ids.contains(message.id)) ids.add(message.id);
      if (touchConversation) {
        _conversations[message.conversationId] = conversation.copyWith(
          messageIds: ids,
          updatedAt: DateTime.now(),
        );
      } else if (!ids.contains(message.id)) {
        _conversations[message.conversationId] = conversation.copyWith(
          messageIds: ids,
        );
      }
    } else {
      await _reloadConversation(message.conversationId);
    }
    _markToolEventsLoadedEmpty(message.id);
    return message;
  }

  @override
  Future<void> insertMessageAt(ChatMessage message, int ordinal) async {
    await _repo.insertMessageAt(message, ordinal);
    await _reloadMessages(message.conversationId);
    _loadedToolEventMessages.remove(message.id);
  }

  @override
  Future<void> addMessageDirectly(
    String conversationId,
    ChatMessage message,
  ) async {
    await _repo.appendMessage(message, touchConversation: false);
    final list = _messages[conversationId];
    if (list != null && !list.any((m) => m.id == message.id)) {
      list.add(message);
    }
    _messageById[message.id] = message;
    final conversation = _conversations[conversationId];
    if (conversation != null) {
      if (!conversation.messageIds.contains(message.id)) {
        _conversations[conversationId] = conversation.copyWith(
          messageIds: [...conversation.messageIds, message.id],
        );
      }
    }
    _markToolEventsLoadedEmpty(message.id);
  }

  @override
  Future<void> restoreConversation(
    Conversation conversation,
    List<ChatMessage> messages,
  ) async {
    await _repo.restoreConversation(conversation, messages);
    // Drop cache entries for rows the restore replaced/deleted.
    final previous = _messages[conversation.id];
    if (previous != null) {
      for (final message in previous) {
        _messageById.remove(message.id);
        _toolEvents.remove(message.id);
        _loadedToolEventMessages.remove(message.id);
        _toolSummaries.remove(message.id);
        _loadedSummaryMessages.remove(message.id);
        _fileRecords.remove(message.id);
        _signatures.remove(message.id);
      }
    }
    _conversations[conversation.id] =
        await _repo.getConversation(conversation.id) ??
        conversation.copyWith(messageIds: messages.map((m) => m.id).toList());
    _messages[conversation.id] = List.of(messages);
    _loadedMessageConversations.add(conversation.id);
    for (final message in messages) {
      _messageById[message.id] = message;
      _loadedToolEventMessages.remove(message.id);
    }
  }

  @override
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
    await _repo.updateMessage(
      messageId,
      content: content,
      totalTokens: totalTokens,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      processFinishedAt: processFinishedAt,
      processStartedAt: processStartedAt,
      translation: translation,
      reasoningSegmentsJson: reasoningSegmentsJson,
      aiTeamProposalsJson: aiTeamProposalsJson,
    );

    final cached = _messageById[messageId];
    if (cached != null) {
      final messages = _messages[cached.conversationId];
      final index = messages?.indexWhere((m) => m.id == messageId) ?? -1;
      if (messages != null && index >= 0) {
        final message = messages[index];
        messages[index] = message.copyWith(
          content: content ?? message.content,
          totalTokens: totalTokens ?? message.totalTokens,
          promptTokens: promptTokens ?? message.promptTokens,
          completionTokens: completionTokens ?? message.completionTokens,
          cachedTokens: cachedTokens ?? message.cachedTokens,
          isStreaming: isStreaming ?? message.isStreaming,
          reasoningText: reasoningText ?? message.reasoningText,
          reasoningStartAt: reasoningStartAt ?? message.reasoningStartAt,
          reasoningFinishedAt:
              reasoningFinishedAt ?? message.reasoningFinishedAt,
          processFinishedAt: processFinishedAt ?? message.processFinishedAt,
          processStartedAt: processStartedAt ?? message.processStartedAt,
          translation: translation ?? message.translation,
          reasoningSegmentsJson:
              reasoningSegmentsJson ?? message.reasoningSegmentsJson,
          aiTeamProposalsJson:
              aiTeamProposalsJson ?? message.aiTeamProposalsJson,
        );
        _messageById[messageId] = messages[index];
      }
    }
  }

  @override
  Future<bool> deleteMessage(String messageId) async {
    var removed = _messageById[messageId];
    removed ??= await _repo.getMessage(messageId);
    final deleted = await _repo.deleteMessage(messageId);
    if (!deleted) return false;
    if (removed != null) {
      final conversationId = removed.conversationId;
      if (_loadedMessageConversations.contains(conversationId)) {
        await _reloadMessages(conversationId);
      } else {
        final conversation = await _repo.getConversation(conversationId);
        if (conversation != null) {
          _conversations[conversationId] = conversation;
        }
      }
    }
    _messageById.remove(messageId);
    _toolEvents.remove(messageId);
    _loadedToolEventMessages.remove(messageId);
    _fileRecords.remove(messageId);
    _signatures.remove(messageId);
    return true;
  }

  @override
  Future<ChatMessage?> appendMessageVersion({
    required String messageId,
    required String content,
  }) async {
    final original = _messageById[messageId];
    if (original == null) return null;

    final conversation = _conversations[original.conversationId];
    if (conversation == null) return null;

    final groupId = original.groupId ?? original.id;
    var maxVersion = -1;
    for (final message
        in _messages[original.conversationId] ?? const <ChatMessage>[]) {
      if ((message.groupId ?? message.id) == groupId &&
          message.version > maxVersion) {
        maxVersion = message.version;
      }
    }

    final newMessage = ChatMessage(
      role: original.role,
      content: content,
      conversationId: original.conversationId,
      modelId: original.modelId,
      providerId: original.providerId,
      totalTokens: null,
      isStreaming: false,
      groupId: groupId,
      version: maxVersion + 1,
    );

    await _repo.appendMessageVersion(groupId: groupId, message: newMessage);
    final list = _messages[original.conversationId];
    if (list != null) list.add(newMessage);
    _messageById[newMessage.id] = newMessage;
    _conversations[original.conversationId] = conversation.copyWith(
      messageIds: [...conversation.messageIds, newMessage.id],
      versionSelections: {
        ...conversation.versionSelections,
        groupId: newMessage.version,
      },
      updatedAt: DateTime.now(),
    );
    _markToolEventsLoadedEmpty(newMessage.id);
    return newMessage;
  }

  // ---------------------------------------------------------------------------
  // Tool parts / artifacts
  // ---------------------------------------------------------------------------

  @override
  Future<void> setToolEvents(
    String assistantMessageId,
    List<Map<String, dynamic>> events,
  ) async {
    // During a live turn the assistant row is streaming and a result-less
    // placeholder is still pending. A restored/migrated history is not
    // streaming: an approved/auto part without a result was interrupted.
    final live = _findCachedMessage(assistantMessageId)?.isStreaming ?? false;
    final drafts = <ToolPartDraft>[];
    for (final event in events) {
      final draft = toolPartDraftFromLegacyEvent(event);
      drafts.add(
        live
            ? ToolPartDraft(
                toolCallId: draft.toolCallId,
                toolName: draft.toolName,
                argumentsJson: draft.argumentsJson,
                content: draft.content,
                approvalState: draft.approvalState,
                status: deriveRuntimeToolPartStatus(
                  approvalState: draft.approvalState,
                  content: draft.content,
                ),
                metadataJson: draft.metadataJson,
              )
            : draft,
      );
    }
    await _repo.replaceToolEvents(assistantMessageId, drafts);
    await _reloadToolEvents([assistantMessageId]);
  }

  @override
  Future<void> upsertToolEvent(
    String assistantMessageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    String? approvalState,
    Map<String, dynamic>? extras,
  }) async {
    await _repo.upsertToolEvent(
      assistantMessageId: assistantMessageId,
      id: id,
      name: name,
      arguments: arguments,
      content: content,
      approvalState: approvalState,
      extras: extras,
    );
    await _reloadToolEvents([assistantMessageId]);
  }

  @override
  Future<bool> setToolEventApprovalState(
    String assistantMessageId, {
    required String id,
    required String approvalState,
    String? content,
  }) async {
    // The approval path can supply a result (approve) or a denial message;
    // apply the same file_read persisted-preview policy as the other writers.
    String? boundedContent = content;
    if (content != null && id.trim().isNotEmpty) {
      final detail = await _repo.loadToolEventDetail(
        assistantMessageId: assistantMessageId,
        toolCallId: id,
      );
      boundedContent = boundPersistedToolResult(
        detail?['name']?.toString() ?? '',
        content,
      );
    }
    final updated = await _repo.setToolEventApprovalState(
      assistantMessageId: assistantMessageId,
      id: id,
      approvalState: approvalState,
      content: boundedContent,
    );
    if (!updated) return false;
    await _reloadToolEvents([assistantMessageId]);
    return true;
  }

  @override
  Future<void> setGeminiThoughtSignature(
    String assistantMessageId,
    String signature,
  ) async {
    await _repo.setProviderArtifact(
      assistantMessageId,
      kGeminiThoughtSignatureKind,
      signature,
    );
    _signatures[assistantMessageId] = signature;
  }

  @override
  Future<void> removeGeminiThoughtSignature(String assistantMessageId) async {
    await _repo.deleteProviderArtifact(
      assistantMessageId,
      kGeminiThoughtSignatureKind,
    );
    _signatures.remove(assistantMessageId);
  }

  @override
  Future<void> addFileRecord(String messageId, FileRecord record) async {
    await _repo.upsertFileRecord(messageId, record);
    final records = List<FileRecord>.of(getFileRecords(messageId))
      ..removeWhere((item) => item.path == record.path)
      ..add(record);
    _fileRecords[messageId] = records;
  }

  @override
  Future<void> setWorkspaceConfig(
    String conversationId,
    WorkspaceConfig? config,
  ) async {
    if (config == null || config.mode == WorkspaceMode.inheritProject) {
      await _repo.deleteWorkspaceBinding(conversationId);
      _workspaceConfigs.remove(conversationId);
      return;
    }
    await _repo.setWorkspaceBinding(conversationId, config);
    _workspaceConfigs[conversationId] = config;
  }

  // ---------------------------------------------------------------------------
  // Fork / reset
  // ---------------------------------------------------------------------------

  @override
  Future<Conversation> forkConversation({
    required String title,
    required String? assistantId,
    required List<ChatMessage> sourceMessages,
    Map<String, int>? versionSelections,
  }) async {
    final conversation = await _repo.forkConversation(
      title: title,
      assistantId: assistantId,
      sourceMessages: sourceMessages,
      versionSelections: versionSelections,
    );
    _conversations[conversation.id] = conversation;
    final cloned = await _repo.getMessages(conversation.id);
    _messages[conversation.id] = cloned;
    for (final message in cloned) {
      _messageById[message.id] = message;
    }

    for (var i = 0; i < sourceMessages.length && i < cloned.length; i++) {
      final records = getFileRecords(sourceMessages[i].id);
      if (records.isNotEmpty) {
        _fileRecords[cloned[i].id] = List<FileRecord>.of(records);
      }
    }
    // The fork copies parts, so the new conversation must be usable
    // immediately (the UI switches to it without a reload).
    await ensureConversationLoaded(conversation.id);
    return conversation;
  }

  @override
  Future<void> optimize() async {
    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'vacuum',
    );
    try {
      await _db.checkpointAndTruncate();
      await _db.customStatement('VACUUM');
      await _db.checkpointAndTruncate();
      await _reloadAll();
    } finally {
      await lock.release();
    }
  }

  @override
  Future<void> clearAllRows() async {
    await _db.transaction(() async {
      // Cascades messages, parts, artifacts, file records, and bindings.
      await _db.delete(_db.conversationRows).go();
    });
    await _reloadAll();
  }

  @override
  Future<void> clearAllData() async {
    await _db.close();
    _initialized = false;
    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'clear-all-data',
    );
    try {
      // §8.10: write the reset marker before deleting anything. The marker
      // means "never import Hive"; the installation gate owns the deletion and
      // the post-reset empty database.
      await files.writeJsonAtomically(files.resetMarker, <String, dynamic>{
        'format': 1,
        'requestedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'databaseId': (await probeDatabase(files.database)).databaseId,
      });
      final result = await DatabaseInstallationGate(
        directory: directory,
        appVersion: appVersion,
      ).ensureReady();
      if (!result.isReady) {
        throw StateError('Chat storage reset failed: ${result.message}');
      }
      await _openAndLoad();
    } catch (_) {
      // Never leave a populated cache over a closed/deleted database. Try to
      // reopen; if that also fails the facade is marked uninitialized so the
      // next init() re-runs admission instead of serving stale rows.
      try {
        await _openAndLoad();
      } catch (_) {
        _initialized = false;
      }
      rethrow;
    } finally {
      await lock.release();
    }
  }

  Future<void> _openAndLoad() async {
    _db = AppDatabase.open(files.database, background: background);
    await _db.verifyHealthy();
    _repo = ChatRepository(_db);
    await _reloadAll();
    _initialized = true;
  }

  // ---------------------------------------------------------------------------
  // Cache internals
  // ---------------------------------------------------------------------------

  Future<void> _reloadAll() async {
    _conversations.clear();
    _messages.clear();
    _loadedMessageConversations.clear();
    _messageById.clear();
    _fileRecords.clear();
    _workspaceConfigs.clear();
    _signatures.clear();
    _toolEvents.clear();
    _loadedToolEventMessages.clear();
    _toolSummaries.clear();
    _loadedSummaryMessages.clear();

    final conversations = await _repo.listConversations();
    for (final conversation in conversations) {
      _conversations[conversation.id] = conversation;
    }

    _fileRecords.addAll(await _repo.allFileRecordsGrouped());
    _workspaceConfigs.addAll(await _repo.allWorkspaceBindings());
    _signatures.addAll(
      await _repo.allProviderArtifactsOfKind(kGeminiThoughtSignatureKind),
    );
  }

  Future<void> _reloadConversation(String conversationId) async {
    final conversation = await _repo.getConversation(conversationId);
    if (conversation == null) {
      _conversations.remove(conversationId);
      _messages.remove(conversationId);
      return;
    }
    _conversations[conversationId] = conversation;
    await _reloadMessages(conversationId);
  }

  Future<void> _reloadMessages(String conversationId) async {
    final previous = _messages[conversationId];
    if (previous != null) {
      for (final message in previous) {
        _messageById.remove(message.id);
        _toolEvents.remove(message.id);
        _loadedToolEventMessages.remove(message.id);
        _toolSummaries.remove(message.id);
        _loadedSummaryMessages.remove(message.id);
        _fileRecords.remove(message.id);
        _signatures.remove(message.id);
      }
    }
    final messages = await _repo.getMessages(conversationId);
    _messages[conversationId] = messages;
    _loadedMessageConversations.add(conversationId);
    for (final message in messages) {
      _messageById[message.id] = message;
    }
    final conversation = await _repo.getConversation(conversationId);
    if (conversation != null) {
      _conversations[conversationId] = conversation;
    }
  }

  Future<void> _reloadToolEvents(Iterable<String> messageIds) async {
    final ids = messageIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return;
    final parts = await _repo.allPartsBatch(ids);
    final byMessage = <String, List<MessagePartRow>>{};
    for (final part in parts) {
      (byMessage[part.messageId] ??= <MessagePartRow>[]).add(part);
    }
    for (final id in ids) {
      final rows = byMessage[id] ?? const <MessagePartRow>[];
      final events = <Map<String, dynamic>>[];
      final summaries = <ToolPartSummary>[];
      for (final row in rows) {
        if (row.kind != kToolPartKind) continue;
        final event = toolEventFromStoredPart(
          toolCallId: row.toolCallId,
          toolName: row.toolName,
          argumentsJson: row.argumentsJson,
          content: row.content,
          approvalState: row.approvalState ?? kApprovalAuto,
          metadataJson: row.metadataJson,
        );
        events.add(event);
        summaries.add(
          ToolPartSummary(
            partId: row.partId,
            messageId: id,
            ordinal: row.ordinal,
            toolCallId: row.toolCallId,
            toolName: row.toolName,
            approvalState: row.approvalState ?? kApprovalAuto,
            status: row.status,
            contentLengthChars: row.content?.length ?? 0,
            argumentsLengthChars: row.argumentsJson?.length ?? 0,
            argumentsPreview: (row.argumentsJson ?? '').length <= 256
                ? row.argumentsJson
                : row.argumentsJson!.substring(0, 256),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAtMs),
            eagerContent:
                (row.status == kPartStatusPending ||
                    row.status == kPartStatusDenied ||
                    row.toolName == 'ask_user')
                ? row.content
                : null,
            eagerArgumentsJson:
                (row.status == kPartStatusPending ||
                    row.status == kPartStatusDenied ||
                    (row.toolName != null &&
                        kEagerSummaryToolNames.contains(row.toolName)))
                ? row.argumentsJson
                : null,
            searchProvider: _metadataValue(row.metadataJson, 'searchProvider'),
            searchFallbackFrom: _metadataValue(
              row.metadataJson,
              'searchFallbackFrom',
            ),
            webFetchSource: _metadataValue(row.metadataJson, 'webFetchSource'),
          ),
        );
      }
      _toolEvents[id] = events;
      _loadedToolEventMessages.add(id);
      _toolSummaries[id] = summaries;
      _loadedSummaryMessages.add(id);
    }
  }

  String? _metadataValue(String? metadataJson, String key) {
    final map = decodeJsonMap(metadataJson);
    return map[key]?.toString();
  }

  ChatMessage? _findCachedMessage(String messageId) => _messageById[messageId];

  void _markToolEventsLoadedEmpty(String messageId) {
    _toolEvents.putIfAbsent(messageId, () => const <Map<String, dynamic>>[]);
    _loadedToolEventMessages.add(messageId);
    _toolSummaries.putIfAbsent(messageId, () => const <ToolPartSummary>[]);
    _loadedSummaryMessages.add(messageId);
  }

  void _dropConversationCache(String id) {
    _conversations.remove(id);
    _loadedMessageConversations.remove(id);
    final messages = _messages.remove(id);
    if (messages != null) {
      for (final message in messages) {
        _messageById.remove(message.id);
        _toolEvents.remove(message.id);
        _loadedToolEventMessages.remove(message.id);
        _toolSummaries.remove(message.id);
        _loadedSummaryMessages.remove(message.id);
        _fileRecords.remove(message.id);
        _signatures.remove(message.id);
      }
    }
    _workspaceConfigs.remove(id);
  }
}
