import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/file_record.dart';
import '../../models/workspace_config.dart';
import '../logging/flutter_logger.dart';
import 'storage/chat_repository.dart' show ChatStorageCounts;
import 'storage/chat_storage.dart';
import 'storage/chat_storage_gate.dart';
import 'storage/chat_storage_recovery_service.dart';
import 'storage/chat_storage_startup_status.dart';
import 'storage/database_installation_gate.dart' show chatHiveFiles;
import 'storage/hive_chat_storage.dart';
import 'storage/legacy_reimport_service.dart';
import 'storage/message_part_codec.dart';
import 'storage/sqlite_chat_storage.dart';

/// Runs when chat-storage migration actually starts and when initialization
/// leaves the migration path. The UI uses this for a temporary Android
/// foreground service so the OS cannot kill a long import.
typedef ChatMigrationLifecycleCallback = Future<void> Function();

/// The installation gate recorded a database that is now missing. Recovery
/// must be an explicit user decision; `init()` must not silently create an
/// empty database or fall back without offering the choices.
class ChatStorageRestoreRequiredException implements Exception {
  const ChatStorageRestoreRequiredException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// App-facing chat store (§9.1).
///
/// The public API and its `ChangeNotifier` notifications stay stable; all
/// persistence is delegated to a [ChatStorage] backend:
///
/// * `sqlite` — `chat_v2.sqlite` after the installation/migration gate passes
///   (§9.6). Tool bodies are loaded per conversation; [getToolEvents] fails
///   closed for a message that was never loaded.
/// * `hive` — the legacy boxes, kept as a one-release fallback when the gate
///   fails and as the explicit backend in the Hive persistence tests.
///
/// Draft conversations live here, not in a backend: a draft has no persisted
/// rows until the first message promotes it in one operation.
class ChatService extends ChangeNotifier {
  ChatService({ChatStorage? storage, ChatStorageBackend? backend})
    : _storageOverride = storage,
      _backendOverride = backend;

  static const int maxPersistedFileReadResultChars =
      kMaxPersistedFileReadResultChars;

  /// UI-only metadata fields that must survive result upserts. Kept as a
  /// public allow-list so arbitrary event payloads never leak into
  /// replacements (also used by the stream controller when hydrating live
  /// tool card parts).
  static const List<String> preservedToolEventExtraKeys =
      kPreservedToolEventExtraKeys;

  final ChatStorage? _storageOverride;
  final ChatStorageBackend? _backendOverride;

  ChatStorage? _storage;
  ChatStorageGateResult? _lastStorageGateResult;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;
  Future<LegacyReimportReport>? _reimportFuture;
  ChatMigrationBackupPrompt? _backupPrompt;
  ChatMigrationLifecycleCallback? _onMigrationStarted;
  ChatMigrationLifecycleCallback? _onMigrationFinished;
  bool _migrationKeepAliveStarted = false;
  Directory? _appDataDirectory;
  bool _legacyHiveAvailable = false;
  ChatStorageInitStatus _storageInitStatus = const ChatStorageInitStatus();

  String? _currentConversationId;
  final Map<String, Conversation> _draftConversations = {};

  /// Workspace choices made on an unpersisted draft. SQLite has a foreign key
  /// from the binding to `conversations`, so the binding is applied in the
  /// same operation that promotes the draft on its first message.
  final Map<String, WorkspaceConfig> _draftWorkspaceConfigs = {};

  // Localized default title for new conversations; set by UI on startup.
  String _defaultConversationTitle = 'New Chat';

  void setDefaultConversationTitle(String title) {
    if (title.trim().isEmpty) return;
    _defaultConversationTitle = title.trim();
  }

  bool get initialized => _initialized;

  /// True when a persisted assistant row is still marked as streaming. Legacy
  /// re-import requires an idle store so a stream write cannot race the cache
  /// refresh after the merge.
  /// Loads every conversation first because a stream may belong to a
  /// conversation that is not currently open. This is a rare re-import guard,
  /// not a startup path.
  Future<bool> hasStreamingMessages() async {
    if (!_initialized) return false;
    await _storage!.ensureAllMessagesLoaded();
    return _storage!.allMessages().any((message) => message.isStreaming);
  }

  String? get currentConversationId => _currentConversationId;

  /// The active backend, or null before initialization.
  ChatStorageBackend? get backend => _storage?.backend;

  /// Result of the SQLite admission/migration gate for diagnostics. Null when
  /// a backend was explicitly injected (tests) or Hive was forced.
  ChatStorageGateResult? get storageGateResult => _lastStorageGateResult;

  /// Live startup progress for the blocking migration UI (§9.6 step 3).
  ChatStorageInitStatus get storageInitStatus => _storageInitStatus;

  /// True when the gate needs an explicit restore/reset choice. The recovery
  /// overlay owns the next action; no chat widget may read the store yet.
  bool get needsRestoreOrReset =>
      _storageInitStatus.phase == ChatStorageInitPhase.restoreRequired;

  /// Whether untouched Hive chat artifacts exist for a rebuild action. Only
  /// meaningful while [needsRestoreOrReset] is true.
  bool get legacyHiveAvailable => _legacyHiveAvailable;

  /// True while [init] is running. Concurrent callers await the same future so
  /// the gate and importer never run twice in one process.
  bool get initializing => _initFuture != null;

