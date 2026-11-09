import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../models/answer_review.dart';
import '../../models/chat_message.dart';
import '../../models/message_usage.dart';
import '../../models/conversation.dart';
import '../../models/file_record.dart';
import '../../models/workspace_config.dart';
import '../agent/checkpoint/agent_run_checkpoint_store.dart';
import '../logging/flutter_logger.dart';
import '../file/session_outputs.dart';
import 'storage/chat_backup_restorer.dart';
import 'storage/chat_database_files.dart';
import 'storage/chat_repository.dart' show ChatStorageCounts;
import 'storage/chat_storage.dart';
import 'storage/chat_storage_gate.dart';
import 'storage/chat_storage_recovery_service.dart';
import 'storage/chat_maintenance_lock.dart';
import 'storage/chat_storage_startup_status.dart';
import 'storage/database_family_publisher.dart';
import 'storage/database_installation_gate.dart'
    show ChatInstallationState, chatHiveFiles;
import 'storage/hive_chat_storage.dart';
import 'storage/file_restore_stager.dart';
import 'storage/legacy_reimport_service.dart';
import 'storage/message_part_codec.dart';
import 'storage/restore_journal.dart';
import 'storage/restore_journal_recovery.dart';
import 'storage/settings_snapshot.dart';
import 'storage/sqlite_chat_storage.dart';
import 'todo_models.dart';
import 'todo_v1_migration.dart';

/// Runs when chat-storage migration actually starts and when initialization
/// leaves the migration path. The UI uses this for a temporary Android
/// foreground service so the OS cannot kill a long import.
typedef ChatMigrationLifecycleCallback = Future<void> Function();

/// The installation gate needs an explicit recovery decision. `init()` must
/// not silently create an empty database or pick another backend.
class ChatStorageRestoreRequiredException implements Exception {
  const ChatStorageRestoreRequiredException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// SQLite is the only runtime chat store. A gate/import/open failure leaves the
/// app in the retry state; it never silently switches back to Hive.
class ChatStorageUnavailableException implements Exception {
  const ChatStorageUnavailableException(this.message);

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
/// * `hive` — only an injected test seam or the legacy import/export source;
///   production startup never selects it as a runtime fallback.
///
/// Draft conversations live here, not in a backend: a draft has no persisted
/// rows until the first message promotes it in one operation.
class ChatService extends ChangeNotifier {
  ChatService({ChatStorage? storage}) : _storageOverride = storage;

  static const int maxPersistedFileReadResultChars =
      kMaxPersistedFileReadResultChars;

  /// UI-only metadata fields that must survive result upserts. Kept as a
  /// public allow-list so arbitrary event payloads never leak into
  /// replacements (also used by the stream controller when hydrating live
  /// tool card parts).
  static const List<String> preservedToolEventExtraKeys =
      kPreservedToolEventExtraKeys;

  final ChatStorage? _storageOverride;

  ChatStorage? _storage;
  ChatStorageGateResult? _lastStorageGateResult;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;
  Future<ChatRestoreResult>? _restoreFuture;
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
  /// first; ordinary failures surface the startup Retry panel, while a
  /// recorded-but-missing/unrecoverable database pauses in `restoreRequired`
  /// for the explicit recovery UI. Hive is never selected at runtime.
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

