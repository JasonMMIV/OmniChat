import 'dart:convert';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';

import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import '../../../models/file_record.dart';
import '../../../models/workspace_config.dart';
import '../../../../utils/sandbox_path_resolver.dart';
import 'chat_storage.dart';
import 'hive_open_boundary.dart';
import 'message_part_codec.dart';

/// Legacy Hive backend. It is retained for one release as the fallback when
/// the SQLite installation/migration gate fails (§9.6) and for the existing
/// Hive persistence tests.
///
/// The behaviour is the pre-M3 `ChatService` storage code, minus
/// notifications and draft handling (both owned by the facade). Hive boxes are
/// opened eagerly here because this backend only runs when SQLite is not
/// authoritative; the Hive hot path is retired in M6.
class HiveChatStorage extends ChatStorage {
  HiveChatStorage({required this.directory});

  static const String conversationsBoxName = 'conversations';
  static const String messagesBoxName = 'messages';
  static const String toolEventsBoxName = 'tool_events_v1';
  static const String conversationWorkspacesBoxName =
      'conversation_workspaces_v1';
  static const String conversationWorkspaceBindingsBoxName =
      'conversation_workspace_bindings_v2';
  static const String messageFileRecordsBoxName = 'message_file_records_v1';
  static const String legacyMessageSnapshotsBoxName = 'message_snapshots_v1';

  final Directory directory;

  late Box<Conversation> _conversationsBox;
  late Box<ChatMessage> _messagesBox;
  late Box<dynamic> _toolEventsBox;
  late Box<dynamic> _conversationWorkspacesBox;
  late Box<dynamic> _conversationWorkspaceBindingsBox;
  late Box<dynamic> _messageFileRecordsBox;

  final Map<String, List<ChatMessage>> _messagesCache = {};
  final List<Future<void> Function()> _boxClosers = <Future<void> Function()>[];

  String _sigKey(String id) => 'sig_$id';