  /// Initializes the chat store. Runs the SQLite installation/migration gate
  /// first; ordinary failures fall back to Hive, while a recorded-but-missing
  /// database pauses in `restoreRequired` for the explicit recovery UI.
  ///
  /// [onMigrationStarted] and [onMigrationFinished] are best-effort lifecycle
  /// hooks for the UI. They fire once per real import, never for an ordinary
  /// SQLite startup. Concurrent [init] callers join the first call's hooks.
  Future<void> init({
    ChatMigrationBackupPrompt? backupPrompt,
    ChatMigrationLifecycleCallback? onMigrationStarted,
    ChatMigrationLifecycleCallback? onMigrationFinished,
  }) {
    if (_disposed || _initialized) return Future<void>.value();
    final running = _initFuture;
    if (running != null) return running;

    // Register the in-flight future *before* `_initialize` can run. Its first
    // status update notifies listeners synchronously; a listener that calls
    // `init()` again must join this future instead of starting a second gate
    // or importer. The microtask also keeps the first notification out of a
    // widget build that may be creating this service.
    _backupPrompt = backupPrompt ?? _backupPrompt;
    _onMigrationStarted = onMigrationStarted ?? _onMigrationStarted;
    _onMigrationFinished = onMigrationFinished ?? _onMigrationFinished;
    final completer = Completer<void>();
    _initFuture = completer.future;
    scheduleMicrotask(() async {
      try {
        await _initialize();
        if (!completer.isCompleted) completer.complete();
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        if (identical(_initFuture, completer.future)) {
          _initFuture = null;
        }
      }
    });
    return completer.future;
  }

  Future<void> _initialize() async {
    _migrationKeepAliveStarted = false;
    _legacyHiveAvailable = false;
    _lastStorageGateResult = null;
    _setStorageInitStatus(
      const ChatStorageInitStatus(phase: ChatStorageInitPhase.preparing),
    );
    try {
      if (_storageOverride != null) {
        await _storageOverride.initialize();
        _storage = _storageOverride;
        _initialized = true;
        _setStorageInitStatus(
          const ChatStorageInitStatus(phase: ChatStorageInitPhase.ready),
        );
        return;
      }

      final appDataDir = await AppDirectories.getAppDataDirectory();
      _appDataDirectory = appDataDir;
      // Historically ChatService.init was the app's Hive initializer;
      // TodoService (`todo_v1`) still opens its own box, so keep the path
      // initialized even when SQLite is authoritative. Initializing the path
      // opens no chat box.
      Hive.init(appDataDir.path);

      // The gate reports `checking` through `onMigrationProgress`; don't
      // publish a duplicate intermediate status before it runs.
      final selection = await _selectStorage(appDataDir);
      var storage = selection.storage;
      var fallbackReason = selection.fallbackReason;
      _setStorageInitStatus(
        const ChatStorageInitStatus(phase: ChatStorageInitPhase.opening),
      );
      try {
        await storage.initialize();
      } catch (e) {
        // A failed initialize may already hold a DB connection or some Hive
        // boxes. Close it before a fallback/retry opens the same files again.
        final failedStorage = storage;
        try {
          await failedStorage.dispose();
        } catch (_) {}

        // A database can pass the admission gate and still fail to open (for
        // example a locked/corrupt file). Keep the app usable on the legacy
        // backend instead of failing chat initialization outright.
        if (failedStorage.backend == ChatStorageBackend.sqlite &&
            _backendOverride != ChatStorageBackend.sqlite) {
          FlutterLogger.log(
            'SQLite chat storage open failed: $e. Falling back to Hive.',
            tag: 'chat-storage',
          );
          fallbackReason = 'SQLite could not be opened: $e';
          storage = HiveChatStorage(directory: appDataDir);
          try {
            await storage.initialize();
          } catch (_) {
            try {
              await storage.dispose();
            } catch (_) {}
            rethrow;
          }
        } else {
          rethrow;
        }
      }

      // Retired P1-5 snapshot box: best-effort sweep, never opened as chat
      // data.
      try {
        await Hive.deleteBoxFromDisk(
          HiveChatStorage.legacyMessageSnapshotsBoxName,
        );
      } catch (_) {}

      if (_disposed) return;
      _storage = storage;
      _initialized = true;
      _setStorageInitStatus(
        ChatStorageInitStatus(
          phase: ChatStorageInitPhase.ready,
          isLegacyFallback: fallbackReason != null,
          message: fallbackReason,
        ),
      );
    } on ChatStorageRestoreRequiredException catch (e) {
      _legacyHiveAvailable =
          _appDataDirectory != null &&
          chatHiveFiles(_appDataDirectory!).isNotEmpty;
      _setStorageInitStatus(
        ChatStorageInitStatus(
          phase: ChatStorageInitPhase.restoreRequired,
          message: e.message,
          canRetry: true,
        ),
      );
      rethrow;
    } catch (e) {
      FlutterLogger.log(
        'Chat storage initialization failed: $e',
        tag: 'chat-storage',
      );
      _setStorageInitStatus(
        ChatStorageInitStatus(
          phase: ChatStorageInitPhase.failed,
          message: e.toString(),
          canRetry: true,
        ),
      );
      rethrow;
    } finally {
      // On failure the overlay exposes Retry immediately. Do not make a fast
      // retry join this failed initialization while Android tears the
      // foreground service down; success can wait for the bounded cleanup.
      if (_storageInitStatus.phase == ChatStorageInitPhase.failed) {
        unawaited(_endMigrationKeepAlive());
      } else {
        await _endMigrationKeepAlive();
      }
    }
  }