  Future<void> _initialize({bool recoverRestoreJournal = true}) async {
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
      // Historically ChatService.init was the app's Hive initializer. SQLite
      // is authoritative now, but the path stays initialized for the
      // device-local `AgentRunCheckpointStore` (`agent_runs_v1`) and the
      // one-time `todo_v1` migration below. Initializing the path opens no
      // chat box — do NOT remove it, or agent resume breaks.
      Hive.init(appDataDir.path);

      // A restore journal owns the preserved database and file directories
      // until it is resolved. It must run before the installation gate, whose
      // clean admission deletes `.previous`/`.replaced-*` material.
      if (recoverRestoreJournal) {
        final restoreRecovery = await RestoreJournalRecovery(
          directory: appDataDir,
          appVersion: await _appVersion(),
        ).recoverIfNeeded();
        if (restoreRecovery.failClosed) {
          throw ChatStorageRestoreRequiredException(restoreRecovery.message);
        }
      }

      // The gate reports `checking` through `onMigrationProgress`; don't
      // publish a duplicate intermediate status before it runs.
      final storage = await _selectSqliteStorage(appDataDir);
      // Preserve migration counts/stage through `opening` so the blocking
      // panel does not disappear between validation and the first render.
      // A normal SQLite startup has no counts and uses the invisible barrier.
      _setStorageInitStatus(
        _storageInitStatus.copyWith(
          phase: ChatStorageInitPhase.opening,
          stage: 'opening',
        ),
      );
      try {
        await storage.initialize();
      } catch (e) {
        // A failed initialize may already hold a DB connection. Close it before
        // Retry reopens the same files. There is no Hive runtime fallback.
        try {
          await storage.dispose();
        } catch (_) {}
        throw ChatStorageUnavailableException('SQLite could not be opened: $e');
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
        const ChatStorageInitStatus(phase: ChatStorageInitPhase.ready),
      );

      // One-time `todo_v1` migration (plan §2.5.3): fold the retired Hive
      // plan box into conversation tool events. Idempotent, best-effort,
      // never blocks startup.
      unawaited(
        () async {
          try {
            final prefs = await SharedPreferences.getInstance();
            await TodoV1Migration.run(
              chatService: this,
              prefs: prefs,
              appDataDirPath: _appDataDirectory?.path,
            );
          } catch (e) {
            FlutterLogger.log(
              'todo_v1 migration crashed (non-fatal): $e',
              tag: 'todo-migration',
            );
          }
        }(),
      );
    } on ChatStorageRestoreRequiredException catch (e) {
      _legacyHiveAvailable =
          _appDataDirectory != null &&
          chatHiveFiles(
            _appDataDirectory!,
            // A leftover todo_v1 box is not chat data; it must not advertise
            // "legacy data available" for the restore flow.
            includeTransientTodo: false,
          ).isNotEmpty;
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

  Future<ChatStorage> _selectSqliteStorage(Directory directory) async {
    final appVersion = await _appVersion();
    try {
      final result = await ChatStorageGate(
        directory: directory,
        appVersion: appVersion,
        backupPrompt: _backupPrompt,
        // Never silently skip the pre-migration backup. A non-UI caller that
        // reaches the gate first fails closed until the chat surface retries.
        requireBackupPrompt: true,
        onMigrationProgress: _onMigrationProgress,
      ).ensureReady();
      _lastStorageGateResult = result;

      final installationState = result.installation?.state;
      if (result.stage == ChatStorageGateStage.needsRestoreOrReset ||
          result.needsRecovery ||
          installationState == ChatInstallationState.failClosed ||
          installationState == ChatInstallationState.needsRestoreOrReset) {
        throw ChatStorageRestoreRequiredException(result.message);
      }
      if (!result.sqliteReady) {
        throw ChatStorageUnavailableException(result.message);
      }
      FlutterLogger.log(
        'SQLite chat storage ready (${result.stage.name}).',
        tag: 'chat-storage',
      );
      return SqliteChatStorage(directory: directory, appVersion: appVersion);
    } on ChatStorageRestoreRequiredException {
      rethrow;
    } on ChatStorageUnavailableException {
      rethrow;
    } catch (e) {
      FlutterLogger.log('Chat storage gate failed: $e.', tag: 'chat-storage');
      throw ChatStorageUnavailableException(
        'Chat storage initialization failed: $e',
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
        cutoverStarted: stage != 'checking',
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
      await SessionOutputs.deleteConversation(id);
      await _clearAgentRunCheckpoint(id);
      return true;
    }

    final conversation = _storage!.getConversation(id);
    if (conversation == null) return false;

    await _storage!.deleteConversation(id);
    // P1-6: shell output files are app-private and must not outlive their
    // conversation (retention alone would keep them up to 7 days).
    await SessionOutputs.deleteConversation(id);
    // todo_v1 legacy fallback entries must not outlive their conversation
    // either (plan §2.5.1: no orphan todo data anywhere).
    unawaited(TodoV1Migration.dropConversation(id));
    await _clearAgentRunCheckpoint(id);
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
    MessageUsage? usageMeta,
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
      usageMeta: usageMeta,
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
    MessageUsage? usageMeta,
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
      usageMeta: usageMeta,
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

  /// Persisted answer-review card data for one assistant message. Null for
  /// messages that were never reviewed or before the conversation is loaded.
  AnswerReviewRecord? getAnswerReview(String assistantMessageId) {
    if (!_initialized) return null;
    return _storage!.getAnswerReview(assistantMessageId);
  }

  Map<String, AnswerReviewRecord> getAnswerReviews(
    Iterable<String> messageIds,
  ) {
    if (!_initialized) return const <String, AnswerReviewRecord>{};
    return _storage!.getAnswerReviews(messageIds);
  }

  /// Upserts the per-message review row. Deliberately silent: review writes
  /// happen during streaming and must not trigger a full page rebuild.
  Future<void> upsertAnswerReview({
    required String messageId,
    required AnswerReviewReport report,
    required String status,
    String? draft,
  }) async {
    if (!_initialized) await init();
    await _storage!.upsertAnswerReviewPart(
      messageId: messageId,
      report: report,
      status: status,
      draft: draft,
    );
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

  /// Latest `write_todos` state of a conversation, projected from the most
  /// recent tool part (any status). Used by the write_todos handler to decide
  /// whether an explicit clear actually changed anything (§2.2.3), and by the
  /// todo_v1 migration. Returns null when no parseable part exists.
  Future<TodoState?> getLatestTodoState(String conversationId) async {
    if (!_initialized) return null;
    try {
      final event = await _storage!.getLatestTodoEvent(conversationId);
      if (event == null) return null;
      final content = event['content'];
      final snapshot = parseTodoSnapshotContent(
        content is String ? content : null,
      );
      if (snapshot != null && snapshot.hasItems) {
        return TodoState(items: snapshot.items, hasExplicitState: true);
      }
      final argumentsJson = event['argumentsJson'];
      Object? decodedArgs;
      if (argumentsJson is String && argumentsJson.isNotEmpty) {
        try {
          decodedArgs = jsonDecode(argumentsJson);
        } catch (_) {}
      }
      final rawTodos = decodedArgs is Map ? decodedArgs['todos'] : null;
      final parsed = parseTodoListInput(rawTodos);
      if (!parsed.isValid) return null;
      return TodoState(items: parsed.items, hasExplicitState: true);
    } catch (_) {
      return null;
    }
  }

  /// Whether the conversation has at least one successful `write_todos`
  /// event (todo_v1 migration rule 1: events win over legacy box entries).
  Future<bool> hasCompletedTodoEvent(String conversationId) async {
    if (!_initialized) return false;
    try {
      return await _storage!.hasCompletedTodoEvent(conversationId);
    } catch (_) {
      return false;
    }
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

  MessageUsage? getOpenCodeUsage(String messageId) {
    if (!_initialized) return null;
    return _storage!.getOpenCodeUsage(messageId);
  }

  Future<void> setOpenCodeUsage(String messageId, MessageUsage usage) async {
    if (!_initialized) await init();
    await _storage!.setOpenCodeUsage(messageId, usage);
    notifyListeners();
  }

  Future<void> removeOpenCodeUsage(String messageId) async {
    if (!_initialized) await init();
    await _storage!.removeOpenCodeUsage(messageId);
    notifyListeners();
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

  /// Serializes a restore with [init] and the recovery overlay's Retry.
  bool get restoringBackup => _restoreFuture != null;

  /// Transactional restore (§2.2). Builds a staging database, swaps staged
  /// files, publishes the database (commit point), verifies the live store,
  /// then applies settings. The live database is never cleared first.
  Future<ChatRestoreResult> restoreChatBackup(
    File archive, {
    bool includeFiles = false,
    bool restoreSettings = false,
    void Function(String stage)? onStage,
  }) => _enqueueRestore(
    () => _runRestore(
      archive,
      includeFiles: includeFiles,
      restoreSettings: restoreSettings,
      onStage: onStage,
    ),
  );

  /// Transactional replacement of the chat database with an in-memory payload
  /// (third-party import overwrite path, plan §3 Phase 1c). Attachments may be
  /// pre-staged by the caller under `restore_staging_<restoreId>`; the same
  /// staging/publish commit protocol as [restoreChatBackup] applies.
  Future<ChatRestoreResult> restoreChatsPayload(
    ChatBackupPayload payload, {
    String? restoreId,
    Map<String, RestoreJournalEntry> stagedFiles =
        const <String, RestoreJournalEntry>{},
    void Function(String stage)? onStage,
  }) => _enqueueRestore(
    () => _runRestore(
      null,
      payloadOverride: payload,
      restoreIdOverride: restoreId,
      stagedFilesOverride: stagedFiles,
      includeFiles: false,
      restoreSettings: false,
      onStage: onStage,
    ),
  );

  /// Serializes restore operations with [init] and the recovery overlay's
  /// Retry: a concurrent init()/overlay Retry joins this future instead of
  /// running the gate while files or the database family are being swapped.
  Future<ChatRestoreResult> _enqueueRestore(
    Future<ChatRestoreResult> Function() operation,
  ) async {
    if (_disposed) {
      throw const ChatRestoreException(
        'disposed',
        'The chat service is closed.',
      );
    }
    if (_storageOverride != null && _storageOverride is! SqliteChatStorage) {
      throw const ChatRestoreException(
        'unsupported',
        'Transactional restore requires the SQLite chat store.',
      );
    }

    final running = _restoreFuture;
    if (running != null) return running;
    final runningInit = _initFuture;
    if (runningInit != null) {
      try {
        await runningInit;
      } catch (_) {}
    }
    final startedMeanwhile = _restoreFuture;
    if (startedMeanwhile != null) return startedMeanwhile;

    final completer = Completer<ChatRestoreResult>();
    _restoreFuture = completer.future;
    // A concurrent init()/overlay Retry joins this future instead of running
    // the gate while files or the database family are being swapped.
    _initFuture = completer.future;
    scheduleMicrotask(() async {
      try {
        final result = await operation();
        if (!completer.isCompleted) completer.complete(result);
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        if (identical(_initFuture, completer.future)) _initFuture = null;
        if (identical(_restoreFuture, completer.future)) _restoreFuture = null;
      }
    });
    return completer.future;
  }

  Future<ChatRestoreResult> _runRestore(
    File? archive, {
    ChatBackupPayload? payloadOverride,
    String? restoreIdOverride,
    Map<String, RestoreJournalEntry> stagedFilesOverride =
        const <String, RestoreJournalEntry>{},
    required bool includeFiles,
    required bool restoreSettings,
    void Function(String stage)? onStage,
  }) async {
    final appData =
        _appDataDirectory ?? await AppDirectories.getAppDataDirectory();
    _appDataDirectory = appData;
    final appVersion = await _appVersion();
    final files = ChatDatabaseFiles(appData);
    final restorer = ChatBackupRestorer(
      directory: appData,
      appVersion: appVersion,
    );
    final journalRecovery = RestoreJournalRecovery(
      directory: appData,
      appVersion: appVersion,
    );

    var stage = 'preflight';
    RestoreJournal? journal;
    FileRestoreStager? stager;
    var committed = false;
    var settingsApplied = true;
    var keepForRecovery = false;
    String? settingsError;

    final lock = await ChatMaintenanceLock.acquire(
      appData,
      purpose: 'chat-backup-restore',
      timeout: const Duration(seconds: 5),
    );
    try {
      if (await files.restoreJournal.exists()) {
        throw const ChatRestoreException(
          'preflight',
          'A previous restore is unfinished. Restart the app so it can be '
              'completed or rolled back.',
        );
      }
      final publisher = DatabaseFamilyPublisher(files, appVersion: appVersion);
      final publishRecovery = await publisher.recoverIfNeeded();
      if (publishRecovery.failClosed) {
        throw ChatRestoreException('preflight', publishRecovery.message);
      }
      if (_initialized && await hasStreamingMessages()) {
        throw const ChatRestoreException(
          'preflight',
          'Stop the active reply before restoring a backup.',
        );
      }

      ChatBackupPayload payload;
      if (payloadOverride != null) {
        // Caller-built payloads (third-party importers) must satisfy the same
        // rules as an archive parse before anything is staged.
        restorer.validatePayload(payloadOverride);
        payload = payloadOverride;
      } else {
        stage = 'parse';
        onStage?.call(stage);
        payload = await restorer.parseAndValidate(archive!);
      }
      final databaseId = await restorer.resolveDatabaseId();
      final restoreId = restoreIdOverride ?? const Uuid().v4();
      final publishId = const Uuid().v4();

      journal = await RestoreJournal.begin(
        files: files,
        restoreId: restoreId,
        archiveHash: payload.archiveSha256,
        publishId: publishId,
        stagingDatabaseId: databaseId,
      );

      stage = 'staging-db';
      onStage?.call(stage);
      await restorer.buildStagingDatabase(
        payload: payload,
        databaseId: databaseId,
        publishId: publishId,
      );
      await journal.updateStage(RestoreJournal.stageStaged);

      var swapFiles = false;
      if (stagedFilesOverride.isNotEmpty) {
        stage = 'staging-files';
        onStage?.call(stage);
        // The caller (third-party importers) already wrote the staged files
        // under `restore_staging_<restoreId>`; register them so swap/rollback
        // manage them together with the database transaction (plan §3 Phase
        // 1c).
        swapFiles = true;
        stager = FileRestoreStager(
          appDataDirectory: appData,
          restoreId: restoreId,
        );
        await journal.setFileEntries(stagedFilesOverride);
        await journal.updateStage(RestoreJournal.stageFilesStaged);
      } else if (includeFiles) {
        stage = 'staging-files';
        onStage?.call(stage);
        swapFiles = true;
        stager = FileRestoreStager(
          appDataDirectory: appData,
          restoreId: restoreId,
        );
        final entries = await stager.stageArchive(archive!);
        if (entries.isEmpty) {
          swapFiles = false;
          await stager.cleanup();
          stager = null;
        } else {
          await journal.setFileEntries(entries);
          await journal.updateStage(RestoreJournal.stageFilesStaged);
        }
      }

      stage = 'detach';
      onStage?.call(stage);
      final oldTarget = await probeDatabase(files.database);
      await _detachStorageForRecovery();

      if (swapFiles && stager != null) {
        stage = 'swap-files';
        onStage?.call(stage);
        await stager.swap(journal);
        await journal.updateStage(RestoreJournal.stageFilesSwapped);
      }

      stage = 'publish';
      onStage?.call(stage);
      final outcome = await restorer.publishStaging();
      if (!outcome.success) {
        // Test seam: let a test force the unresolved branch before the
        // publisher gets to decide.
        final afterFailure = ChatBackupRestorer.debugAfterPublishFailure;
        if (afterFailure != null) {
          ChatBackupRestorer.debugAfterPublishFailure = null;
          afterFailure();
        }
        final recovery = await publisher.recoverIfNeeded();
        if (!recovery.resolved) {
          await journal.updateStage(RestoreJournal.stagePublishUnresolved);
          keepForRecovery = true;
          throw ChatRestoreException(
            'publish',
            '${outcome.error ?? 'The restored database could not be published.'} '
                'The restore journal was kept for the next startup.',
          );
        }
        final recovered = await probeDatabase(files.database);
        if (recovered.publishId != publishId) {
          await journal.updateStage(RestoreJournal.stageRollingBack);
          if (stager != null) await stager.rollback(journal);
          await files.deleteFamily(files.restoring);
          if (stager != null) await stager.cleanup();
          await journal.discard();
          journal = null;
          await _initialize(recoverRestoreJournal: false);
          throw ChatRestoreException(
            'publish',
            outcome.error ?? 'The restored database could not be published.',
          );
        }
      }

      committed = true;
      // The restored database has different message ids; any local checkpoint
      // from the pre-restore installation is no longer actionable.
      await _clearAllAgentRunCheckpoints();
      // The publisher knows which family it actually preserved. Scanning for
      // `.previous` would be wrong when an older `.previous` already existed
      // and the target was kept as `.replaced-<publishId>` instead.
      var preservedPath = outcome.previousPath ?? outcome.replacedPath;
      var preservedDatabaseId = outcome.previousDatabaseId;
      if (preservedPath == null) {
        final preserved = await restorer.resolvePreservedFamily(
          oldTarget,
          publishId,
        );
        preservedPath = preserved.path;
        preservedDatabaseId = preserved.databaseId;
      } else if (preservedDatabaseId == null) {
        preservedDatabaseId = (await probeDatabase(File(preservedPath)))
            .databaseId;
      }
      try {
        await journal.notePublished(
          preservedPath: preservedPath,
          preservedDatabaseId: preservedDatabaseId,
        );
        await journal.updateStage(RestoreJournal.stageDbPublished);
      } catch (error) {
        // The database is already committed and verified; a journal write
        // failure must not throw away working data. Recovery can still use
        // the target's publishId.
        FlutterLogger.log(
          'Restore journal could not record the preserved family: $error',
          tag: 'backup-restore',
        );
      }

      stage = 'open';
      onStage?.call(stage);
      await _initialize(recoverRestoreJournal: false);
      final storage = _storage;
      if (storage is! SqliteChatStorage) {
        throw const ChatRestoreException(
          'open',
          'The restored database was not opened by the SQLite store.',
        );
      }
      final liveProbe = await probeDatabase(files.database);
      if (liveProbe.publishId != publishId ||
          liveProbe.databaseId != databaseId) {
        throw const ChatRestoreException(
          'open',
          'The live database identity changed after publish.',
        );
      }
      // Keep the pre-transactional restore contract: a caller may read the
      // restored messages immediately after this method returns.
      await storage.ensureAllMessagesLoaded();
      await restorer.verifyCounts(
        await storage.repository.counts(),
        payload,
        storage.repository,
      );
      await journal.updateStage(RestoreJournal.stageLiveVerified);

      if (restoreSettings && payload.settings != null) {
        stage = 'settings';
        onStage?.call(stage);
        // Settings are not transactional. Capture/stage/apply failures are a
        // partial success; the committed chat data must never be rolled back
        // because of them.
        final settings = SettingsSnapshot(files);
        try {
          await settings.captureCurrent();
          await settings.stageIncoming(payload.settings!);
          await settings.applyPending();
        } catch (error) {
          settingsApplied = false;
          settingsError =
              'Chat data was restored, but settings could not be applied: '
              '$error';
          // The pending file is kept for retry; the pre-restore snapshot is
          // not needed and may contain sensitive settings.
          await settings.discardSnapshot();
          FlutterLogger.log(settingsError, tag: 'backup-restore');
        }
        if (settingsApplied) {
          try {
            await journal.noteSettingsFiles(
              snapshotPath: settings.previous.path,
              pendingPath: settings.pending.path,
            );
          } catch (error) {
            FlutterLogger.log(
              'Restore journal could not record the settings files: $error',
              tag: 'backup-restore',
            );
          }
          try {
            await journal.updateStage(RestoreJournal.stageSettingsApplied);
          } catch (error) {
            // Settings were applied successfully; a journal write failure must
            // not turn a committed restore into a partial failure.
            FlutterLogger.log(
              'Restore journal could not record applied settings: $error',
              tag: 'backup-restore',
            );
          }
        }
      }

      stage = 'cleanup';
      onStage?.call(stage);
      try {
        await journal.done();
      } catch (error) {
        FlutterLogger.log(
          'Restore journal could not be marked done: $error',
          tag: 'backup-restore',
        );
      }
      await restorer.cleanupCommitted(
        preservedPath: journal.preservedPath,
        stagingDirectory: stager?.stagingRoot,
        previousDirectory: stager?.previousRoot,
      );
      try {
        await journal.discard();
      } catch (error) {
        FlutterLogger.log(
          'Restore journal could not be removed: $error',
          tag: 'backup-restore',
        );
      }
      journal = null;

      _currentConversationId = null;
      _draftConversations.clear();
      _draftWorkspaceConfigs.clear();
      _setStorageInitStatus(
        const ChatStorageInitStatus(phase: ChatStorageInitPhase.ready),
      );
      notifyListeners();

      FlutterLogger.log(
        'Restore committed: restoreId=$restoreId '
        'conversations=${payload.conversations.length} '
        'messages=${payload.messageCount} files=$swapFiles '
        'settingsApplied=$settingsApplied',
        tag: 'backup-restore',
      );
      return ChatRestoreResult(
        restoredConversations: payload.conversations.length,
        restoredMessages: payload.messageCount,
        filesRestored: swapFiles,
        settingsApplied: settingsApplied,
        settingsError: settingsError,
      );
    } catch (error) {
      final failureStage = error is ChatRestoreException ? error.stage : stage;
      if (journal != null && keepForRecovery) {
        // Fail closed: the publisher could not decide the database state, so
        // keep the journal, staging database and every preserved family for
        // the next startup.
        _setStorageInitStatus(
          ChatStorageInitStatus(
            phase: ChatStorageInitPhase.failed,
            message:
                'The restore could not be resolved. Restart the app so the '
                'journal can be completed or rolled back; no files were '
                'deleted.',
            canRetry: true,
          ),
        );
        FlutterLogger.log(
          'Restore left unresolved at $failureStage: $error',
          tag: 'backup-restore',
        );
        if (error is ChatRestoreException) rethrow;
        throw ChatRestoreException(
          failureStage,
          error.toString(),
          cause: error,
        );
      }
      if (journal != null) {
        String? rollbackFailure;
        try {
          if (committed) {
            await journal.updateStage(RestoreJournal.stageRollingBack);
            await _detachStorageForRecovery();
            final result = await journalRecovery.rollbackCommitted(journal);
            if (result.failClosed) rollbackFailure = result.message;
            journal = null;
          } else {
            if (stager != null) await stager.rollback(journal);
            await files.deleteFamily(files.restoring);
            if (stager != null) await stager.cleanup();
            await journal.discard();
            journal = null;
          }
        } catch (rollbackError) {
          rollbackFailure = '$rollbackError';
        }
        if (rollbackFailure != null) {
          _setStorageInitStatus(
            ChatStorageInitStatus(
              phase: ChatStorageInitPhase.failed,
              message:
                  'Restore failed and could not be rolled back cleanly: '
                  '$rollbackFailure',
              canRetry: true,
            ),
          );
          throw ChatRestoreException(
            failureStage,
            'Restore failed and could not be rolled back cleanly: '
            '$rollbackFailure',
            cause: error,
          );
        }
      }

      if (!_initialized) {
        try {
          await _initialize(recoverRestoreJournal: false);
        } catch (reopenError) {
          FlutterLogger.log(
            'Chat store could not be reopened after a failed restore: '
            '$reopenError',
            tag: 'backup-restore',
          );
        }
      }
      if (!_initialized) {
        _markRecoveryFailed(error);
      }
      FlutterLogger.log(
        'Restore failed at $failureStage: $error',
        tag: 'backup-restore',
      );
      if (error is ChatRestoreException) rethrow;
      throw ChatRestoreException(failureStage, error.toString(), cause: error);
    } finally {
      await lock.release();
    }
  }

  /// Re-applies staged backup settings after a partial-success restore.
  Future<bool> retryRestoreSettings() async {
    final appData =
        _appDataDirectory ?? await AppDirectories.getAppDataDirectory();
    final files = ChatDatabaseFiles(appData);
    // Never apply staged settings while a restore is unresolved: the staged
    // values may still be rolled back with that restore.
    if (await files.restoreJournal.exists()) return false;
    final applied = await SettingsSnapshot(files).applyPending();
    if (applied) notifyListeners();
    return applied;
  }

  /// Explicitly recreate an empty SQLite store after the gate reported a
  /// missing/corrupt database. The legacy Hive files are preserved, but the
  /// reset sentinel prevents them from being imported into the new database.
  Future<void> resetChatStorage() async {
    await _detachStorageForRecovery();
    try {
      final recovery = await _recoveryService();
      await recovery.resetToFreshDatabase();
      await _clearAllAgentRunCheckpoints();
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
      await _clearAllAgentRunCheckpoints();
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
    await _afterClearRows(deleteUploads: true);
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
  ///
  /// Uploads are preserved. A full reset uses [clearAllData], and a
  /// file-inclusive restore replaces `upload/` only inside the restore's file
  /// section after the archive has been validated and extracted.
  Future<void> clearAllChatRows() async {
    if (!_initialized) return;
    await _storage!.clearAllRows();
    await _afterClearRows(deleteUploads: false);
  }

  Future<void> _clearAgentRunCheckpoint(String conversationId) async {
    try {
      await AgentRunCheckpointStore.instance.delete(conversationId);
    } catch (_) {}
  }

  Future<void> _clearAllAgentRunCheckpoints() async {
    try {
      await AgentRunCheckpointStore.instance.clearAll();
    } catch (_) {}
  }

  Future<void> _afterClearRows({required bool deleteUploads}) async {
    _draftConversations.clear();
    _draftWorkspaceConfigs.clear();
    _currentConversationId = null;
    await _clearAllAgentRunCheckpoints();
    // Shell outputs are keyed by conversation id and are not part of a chat
    // backup. A reset or restore must remove them so old output_file paths
    // cannot reappear in a restored conversation.
    await SessionOutputs.clearAll();
    if (deleteUploads) {
      try {
        final uploadDir = await AppDirectories.getUploadDirectory();
        if (await uploadDir.exists()) {
          await uploadDir.delete(recursive: true);
        }
      } catch (_) {}
    }
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
    _restoreFuture = null;
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