  @override
  ChatStorageBackend get backend => ChatStorageBackend.hive;

  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    Hive.init(directory.path);

    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ConversationAdapter());
    }

    _conversationsBox = await _openBoxSafely<Conversation>(
      conversationsBoxName,
    );
    _boxClosers.add(_conversationsBox.close);
    _messagesBox = await _openBoxSafely<ChatMessage>(messagesBoxName);
    _boxClosers.add(_messagesBox.close);
    _toolEventsBox = await _openBoxSafely<dynamic>(toolEventsBoxName);
    _boxClosers.add(_toolEventsBox.close);
    _conversationWorkspacesBox = await _openBoxSafely<dynamic>(
      conversationWorkspacesBoxName,
    );
    _boxClosers.add(_conversationWorkspacesBox.close);
    _conversationWorkspaceBindingsBox = await _openBoxSafely<dynamic>(
      conversationWorkspaceBindingsBoxName,
    );
    _boxClosers.add(_conversationWorkspaceBindingsBox.close);
    _messageFileRecordsBox = await _openBoxSafely<dynamic>(
      messageFileRecordsBoxName,
    );
    _boxClosers.add(_messageFileRecordsBox.close);

    // P1-5 removed 2026-09-10: sweep the orphaned snapshot-record box from
    // disk. Workspace snapshot zips are user-owned files and are left as-is.
    try {
      await Hive.deleteBoxFromDisk(legacyMessageSnapshotsBoxName);
    } catch (_) {}

    await _migrateConversationWorkspaceBindings();
    await _migrateSandboxPaths();
    await _repairStaleStreaming();
    _initialized = true;
  }

  @override
  Future<void> dispose() async {
    _messagesCache.clear();
    _initialized = false;
    // Release the box locks so the migration importer (or a later fallback)
    // can open the same files. Track closers as boxes open, so a failed
    // initialization still releases everything opened before the failure.
    final closers = List<Future<void> Function()>.of(_boxClosers);
    _boxClosers.clear();
    for (final close in closers) {
      try {
        await close();
      } catch (_) {}
    }
  }

  Future<Box<T>> _openBoxSafely<T>(String name) async {
    final outcome = await HiveOpenBoundary.run<Box<T>>(
      () => Hive.openBox<T>(name),
    );
    if (!outcome.succeeded) {
      final opened = outcome.value;
      if (opened != null) {
        try {
          await opened.close();
        } catch (_) {}
      }
      throw HiveOpenException(name, outcome.primaryError);
    }
    return outcome.value!;
  }

  Future<void> _migrateConversationWorkspaceBindings() async {
    for (final key in _conversationWorkspacesBox.keys) {
      if (_conversationWorkspaceBindingsBox.containsKey(key)) continue;
      final raw = _conversationWorkspacesBox.get(key);
      if (raw is String && raw.trim().isNotEmpty) {
        await _conversationWorkspaceBindingsBox.put(
          key,
          WorkspaceConfig.custom(raw.trim()).toJson(),
        );
      }
    }
  }

  Future<void> _migrateSandboxPaths() async {
    try {
      if (_messagesBox.isEmpty) return;
      final imgRe = RegExp(r'\[image:(.+?)\]');
      final fileRe = RegExp(r'\[file:(.+?)\|(.+?)\|(.+?)\]');

      for (final key in _messagesBox.keys) {
        final msg = _messagesBox.get(key);
        if (msg == null) continue;
        final content = msg.content;
        String updated = content;
        var changed = false;

        updated = updated.replaceAllMapped(imgRe, (m) {
          final raw = (m.group(1) ?? '').trim();
          final fixed = SandboxPathResolver.fix(raw);
          if (fixed != raw) changed = true;
          return '[image:$fixed]';
        });

        updated = updated.replaceAllMapped(fileRe, (m) {
          final raw = (m.group(1) ?? '').trim();
          final name = (m.group(2) ?? '').trim();
          final mime = (m.group(3) ?? '').trim();
          final fixed = SandboxPathResolver.fix(raw);
          if (fixed != raw) changed = true;
          return '[file:$fixed|$name|$mime]';
        });

        if (changed && updated != content) {
          await _messagesBox.put(msg.id, msg.copyWith(content: updated));
        }
      }
    } catch (_) {
      // best-effort migration; ignore errors
    }
  }

  Future<void> _repairStaleStreaming() async {
    try {
      final updates = <dynamic, ChatMessage>{};
      for (final key in _messagesBox.keys.toList()) {
        try {
          final message = _messagesBox.get(key);
          if (message == null || !message.isStreaming) continue;
          updates[key] = message.copyWith(isStreaming: false);
        } catch (_) {
          // One corrupt row must not abort the sweep.
        }
      }
      if (updates.isNotEmpty) {
        await _messagesBox.putAll(updates);
      }
    } catch (_) {}
  }

  @override
  List<Conversation> listConversations() {
    final conversations = _conversationsBox.values.toList();
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return conversations;
  }

  @override
  Conversation? getConversation(String id) => _conversationsBox.get(id);

  @override
  List<ChatMessage> getMessages(String conversationId) {
    final cached = _messagesCache[conversationId];
    if (cached != null) return cached;

    final conversation = _conversationsBox.get(conversationId);
    if (conversation == null) return const <ChatMessage>[];

    final messages = <ChatMessage>[];
    for (final messageId in conversation.messageIds) {
      final message = _messagesBox.get(messageId);
      if (message != null) messages.add(message);
    }
    _messagesCache[conversationId] = messages;
    return messages;
  }

  @override
  Iterable<ChatMessage> allMessages() => _messagesBox.values;

  @override
  bool get allMessagesLoaded => true;

  @override
  bool isConversationLoaded(String conversationId) =>
      getConversation(conversationId) != null;

  @override
  Future<Iterable<String>> attachmentBearingMessageContents() async => [
    for (final message in _messagesBox.values)
      if (message.content.contains('[image:') ||
          message.content.contains('[file:'))
        message.content,
  ];

  @override
  Future<void> ensureConversationLoaded(String conversationId) async {}

  @override
  Future<void> ensureAllMessagesLoaded() async {}

  @override
  Future<void> ensureToolEventsLoaded(Iterable<String> messageIds) async {}

  @override
  Future<void> ensureAllToolEventsLoaded() async {}

  @override
  List<ToolPartSummary> getToolPartSummaries(String assistantMessageId) {
    final events = getToolEvents(assistantMessageId);
    return [
      for (var i = 0; i < events.length; i++)
        toolPartSummaryFromEvent(
          event: events[i],
          messageId: assistantMessageId,
          ordinal: i,
        ),
    ];
  }

  @override
  Future<Map<String, dynamic>?> loadToolEventDetail({
    required String assistantMessageId,
    required String toolCallId,
  }) async {
    for (final event in getToolEvents(assistantMessageId)) {
      if ((event['id']?.toString() ?? '') == toolCallId) {
        return Map<String, dynamic>.of(event);
      }
    }
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> getSearchCitations(
    String assistantMessageId,
  ) async {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    final events = getToolEvents(assistantMessageId);
    for (var i = events.length - 1; i >= 0; i--) {
      final event = events[i];
      final name = event['name']?.toString() ?? '';
      if (name != 'search_web' && name != 'builtin_search') continue;
      final content = event['content']?.toString();
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

  @override
  Future<void> putConversation(Conversation conversation) async {
    await _conversationsBox.put(conversation.id, conversation);
    _messagesCache.putIfAbsent(conversation.id, () => <ChatMessage>[]);
  }

  @override
  Future<void> deleteConversation(String id) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;

    for (final messageId in conversation.messageIds) {
      final msg = _messagesBox.get(messageId);
      if (msg != null && msg.role == 'assistant') {
        try {
          await _toolEventsBox.delete(msg.id);
        } catch (_) {}
        try {
          await _toolEventsBox.delete(_sigKey(msg.id));
        } catch (_) {}
      }
      try {
        await _messageFileRecordsBox.delete(messageId);
      } catch (_) {}
      await _messagesBox.delete(messageId);
    }

    await _conversationsBox.delete(id);
    await _conversationWorkspacesBox.delete(id);
    await _conversationWorkspaceBindingsBox.delete(id);
    _messagesCache.remove(id);
  }

  @override
  Future<int> deleteConversations(Iterable<String> ids) async {
    var count = 0;
    final seen = <String>{};
    for (final id in ids) {
      if (id.isEmpty || !seen.add(id)) continue;
      final existed = _conversationsBox.containsKey(id);
      await deleteConversation(id);
      if (existed) count++;
    }
    return count;
  }

  @override
  Future<void> renameConversation(String id, String title) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;
    conversation.title = title;
    conversation.updatedAt = DateTime.now();
    await conversation.save();
  }

  @override
  Future<void> setConversationPinned(String id, bool pinned) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;
    conversation.isPinned = pinned;
    await conversation.save();
  }

  @override
  Future<void> setConversationSummary(
    String id,
    String? summary,
    int lastSummarizedMessageCount,
  ) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;
    conversation.summary = summary;
    conversation.lastSummarizedMessageCount = lastSummarizedMessageCount;
    await conversation.save();
  }

  @override
  Future<void> setConversationAssistant(String id, String? assistantId) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;
    conversation.assistantId = assistantId;
    conversation.updatedAt = DateTime.now();
    await conversation.save();
  }

  @override
  Future<void> setConversationMcpServers(
    String id,
    List<String> serverIds,
  ) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;
    conversation.mcpServerIds = List.of(serverIds);
    conversation.updatedAt = DateTime.now();
    await conversation.save();
  }

  @override
  Future<void> setConversationIndexes(
    String id, {
    required int truncateIndex,
    required int compactBeforeIndex,
  }) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;
    conversation.truncateIndex = truncateIndex;
    conversation.compactBeforeIndex = compactBeforeIndex;
    conversation.updatedAt = DateTime.now();
    await conversation.save();
  }

  @override
  Future<void> setVersionSelections(
    String id,
    Map<String, int> selections,
  ) async {
    final conversation = _conversationsBox.get(id);
    if (conversation == null) return;
    conversation.versionSelections = Map<String, int>.from(selections);
    conversation.updatedAt = DateTime.now();
    await conversation.save();
  }

  @override
  Future<ChatMessage> appendMessage(
    ChatMessage message, {
    bool touchConversation = true,
  }) async {
    await _messagesBox.put(message.id, message);

    final conversation = _conversationsBox.get(message.conversationId);
    if (conversation != null) {
      if (!conversation.messageIds.contains(message.id)) {
        conversation.messageIds.add(message.id);
      }
      if (touchConversation) conversation.updatedAt = DateTime.now();
      await conversation.save();
    }

    final cached = _messagesCache[message.conversationId];
    if (cached != null && !cached.any((m) => m.id == message.id)) {
      cached.add(message);
    }
    return message;
  }

  @override
  Future<void> insertMessageAt(ChatMessage message, int ordinal) async {
    await _messagesBox.put(message.id, message);
    final cached = _messagesCache[message.conversationId];
    if (cached != null) {
      cached.removeWhere((m) => m.id == message.id);
      final index = ordinal.clamp(0, cached.length);
      cached.insert(index, message);
    }
  }

  @override
  Future<void> addMessageDirectly(
    String conversationId,
    ChatMessage message,
  ) async {
    await _messagesBox.put(message.id, message);

    final conversation = _conversationsBox.get(conversationId);
    if (conversation != null) {
      if (!conversation.messageIds.contains(message.id)) {
        conversation.messageIds.add(message.id);
        // Keep original updatedAt during restore.
        await conversation.save();
      }
    }

    final cached = _messagesCache[conversationId];
    if (cached != null && !cached.any((m) => m.id == message.id)) {
      cached.add(message);
    }
  }

  @override
  Future<void> restoreConversation(
    Conversation conversation,
    List<ChatMessage> messages,
  ) async {
    final ids = messages.map((m) => m.id).toList();
    final keep = ids.toSet();
    // Match the SQLite backend: a restore replaces the conversation's message
    // list, so rows no longer present are removed instead of lingering as
    // unreachable Hive entries.
    final previous = _conversationsBox.get(conversation.id);
    if (previous != null) {
      for (final oldId in previous.messageIds) {
        if (keep.contains(oldId)) continue;
        final old = _messagesBox.get(oldId);
        if (old != null && old.role == 'assistant') {
          try {
            await _toolEventsBox.delete(oldId);
          } catch (_) {}
          try {
            await _toolEventsBox.delete(_sigKey(oldId));
          } catch (_) {}
        }
        try {
          await _messageFileRecordsBox.delete(oldId);
        } catch (_) {}
        await _messagesBox.delete(oldId);
      }
    }
    for (final message in messages) {
      await _messagesBox.put(message.id, message);
    }
    final restored = Conversation(
      id: conversation.id,
      title: conversation.title,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      messageIds: ids,
      isPinned: conversation.isPinned,
      mcpServerIds: List.of(conversation.mcpServerIds),
      truncateIndex: conversation.truncateIndex,
      assistantId: conversation.assistantId,
      versionSelections: Map<String, int>.from(conversation.versionSelections),
      compactBeforeIndex: conversation.compactBeforeIndex,
    );
    await _conversationsBox.put(restored.id, restored);
    _messagesCache[restored.id] = List.of(messages);
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
    final message = _messagesBox.get(messageId);
    if (message == null) return;

    final updated = message.copyWith(
      content: content ?? message.content,
      totalTokens: totalTokens ?? message.totalTokens,
      promptTokens: promptTokens ?? message.promptTokens,
      completionTokens: completionTokens ?? message.completionTokens,
      cachedTokens: cachedTokens ?? message.cachedTokens,
      isStreaming: isStreaming ?? message.isStreaming,
      reasoningText: reasoningText ?? message.reasoningText,
      reasoningStartAt: reasoningStartAt ?? message.reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt ?? message.reasoningFinishedAt,
      processFinishedAt: processFinishedAt ?? message.processFinishedAt,
      processStartedAt: processStartedAt ?? message.processStartedAt,
      translation: translation,
      reasoningSegmentsJson:
          reasoningSegmentsJson ?? message.reasoningSegmentsJson,
      aiTeamProposalsJson: aiTeamProposalsJson ?? message.aiTeamProposalsJson,
    );

    await _messagesBox.put(messageId, updated);

    final cached = _messagesCache[message.conversationId];
    if (cached != null) {
      final index = cached.indexWhere((m) => m.id == messageId);
      if (index != -1) cached[index] = updated;
    }
  }

  @override
  Future<bool> deleteMessage(String messageId) async {
    final message = _messagesBox.get(messageId);
    if (message == null) return false;

    final conversation = _conversationsBox.get(message.conversationId);
    if (conversation != null) {
      final gid = message.groupId ?? message.id;
      final ids = conversation.messageIds;
      final removedIndex = ids.indexOf(messageId);
      ids.remove(messageId);

      if (removedIndex >= 0) {
        String? replacementId;
        for (final mid in ids.skip(removedIndex)) {
          if (mid == messageId) continue;
          final candidate = _messagesBox.get(mid);
          if (candidate == null) continue;
          if ((candidate.groupId ?? candidate.id) == gid) {
            replacementId = mid;
            break;
          }
        }
        if (replacementId != null) {
          ids.remove(replacementId);
          final insertAt = removedIndex <= ids.length
              ? removedIndex
              : ids.length;
          ids.insert(insertAt, replacementId);
        }
      }

      await conversation.save();
    }

    await _messagesBox.delete(messageId);
    if (message.role == 'assistant') {
      try {
        await _toolEventsBox.delete(message.id);
      } catch (_) {}
      try {
        await _toolEventsBox.delete(_sigKey(message.id));
      } catch (_) {}
    }
    try {
      await _messageFileRecordsBox.delete(messageId);
    } catch (_) {}

    _messagesCache.remove(message.conversationId);
    return true;
  }

  @override
  Future<ChatMessage?> appendMessageVersion({
    required String messageId,
    required String content,
  }) async {
    final original = _messagesBox.get(messageId);
    if (original == null) return null;

    final cid = original.conversationId;
    final conversation = _conversationsBox.get(cid);
    if (conversation == null) return null;

    final gid = original.groupId ?? original.id;
    var maxVersion = -1;
    for (final mid in conversation.messageIds) {
      final m = _messagesBox.get(mid);
      if (m == null) continue;
      if ((m.groupId ?? m.id) == gid && m.version > maxVersion) {
        maxVersion = m.version;
      }
    }
    final nextVersion = maxVersion + 1;

    final newMessage = ChatMessage(
      role: original.role,
      content: content,
      conversationId: cid,
      modelId: original.modelId,
      providerId: original.providerId,
      totalTokens: null,
      isStreaming: false,
      groupId: gid,
      version: nextVersion,
    );
    await _messagesBox.put(newMessage.id, newMessage);

    conversation.messageIds.add(newMessage.id);
    conversation.updatedAt = DateTime.now();
    conversation.versionSelections[gid] = nextVersion;
    await conversation.save();

    final cached = _messagesCache[cid];
    if (cached != null) cached.add(newMessage);
    return newMessage;
  }

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) {
    final value = _toolEventsBox.get(assistantMessageId);
    if (value is List) {
      return value
          .whereType<Map>()
          .map(
            (event) => boundPersistedToolEvent(
              event.map((k, v) => MapEntry(k.toString(), v)),
            ),
          )
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  @override
  Future<void> setToolEvents(
    String assistantMessageId,
    List<Map<String, dynamic>> events,
  ) async {
    await _toolEventsBox.put(
      assistantMessageId,
      events.map(boundPersistedToolEvent).toList(),
    );
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
    final list = List<Map<String, dynamic>>.of(
      getToolEvents(assistantMessageId),
    );
    final cleanId = id.toString();

    var index = -1;
    if (cleanId.isNotEmpty) {
      index = list.indexWhere((e) => (e['id']?.toString() ?? '') == cleanId);
    }
    if (index < 0) {
      index = list.indexWhere(
        (e) =>
            (e['name']?.toString() ?? '') == name &&
            (e['content'] == null ||
                (e['content']?.toString().isEmpty ?? true)),
      );
    }

    final resolvedId = (cleanId.isEmpty && index >= 0)
        ? (list[index]['id']?.toString() ?? '')
        : cleanId;
    final existingApprovalState = _existingApprovalState(list, index);
    final mergedExtras = <String, dynamic>{
      ..._existingToolEventExtras(list, index),
      if (extras != null)
        for (final key in kPreservedToolEventExtraKeys)
          if (extras[key] != null) key: extras[key],
    };
    final record = <String, dynamic>{
      'id': resolvedId,
      'name': name,
      'arguments': arguments,
      'content': boundPersistedToolResult(name, content),
      'approvalState': approvalState ?? existingApprovalState,
      ...mergedExtras,
    };
    if (index >= 0) {
      list[index] = record;
    } else {
      list.add(record);
    }
    await _toolEventsBox.put(assistantMessageId, list);
  }

  @override
  Future<bool> setToolEventApprovalState(
    String assistantMessageId, {
    required String id,
    required String approvalState,
    String? content,
  }) async {
    final list = List<Map<String, dynamic>>.of(
      getToolEvents(assistantMessageId),
    );
    final index = list.indexWhere((e) => (e['id']?.toString() ?? '') == id);
    if (index < 0) return false;
    final updated = Map<String, dynamic>.of(list[index]);
    updated['approvalState'] = approvalState;
    if (content != null) {
      updated['content'] = boundPersistedToolResult(
        updated['name']?.toString() ?? '',
        content,
      );
    }
    list[index] = updated;
    await _toolEventsBox.put(assistantMessageId, list);
    return true;
  }

  @override
  String? getGeminiThoughtSignature(String assistantMessageId) {
    final value = _toolEventsBox.get(_sigKey(assistantMessageId));
    if (value is String && value.trim().isNotEmpty) return value;
    return null;
  }

  @override
  Future<void> setGeminiThoughtSignature(
    String assistantMessageId,
    String signature,
  ) async {
    await _toolEventsBox.put(_sigKey(assistantMessageId), signature);
  }

  @override
  Future<void> removeGeminiThoughtSignature(String assistantMessageId) async {
    try {
      await _toolEventsBox.delete(_sigKey(assistantMessageId));
    } catch (_) {}
  }

  @override
  List<FileRecord> getFileRecords(String messageId) {
    final value = _messageFileRecordsBox.get(messageId);
    if (value is! List) return const <FileRecord>[];
    final records = <FileRecord>[];
    for (final item in value) {
      try {
        if (item is Map) {
          records.add(FileRecord.fromJson(Map<String, dynamic>.from(item)));
        }
      } catch (_) {}
    }
    return records;
  }

  @override
  Future<void> addFileRecord(String messageId, FileRecord record) async {
    final records = List<FileRecord>.of(getFileRecords(messageId))
      ..removeWhere((item) => item.path == record.path)
      ..add(record);
    await _messageFileRecordsBox.put(
      messageId,
      records.map((item) => item.toJson()).toList(),
    );
  }

  @override
  WorkspaceConfig? getWorkspaceConfig(String conversationId) {
    final raw = _conversationWorkspaceBindingsBox.get(conversationId);
    if (raw is Map) return WorkspaceConfig.fromJson(raw);

    final legacy = _conversationWorkspacesBox.get(conversationId);
    if (legacy is String && legacy.trim().isNotEmpty) {
      return WorkspaceConfig.custom(legacy.trim());
    }
    return null;
  }

  @override
  Future<void> setWorkspaceConfig(
    String conversationId,
    WorkspaceConfig? config,
  ) async {
    await _conversationWorkspacesBox.delete(conversationId);
    if (config == null || config.mode == WorkspaceMode.inheritProject) {
      await _conversationWorkspaceBindingsBox.delete(conversationId);
    } else {
      await _conversationWorkspaceBindingsBox.put(
        conversationId,
        config.toJson(),
      );
    }
  }

  @override
  Future<Conversation> forkConversation({
    required String title,
    required String? assistantId,
    required List<ChatMessage> sourceMessages,
    Map<String, int>? versionSelections,
  }) async {
    final now = DateTime.now();
    final conversation = Conversation(
      title: title,
      assistantId: assistantId,
      createdAt: now,
      updatedAt: now,
      versionSelections: Map<String, int>.from(
        versionSelections ?? const <String, int>{},
      ),
    );
    await _conversationsBox.put(conversation.id, conversation);

    final sourceConversationId = sourceMessages.isEmpty
        ? null
        : sourceMessages.first.conversationId;
    final sourceWorkspace = sourceConversationId == null
        ? null
        : getWorkspaceConfig(sourceConversationId);
    if (sourceWorkspace != null) {
      await setWorkspaceConfig(conversation.id, sourceWorkspace);
    }

    final ids = <String>[];
    final clones = <ChatMessage>[];
    for (final src in sourceMessages) {
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
        conversationId: conversation.id,
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
      await _messagesBox.put(clone.id, clone);
      final records = getFileRecords(src.id);
      if (records.isNotEmpty) {
        await _messageFileRecordsBox.put(
          clone.id,
          records.map((record) => record.toJson()).toList(),
        );
      }
      ids.add(clone.id);
      clones.add(clone);
    }

    conversation.messageIds
      ..clear()
      ..addAll(ids);
    conversation.updatedAt = DateTime.now();
    await conversation.save();
    _messagesCache[conversation.id] = clones;
    return conversation;
  }

  @override
  Future<void> clearAllData() => _clearBoxes();

  @override
  Future<void> clearAllRows() => _clearBoxes();

  @override
  Future<void> optimize() async {}

  Future<void> _clearBoxes() async {
    await _messagesBox.clear();
    await _conversationsBox.clear();
    await _toolEventsBox.clear();
    await _conversationWorkspacesBox.clear();
    await _conversationWorkspaceBindingsBox.clear();
    await _messageFileRecordsBox.clear();
    _messagesCache.clear();
  }

  // ---------------------------------------------------------------------------
  // Persistence bounds / extras
  // ---------------------------------------------------------------------------

  static String? _existingApprovalState(
    List<Map<String, dynamic>> list,
    int index,
  ) {
    if (index < 0 || index >= list.length) return null;
    final raw = list[index]['approvalState'];
    return raw == null ? null : raw.toString();
  }

  static Map<String, dynamic> _existingToolEventExtras(
    List<Map<String, dynamic>> list,
    int index,
  ) {
    if (index < 0 || index >= list.length) return const <String, dynamic>{};
    final event = list[index];
    return <String, dynamic>{
      for (final key in kPreservedToolEventExtraKeys)
        if (event[key] != null) key: event[key],
    };
  }
}