  Future<_StorageSelection> _selectStorage(Directory directory) async {
    if (_backendOverride == ChatStorageBackend.hive) {
      return _StorageSelection(HiveChatStorage(directory: directory));
    }

    final appVersion = await _appVersion();
    if (_backendOverride == ChatStorageBackend.sqlite) {
      return _StorageSelection(
        SqliteChatStorage(directory: directory, appVersion: appVersion),
      );
    }

    const forceHive = bool.fromEnvironment(
      'CHAT_STORAGE_FORCE_HIVE',
      defaultValue: false,
    );
    if (forceHive) {
      FlutterLogger.log(
        'CHAT_STORAGE_FORCE_HIVE is set; using the Hive chat backend.',
        tag: 'chat-storage',
      );
      return _StorageSelection(HiveChatStorage(directory: directory));
    }

    try {
      final result = await ChatStorageGate(
        directory: directory,
        appVersion: appVersion,
        backupPrompt: _backupPrompt,
        // Never silently skip the pre-migration backup. A non-UI caller that
        // reaches the gate first stays on Hive until the app is restarted from
        // the chat surface, where the backup prompt is available.
        requireBackupPrompt: true,
        onMigrationProgress: _onMigrationProgress,
      ).ensureReady();
      _lastStorageGateResult = result;
      if (result.stage == ChatStorageGateStage.needsRestoreOrReset) {
        throw ChatStorageRestoreRequiredException(result.message);
      }
      if (result.sqliteReady) {
        FlutterLogger.log(
          'SQLite chat storage ready (${result.stage.name}).',
          tag: 'chat-storage',
        );
        return _StorageSelection(
          SqliteChatStorage(directory: directory, appVersion: appVersion),
        );
      }
      FlutterLogger.log(
        'SQLite chat storage unavailable (${result.stage.name}): '
        '${result.message}. Falling back to Hive.',
        tag: 'chat-storage',
      );
      return _StorageSelection(
        HiveChatStorage(directory: directory),
        fallbackReason: result.message,
      );
    } on ChatStorageRestoreRequiredException {
      rethrow;
    } catch (e) {
      FlutterLogger.log(
        'Chat storage gate failed: $e. Falling back to Hive.',
        tag: 'chat-storage',
      );
      return _StorageSelection(
        HiveChatStorage(directory: directory),
        fallbackReason: e.toString(),
      );
    }
  }

  void _onMigrationProgress(String stage, ChatStorageCounts? counts) {
    final phase = switch (stage) {
      'checking' => ChatStorageInitPhase.checking,
      'validating' => ChatStorageInitPhase.validating,
      'backing-up' ||
      'copying-hive' ||
      'exporting-json' ||
      'verifying-backup' => ChatStorageInitPhase.backingUp,
      _ => ChatStorageInitPhase.migrating,
    };
    if (stage != 'checking') {
      _startMigrationKeepAlive();
    }
    _setStorageInitStatus(
      _storageInitStatus.copyWith(
        phase: phase,
        stage: stage,
        conversations: counts?.conversations,
        messages: counts?.messages,
        parts: counts?.parts,
        quarantined: counts?.quarantined,
      ),
    );
  }

  void _startMigrationKeepAlive() {
    if (_migrationKeepAliveStarted) return;
    _migrationKeepAliveStarted = true;
    final callback = _onMigrationStarted;
    if (callback == null) return;
    unawaited(
      Future<void>.sync(callback).catchError((Object error) {
        FlutterLogger.log(
          'Migration keep-alive start failed: $error',
          tag: 'chat-storage',
        );
      }),
    );
  }

  Future<void> _endMigrationKeepAlive() async {
    if (!_migrationKeepAliveStarted) return;
    _migrationKeepAliveStarted = false;
    final callback = _onMigrationFinished;
    if (callback == null) return;
    try {
      // A best-effort platform cleanup must never hold the startup future
      // open if a plugin hangs.
      await callback().timeout(const Duration(seconds: 2));
    } catch (error) {
      FlutterLogger.log(
        'Migration keep-alive cleanup failed: $error',
        tag: 'chat-storage',
      );
    }
  }

  void _setStorageInitStatus(ChatStorageInitStatus status) {
    if (_disposed || _storageInitStatus == status) return;
    _storageInitStatus = status;
    notifyListeners();
  }

  Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber.trim();
      return build.isEmpty ? info.version : '${info.version}+$build';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Clears `isStreaming` flags left behind by a crash/force-close.
  ///
  /// Kept as a static, box-scoped helper for the Hive backend tests. The
  /// SQLite backend performs the equivalent repair in its repository/startup
  /// path.
  @visibleForTesting
  static Future<int> repairStaleStreamingMessages(Box<ChatMessage> box) async {
    final updates = <dynamic, ChatMessage>{};
    for (final key in box.keys.toList()) {
      try {
        final message = box.get(key);
        if (message == null || !message.isStreaming) continue;
        updates[key] = message.copyWith(isStreaming: false);
      } catch (_) {
        // One corrupt row must not abort the sweep.
      }
    }
    if (updates.isEmpty) return 0;
    await box.putAll(updates);
    return updates.length;
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  List<Conversation> getAllConversations() {
    if (!_initialized) return [];
    return _storage!.listConversations();
  }

  List<Conversation> getPinnedConversations() {
    return getAllConversations().where((c) => c.isPinned).toList();
  }

  Conversation? getConversation(String id) {
    if (!_initialized) return null;
    return _storage!.getConversation(id) ?? _draftConversations[id];
  }

  /// Messages for an open conversation. Call [ensureConversationLoaded] first;
  /// an unloaded persisted conversation throws rather than looking empty.
  List<ChatMessage> getMessages(String conversationId) {
    if (!_initialized) return [];
    if (_draftConversations.containsKey(conversationId)) {
      return const <ChatMessage>[];
    }
    return _storage!.getMessages(conversationId);
  }

  /// Preloads a conversation's timeline tool *summaries* (never full bodies).
  /// Call before [getToolPartSummaries] for a conversation that has just been
  /// opened. Model replay must call [ensureToolEventsLoaded] separately.
  Future<void> ensureConversationLoaded(String conversationId) async {
    if (!_initialized) await init();
    if (_draftConversations.containsKey(conversationId)) return;
    await _storage!.ensureConversationLoaded(conversationId);
  }

  Future<void> ensureToolEventsLoaded(Iterable<String> messageIds) async {
    if (!_initialized) await init();
    await _storage!.ensureToolEventsLoaded(messageIds);
  }

  /// Loads every persisted conversation's message bodies. Used by stats and
  /// importers that legitimately need the full history but not tool bodies.
  Future<void> ensureAllMessagesLoaded() async {
    if (!_initialized) await init();
    await _storage!.ensureAllMessagesLoaded();
  }

  /// Loads every message and full tool event. Required before a full
  /// backup/export, which legitimately reads every message.
  Future<void> ensureAllConversationsLoaded() async {
    if (!_initialized) await init();
    await _storage!.ensureAllMessagesLoaded();
    await _storage!.ensureAllToolEventsLoaded();
  }

  // ---------------------------------------------------------------------------
  // Conversations
  // ---------------------------------------------------------------------------

  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
  }) async {
    if (!_initialized) await init();

    final conversation = Conversation(
      title: title ?? _defaultConversationTitle,
      assistantId: assistantId,
    );
    await _storage!.putConversation(conversation);
    _currentConversationId = conversation.id;
    notifyListeners();
    return conversation;
  }

  /// Creates a conversation that is not persisted until the first message.
  Future<Conversation> createDraftConversation({
    String? title,
    String? assistantId,
  }) async {
    if (!_initialized) await init();
    final conversation = Conversation(
      title: title ?? _defaultConversationTitle,
      assistantId: assistantId,
    );
    _draftConversations[conversation.id] = conversation;
    _currentConversationId = conversation.id;
    notifyListeners();
    return conversation;
  }

  Future<void> deleteConversation(String id) async {
    if (!_initialized) return;
    if (await _deleteConversationInternal(id)) {
      notifyListeners();
    }
  }

  /// Deletes each id once. Returns the number of conversations actually
  /// removed; notifies at most once after orphaned-file cleanup.
  Future<int> deleteConversations(Iterable<String> ids) async {
    if (!_initialized) await init();

    var count = 0;
    final seen = <String>{};
    for (final id in ids) {
      if (id.isEmpty || !seen.add(id)) continue;
      if (await _deleteConversationInternal(id, cleanup: false)) {
        count++;
      }
    }
    if (count == 0) return 0;
    await _cleanupOrphanUploads();
    notifyListeners();
    return count;
  }

  Future<bool> _deleteConversationInternal(
    String id, {
    bool cleanup = true,
  }) async {
    if (_draftConversations.containsKey(id)) {
      _draftConversations.remove(id);
      _draftWorkspaceConfigs.remove(id);
      if (_currentConversationId == id) _currentConversationId = null;
      return true;
    }

    final conversation = _storage!.getConversation(id);
    if (conversation == null) return false;

    await _storage!.deleteConversation(id);
    if (cleanup) await _cleanupOrphanUploads();
    if (_currentConversationId == id) _currentConversationId = null;
    return true;
  }

  Future<void> restoreConversation(
    Conversation conversation,
    List<ChatMessage> messages,
  ) async {
    if (!_initialized) await init();
    _draftConversations.remove(conversation.id);
    await _storage!.restoreConversation(conversation, messages);
    notifyListeners();
  }

  /// Adds a message directly to an existing conversation (merge/import path).
  Future<void> addMessageDirectly(
    String conversationId,
    ChatMessage message,
  ) async {
    if (!_initialized) await init();
    await _storage!.addMessageDirectly(conversationId, message);
    notifyListeners();
  }

  Future<void> renameConversation(String id, String newTitle) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(id)) {
      final draft = _draftConversations[id]!;
      draft.title = newTitle;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    if (_storage!.getConversation(id) == null) return;
    await _storage!.renameConversation(id, newTitle);
    notifyListeners();
  }

  /// Updates the conversation summary generated by the LLM.
  Future<void> updateConversationSummary(
    String id,
    String summary,
    int messageCount,
  ) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(id)) {
      final draft = _draftConversations[id]!;
      draft.summary = summary;
      draft.lastSummarizedMessageCount = messageCount;
      notifyListeners();
      return;
    }
    if (_storage!.getConversation(id) == null) return;
    await _storage!.setConversationSummary(id, summary, messageCount);
    notifyListeners();
  }

  /// Gets all conversations with non-empty summaries for a specific assistant.
  List<Conversation> getConversationsWithSummaryForAssistant(
    String assistantId,
  ) {
    if (!_initialized) return [];
    return getAllConversations()
        .where(
          (c) =>
              c.assistantId == assistantId &&
              c.summary != null &&
              c.summary!.trim().isNotEmpty,
        )
        .toList();
  }

  /// Clears the summary of a specific conversation.
  Future<void> clearConversationSummary(String conversationId) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.summary = null;
      draft.lastSummarizedMessageCount = 0;
      notifyListeners();
      return;
    }
    if (_storage!.getConversation(conversationId) == null) return;
    await _storage!.setConversationSummary(conversationId, null, 0);
    notifyListeners();
  }

  Future<void> togglePinConversation(String id) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(id)) {
      final draft = _draftConversations[id]!;
      draft.isPinned = !draft.isPinned;
      notifyListeners();
      return;
    }
    final conversation = _storage!.getConversation(id);
    if (conversation == null) return;
    await _storage!.setConversationPinned(id, !conversation.isPinned);
    notifyListeners();
  }

  /// Sets pin state to [pinned] for each id. Returns how many conversations
  /// changed. Notifies at most once.
  Future<int> setConversationsPinned(Iterable<String> ids, bool pinned) async {
    if (!_initialized) await init();

    var changed = 0;
    final seen = <String>{};
    for (final id in ids) {
      if (id.isEmpty || !seen.add(id)) continue;
      if (_draftConversations.containsKey(id)) {
        final draft = _draftConversations[id]!;
        if (draft.isPinned == pinned) continue;
        draft.isPinned = pinned;
        changed++;
        continue;
      }
      final conversation = _storage!.getConversation(id);
      if (conversation == null) continue;
      if (conversation.isPinned == pinned) continue;
      await _storage!.setConversationPinned(id, pinned);
      changed++;
    }
    if (changed == 0) return 0;
    notifyListeners();
    return changed;
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<ChatMessage> addMessage({
    required String conversationId,
    required String role,
    required String content,
    String? modelId,
    String? providerId,
    int? totalTokens,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    bool isStreaming = false,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    DateTime? processFinishedAt,
    DateTime? processStartedAt,
    String? groupId,
    int? version,
  }) async {
    if (!_initialized) await init();

    var conversation = _storage!.getConversation(conversationId);
    if (conversation == null) {
      final draft = _draftConversations.remove(conversationId);
      if (draft != null) {
        await _storage!.putConversation(draft);
        final pendingWorkspace = _draftWorkspaceConfigs.remove(conversationId);
        if (pendingWorkspace != null) {
          await _storage!.setWorkspaceConfig(conversationId, pendingWorkspace);
        }
        conversation = draft;
      } else {
        conversation = Conversation(
          id: conversationId,
          title: _defaultConversationTitle,
        );
        await _storage!.putConversation(conversation);
      }
    }

    final message = ChatMessage(
      role: role,
      content: content,
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerId,
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
      groupId: groupId,
      version: version,
    );

    await _storage!.appendMessage(message);
    notifyListeners();
    return message;
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
    if (!_initialized) return;
    await _storage!.updateMessage(
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
    notifyListeners();
  }

  /// Updates a message during streaming without notifying listeners.
  Future<void> updateMessageSilent(
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
    if (!_initialized) return;
    await _storage!.updateMessage(
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
    // NOTE: deliberately no notifyListeners() during streaming.
  }

  Future<void> deleteMessage(String messageId) async {
    if (!_initialized) return;
    final deleted = await _storage!.deleteMessage(messageId);
    if (!deleted) return;
    await _cleanupOrphanUploads();
    notifyListeners();
  }

  Future<Conversation?> toggleTruncateAtTail(
    String conversationId, {
    String? defaultTitle,
  }) async {
    if (!_initialized) await init();
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      final lastIndexPlusOne = draft.messageIds.length;
      draft.truncateIndex = (draft.truncateIndex == lastIndexPlusOne)
          ? -1
          : lastIndexPlusOne;
      if ((defaultTitle ?? '').isNotEmpty) draft.title = defaultTitle!;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return draft;
    }

    final conversation = _storage!.getConversation(conversationId);
    if (conversation == null) return null;
    final lastIndexPlusOne = conversation.messageIds.length;
    final newValue = (conversation.truncateIndex == lastIndexPlusOne)
        ? -1
        : lastIndexPlusOne;
    if ((defaultTitle ?? '').isNotEmpty) {
      await _storage!.renameConversation(conversationId, defaultTitle!);
    }
    await _storage!.setConversationIndexes(
      conversationId,
      truncateIndex: newValue,
      compactBeforeIndex: conversation.compactBeforeIndex,
    );
    notifyListeners();
    return _storage!.getConversation(conversationId);
  }

  /// Persists the auto-compaction marker (raw message index).
  Future<void> setCompactBeforeIndex(String conversationId, int index) async {
    if (!_initialized) await init();
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      if (draft.compactBeforeIndex == index) return;
      draft.compactBeforeIndex = index;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    final conversation = _storage!.getConversation(conversationId);
    if (conversation == null) return;
    if (conversation.compactBeforeIndex == index) return;
    await _storage!.setConversationIndexes(
      conversationId,
      truncateIndex: conversation.truncateIndex,
      compactBeforeIndex: index,
    );
    notifyListeners();
  }

  Future<ChatMessage?> appendMessageVersion({
    required String messageId,
    required String content,
  }) async {
    if (!_initialized) await init();
    final message = await _storage!.appendMessageVersion(
      messageId: messageId,
      content: content,
    );
    if (message == null) return null;
    notifyListeners();
    return message;
  }

  Map<String, int> getVersionSelections(String conversationId) {
    final conversation =
        _storage?.getConversation(conversationId) ??
        _draftConversations[conversationId];
    return Map<String, int>.from(
      conversation?.versionSelections ?? const <String, int>{},
    );
  }

  Future<void> setSelectedVersion(
    String conversationId,
    String groupId,
    int version,
  ) async {
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.versionSelections[groupId] = version;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    final conversation = _storage!.getConversation(conversationId);
    if (conversation == null) return;
    await _storage!.setVersionSelections(conversationId, {
      ...conversation.versionSelections,
      groupId: version,
    });
    notifyListeners();
  }

  Future<void> removeSelectedVersion(
    String conversationId,
    String groupId,
  ) async {
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.versionSelections.remove(groupId);
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    final conversation = _storage!.getConversation(conversationId);
    if (conversation == null) return;
    final selections = Map<String, int>.of(conversation.versionSelections)
      ..remove(groupId);
    await _storage!.setVersionSelections(conversationId, selections);
    notifyListeners();
  }

  Future<Conversation> forkConversation({
    required String title,
    required String? assistantId,
    required List<ChatMessage> sourceMessages,
    Map<String, int>? versionSelections,
  }) async {
    if (!_initialized) await init();
    final conversation = await _storage!.forkConversation(
      title: title,
      assistantId: assistantId,
      sourceMessages: sourceMessages,
      versionSelections: versionSelections,
    );
    notifyListeners();
    return conversation;
  }

  // ---------------------------------------------------------------------------
  // Tool events / provider artifacts
  // ---------------------------------------------------------------------------

  /// Full tool events for model replay and UI hydration. Before `init()` this
  /// keeps the historical empty-list contract; after initialization it throws
  /// [ChatStorageNotLoadedException] when the message was never loaded. Use
  /// [ensureToolEventsLoaded] first.
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) {
    if (!_initialized) return const <Map<String, dynamic>>[];
    return _storage!.getToolEvents(assistantMessageId);
  }

  /// Timeline summaries for one message (no completed tool bodies). Throws
  /// [ChatStorageNotLoadedException] when the conversation was never opened.
  List<ToolPartSummary> getToolPartSummaries(String assistantMessageId) {
    if (!_initialized) return const <ToolPartSummary>[];
    return _storage!.getToolPartSummaries(assistantMessageId);
  }

  /// Loads one part's full arguments/content for an expanded card.
  Future<Map<String, dynamic>?> loadToolEventDetail({
    required String assistantMessageId,
    required String toolCallId,
  }) async {
    if (!_initialized) await init();
    return _storage!.loadToolEventDetail(
      assistantMessageId: assistantMessageId,
      toolCallId: toolCallId,
    );
  }

  /// Citation rows parsed from the message's search results, without loading
  /// the rest of its tool bodies.
  Future<List<Map<String, dynamic>>> getSearchCitations(
    String assistantMessageId,
  ) async {
    if (!_initialized) await init();
    return _storage!.getSearchCitations(assistantMessageId);
  }

  Future<void> setToolEvents(
    String assistantMessageId,
    List<Map<String, dynamic>> events,
  ) async {
    if (!_initialized) await init();
    // Preserve the existing writer policy for every backend: a `file_read`
    // result persisted with the event list keeps its 8 KB preview, and
    // non-string content is normalized to null.
    final bounded = [
      for (final event in events) _boundToolEventForPersistence(event),
    ];
    await _storage!.setToolEvents(assistantMessageId, bounded);
    notifyListeners();
  }

  Future<void> upsertToolEvent(
    String assistantMessageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    String? approvalState,
    Map<String, dynamic>? extras,
  }) async {
    if (!_initialized) await init();
    await _storage!.upsertToolEvent(
      assistantMessageId,
      id: id,
      name: name,
      arguments: arguments,
      content: _boundToolResultForPersistence(name, content),
      approvalState: approvalState,
      extras: extras,
    );
    notifyListeners();
  }

  static Map<String, dynamic> _boundToolEventForPersistence(
    Map<String, dynamic> event,
  ) => boundPersistedToolEvent(event);

  static String? _boundToolResultForPersistence(String name, String? content) =>
      boundPersistedToolResult(name, content);

  /// Updates only the `approvalState` (and optionally content) of an existing
  /// tool event. No-op when the event does not exist.
  Future<bool> setToolEventApprovalState(
    String assistantMessageId, {
    required String id,
    required String approvalState,
    String? content,
  }) async {
    if (!_initialized) await init();
    final updated = await _storage!.setToolEventApprovalState(
      assistantMessageId,
      id: id,
      approvalState: approvalState,
      content: content,
    );
    if (updated) notifyListeners();
    return updated;
  }

  String? getGeminiThoughtSignature(String assistantMessageId) {
    if (!_initialized) return null;
    return _storage!.getGeminiThoughtSignature(assistantMessageId);
  }

  Future<void> setGeminiThoughtSignature(
    String assistantMessageId,
    String signature,
  ) async {
    if (!_initialized) await init();
    await _storage!.setGeminiThoughtSignature(assistantMessageId, signature);
    notifyListeners();
  }

  Future<void> removeGeminiThoughtSignature(String assistantMessageId) async {
    if (!_initialized) await init();
    await _storage!.removeGeminiThoughtSignature(assistantMessageId);
  }

  // ---------------------------------------------------------------------------
  // File records / workspace
  // ---------------------------------------------------------------------------

  List<FileRecord> getMessageFileRecords(String messageId) {
    if (!_initialized) return const <FileRecord>[];
    return _storage!.getFileRecords(messageId);
  }

  Future<void> addMessageFileRecord(String messageId, FileRecord record) async {
    if (!_initialized) await init();
    await _storage!.addFileRecord(messageId, record);
    notifyListeners();
  }

  WorkspaceConfig? getConversationWorkspaceConfig(String conversationId) {
    if (!_initialized) return null;
    if (_draftConversations.containsKey(conversationId)) {
      return _draftWorkspaceConfigs[conversationId];
    }
    return _storage!.getWorkspaceConfig(conversationId);
  }

  Future<void> setConversationWorkspace(
    String conversationId,
    String? path,
  ) async {
    await setConversationWorkspaceConfig(
      conversationId,
      path == null || path.trim().isEmpty
          ? const WorkspaceConfig.inheritProject()
          : WorkspaceConfig.custom(path.trim()),
    );
  }

  Future<void> setConversationWorkspaceConfig(
    String conversationId,
    WorkspaceConfig config,
  ) async {
    if (!_initialized) await init();
    if (_draftConversations.containsKey(conversationId)) {
      if (config.mode == WorkspaceMode.inheritProject) {
        _draftWorkspaceConfigs.remove(conversationId);
      } else {
        _draftWorkspaceConfigs[conversationId] = config;
      }
      notifyListeners();
      return;
    }
    await _storage!.setWorkspaceConfig(conversationId, config);
    notifyListeners();
  }

  /// Toggle the workspace for one conversation. Disabling remembers the
  /// current directory choice inside the disabled config; enabling restores
  /// it (falling back to project inheritance).
  Future<void> setConversationWorkspaceEnabled(
    String conversationId,
    bool enable,
  ) async {
    final config = getConversationWorkspaceConfig(conversationId);
    if (enable) {
      final restore = config?.mode == WorkspaceMode.disabled
          ? config!.restoreOnEnable
          : (config ?? const WorkspaceConfig.inheritProject());
      await setConversationWorkspaceConfig(conversationId, restore);
      return;
    }
    final prior = (config == null || config.mode == WorkspaceMode.disabled)
        ? (config?.previous ?? const WorkspaceConfig.inheritProject())
        : config;
    await setConversationWorkspaceConfig(
      conversationId,
      WorkspaceConfig.disabledFrom(prior),
    );
  }

  List<String> getConversationMcpServers(String conversationId) {
    if (!_initialized) return const <String>[];
    final conversation =
        _storage!.getConversation(conversationId) ??
        _draftConversations[conversationId];
    return conversation?.mcpServerIds ?? const <String>[];
  }

  Future<void> setConversationMcpServers(
    String conversationId,
    List<String> serverIds,
  ) async {
    if (!_initialized) await init();
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.mcpServerIds = List.of(serverIds);
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    if (_storage!.getConversation(conversationId) == null) return;
    await _storage!.setConversationMcpServers(conversationId, serverIds);
    notifyListeners();
  }

  Future<void> toggleConversationMcpServer(
    String conversationId,
    String serverId,
    bool enabled,
  ) async {
    final current = getConversationMcpServers(conversationId);
    final set = current.toSet();
    if (enabled) {
      set.add(serverId);
    } else {
      set.remove(serverId);
    }
    await setConversationMcpServers(conversationId, set.toList());
  }

  // ---------------------------------------------------------------------------
  // Assistant ownership
  // ---------------------------------------------------------------------------

  /// Move an existing conversation to a different assistant.
  Future<void> moveConversationToAssistant({
    required String conversationId,
    required String assistantId,
  }) async {
    if (!_initialized) await init();

    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.assistantId = assistantId;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    if (_storage!.getConversation(conversationId) == null) return;
    await _storage!.setConversationAssistant(conversationId, assistantId);
    notifyListeners();
  }

  /// Moves each conversation to [assistantId]. Items already on that assistant
  /// are skipped. Returns how many actually moved. Notifies at most once.
  Future<int> moveConversationsToAssistant({
    required Iterable<String> conversationIds,
    required String assistantId,
  }) async {
    if (!_initialized) await init();

    var changed = 0;
    final seen = <String>{};
    for (final id in conversationIds) {
      if (id.isEmpty || !seen.add(id)) continue;
      if (await _moveConversationCore(id, assistantId)) changed++;
    }
    if (changed == 0) return 0;
    notifyListeners();
    return changed;
  }

  Future<bool> _moveConversationCore(
    String conversationId,
    String assistantId,
  ) async {
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      if (draft.assistantId == assistantId) return false;
      draft.assistantId = assistantId;
      draft.updatedAt = DateTime.now();
      return true;
    }
    final conversation = _storage!.getConversation(conversationId);
    if (conversation == null || conversation.assistantId == assistantId) {
      return false;
    }
    await _storage!.setConversationAssistant(conversationId, assistantId);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle / filesystem
  // ---------------------------------------------------------------------------

  void setCurrentConversation(String? id) {
    _currentConversationId = id;
    notifyListeners();
  }

  Future<ChatStorageRecoveryService> _recoveryService() async {
    final directory =
        _appDataDirectory ?? await AppDirectories.getAppDataDirectory();
    return ChatStorageRecoveryService(
      directory: directory,
      appVersion: await _appVersion(),
    );
  }

  /// Closes the current backend before a file-level reset/rebuild. Unlike
  /// [close], this keeps the startup callbacks and backup prompt so a rebuild
  /// can immediately re-enter the normal migration flow.
  Future<void> _detachStorageForRecovery() async {
    final storage = _storage;
    _storage = null;
    _initialized = false;
    _currentConversationId = null;
    _draftConversations.clear();
    _draftWorkspaceConfigs.clear();
    if (storage != null) {
      try {
        await storage.dispose();
      } catch (_) {}
    }
  }

  /// Explicitly recreate an empty SQLite store after the gate reported a
  /// missing/corrupt database. The legacy Hive files are preserved, but the
  /// reset sentinel prevents them from being imported into the new database.
  Future<void> resetChatStorage() async {
    await _detachStorageForRecovery();
    try {
      final recovery = await _recoveryService();
      await recovery.resetToFreshDatabase();
      await init();
    } catch (error) {
      _markRecoveryFailed(error);
      rethrow;
    }
  }

  /// Remove only SQLite artifacts/markers so the normal gate can re-import the
  /// untouched Hive files. The existing backup prompt is reused.
  Future<void> rebuildFromLegacyHive() async {
    await _detachStorageForRecovery();
    try {
      final recovery = await _recoveryService();
      await recovery.clearForLegacyImport();
      await init();
    } catch (error) {
      _markRecoveryFailed(error);
      rethrow;
    }
  }

  /// Validate a backup before destructive recovery. A settings-only archive is
  /// not enough to replace the chat database.
  Future<void> validateChatBackup(File archive) async {
    final recovery = await _recoveryService();
    await recovery.validateBackup(archive);
  }

  /// Keep the app usable for this session without deleting the missing/corrupt
  /// SQLite family or modifying Hive. A later launch asks again.
  Future<void> useLegacyStorage() async {
    if (_initialized && _storage?.backend == ChatStorageBackend.hive) return;
    await _detachStorageForRecovery();
    final directory =
        _appDataDirectory ?? await AppDirectories.getAppDataDirectory();
    final storage = HiveChatStorage(directory: directory);
    try {
      await storage.initialize();
    } catch (error) {
      try {
        await storage.dispose();
      } catch (_) {}
      _markRecoveryFailed(error);
      rethrow;
    }
    if (_disposed) {
      await storage.dispose();
      return;
    }
    _storage = storage;
    _initialized = true;
    _setStorageInitStatus(
      ChatStorageInitStatus(
        phase: ChatStorageInitPhase.ready,
        isLegacyFallback: true,
        message: _lastStorageGateResult?.message,
      ),
    );
  }

  void _markRecoveryFailed(Object error) {
    if (_disposed) return;
    _setStorageInitStatus(
      ChatStorageInitStatus(
        phase: ChatStorageInitPhase.failed,
        message: error.toString(),
        canRetry: true,
      ),
    );
  }

  /// Destructive user action: reset the chat database (§8.10) and clear the
  /// in-memory drafts. Writes the `legacy_import_disabled` sentinel.
  Future<void> clearAllData() async {
    if (!_initialized) return;
    try {
      await _storage!.clearAllData();
    } catch (_) {
      // A failed reset may leave the backend closed. Do not keep serving the
      // stale cache as if it were live data; a later init() re-admits.
      _initialized = false;
      rethrow;
    }
    await _afterClearRows();
  }

  /// Explicit §9.8 legacy Hive re-import. Merges missing conversations and
  /// messages into the live SQLite store, keeps existing rows, and removes the
  /// durable `legacy_import_disabled` sentinel only after validation succeeds.
  /// Concurrent callers join one import.
  Future<LegacyReimportReport> reimportLegacyHive({
    void Function(String stage)? onProgress,
  }) {
    final running = _reimportFuture;
    if (running != null) return running;

    final completer = Completer<LegacyReimportReport>();
    _reimportFuture = completer.future;
    scheduleMicrotask(() async {
      try {
        final report = await _reimportLegacyHiveInternal(onProgress);
        if (!completer.isCompleted) completer.complete(report);
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        if (identical(_reimportFuture, completer.future)) {
          _reimportFuture = null;
        }
      }
    });
    return completer.future;
  }

  Future<LegacyReimportReport> _reimportLegacyHiveInternal(
    void Function(String stage)? onProgress,
  ) async {
    if (!_initialized) await init();
    final storage = _storage;
    if (storage is! SqliteChatStorage) {
      throw const LegacyReimportException(
        'The legacy import requires the SQLite chat store.',
      );
    }
    if (await hasStreamingMessages()) {
      throw const LegacyReimportException(
        'Stop any active reply before importing legacy chat data.',
      );
    }
    final report = await LegacyReimportService(
      directory: storage.directory,
      appVersion: await _appVersion(),
      destination: storage,
    ).run(onProgress: onProgress);
    notifyListeners();
    return report;
  }

  /// Reclaims free pages after large deletions (`VACUUM`). Requires an idle
  /// app; the settings page only calls it after confirmation.
  Future<void> optimizeChatDatabase() async {
    if (!_initialized) await init();
    await _storage!.optimize();
    notifyListeners();
  }

  /// Backup-restore path: delete all chat rows without resetting the database
  /// installation or writing the `legacy_import_disabled` sentinel.
  Future<void> clearAllChatRows() async {
    if (!_initialized) return;
    await _storage!.clearAllRows();
    await _afterClearRows();
  }

  Future<void> _afterClearRows() async {
    _draftConversations.clear();
    _draftWorkspaceConfigs.clear();
    _currentConversationId = null;
    // Remove the uploads directory completely.
    try {
      final uploadDir = await AppDirectories.getUploadDirectory();
      if (await uploadDir.exists()) {
        await uploadDir.delete(recursive: true);
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Uploads stats: count and total size of files under app documents/upload.
  Future<UploadStats> getUploadStats() async {
    try {
      final uploadDir = await AppDirectories.getUploadDirectory();
      if (!await uploadDir.exists()) {
        return const UploadStats(fileCount: 0, totalBytes: 0);
      }
      var count = 0;
      var bytes = 0;
      final entries = uploadDir.listSync(recursive: true, followLinks: false);
      for (final entry in entries) {
        if (entry is File) {
          count += 1;
          try {
            bytes += await entry.length();
          } catch (_) {}
        }
      }
      return UploadStats(fileCount: count, totalBytes: bytes);
    } catch (_) {
      return const UploadStats(fileCount: 0, totalBytes: 0);
    }
  }

  Future<void> _cleanupOrphanUploads() async {
    try {
      final storage = _storage;
      if (storage == null) return;
      final uploadDir = await AppDirectories.getUploadDirectory();
      if (!await uploadDir.exists()) return;

      String canon(String path) {
        final normalized = p.normalize(path);
        return Platform.isWindows ? normalized.toLowerCase() : normalized;
      }

      final referenced = <String>{};
      final contents = await storage.attachmentBearingMessageContents();
      for (final content in contents) {
        if (content.isEmpty) continue;
        final imgRe = RegExp(r'\[image:(.+?)\]');
        for (final match in imgRe.allMatches(content)) {
          final path = match.group(1)?.trim();
          if (path != null && path.isNotEmpty) {
            referenced.add(canon(SandboxPathResolver.fix(path)));
          }
        }
        final fileRe = RegExp(r'\[file:(.+?)\|(.+?)\|(.+?)\]');
        for (final match in fileRe.allMatches(content)) {
          final path = match.group(1)?.trim();
          if (path != null && path.isNotEmpty) {
            referenced.add(canon(SandboxPathResolver.fix(path)));
          }
        }
      }

      final entries = uploadDir.listSync(recursive: true, followLinks: false);
      for (final entry in entries) {
        if (entry is File && !referenced.contains(canon(entry.path))) {
          try {
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Closes the active backend. Exposed for tests and orderly shutdown; the
  /// facade must be re-initialized before use afterwards.
  Future<void> close() async {
    await _endMigrationKeepAlive();
    _onMigrationStarted = null;
    _onMigrationFinished = null;
    final storage = _storage;
    _storage = null;
    _initialized = false;
    _initFuture = null;
    _reimportFuture = null;
    _backupPrompt = null;
    _storageInitStatus = const ChatStorageInitStatus();
    if (storage == null) return;
    try {
      await storage.dispose();
    } catch (_) {
      // A shutdown failure must not surface as an unhandled async error.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

class UploadStats {
  const UploadStats({required this.fileCount, required this.totalBytes});

  final int fileCount;
  final int totalBytes;
}

class _StorageSelection {
  const _StorageSelection(this.storage, {this.fallbackReason});

  final ChatStorage storage;
  final String? fallbackReason;
}
