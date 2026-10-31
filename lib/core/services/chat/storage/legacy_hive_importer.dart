import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show DoUpdate, Value;
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import '../../../models/file_record.dart';
import '../../../models/workspace_config.dart';
import 'app_database.dart';
import 'chat_database_files.dart';
import 'chat_maintenance_lock.dart';
import 'chat_repository.dart';
import 'database_family_publisher.dart';
import 'hive_open_boundary.dart';
import 'message_part_codec.dart';

class LegacyMigrationException implements Exception {
  const LegacyMigrationException(
    this.message, {
    this.validationFailures = const <String>[],
    this.tempPath,
  });

  final String message;
  final List<String> validationFailures;
  final String? tempPath;

  @override
  String toString() {
    final detail = validationFailures.isEmpty
        ? ''
        : '\n  - ${validationFailures.join('\n  - ')}';
    return 'LegacyMigrationException: $message$detail';
  }
}

class LegacyMigrationResult {
  const LegacyMigrationResult({
    required this.receipt,
    required this.targetProbe,
    required this.validationMode,
    required this.quarantineCount,
    required this.state,
  });

  final Map<String, dynamic> receipt;
  final DatabaseProbe targetProbe;
  final String validationMode;
  final int quarantineCount;
  final String state;
}

/// One-time copy-then-swap import of the chat Hive boxes into
/// `chat_v2.sqlite` (§7/§8).
///
/// The temp database is disposable: an interrupted run is discarded and the
/// next run restarts from Hive. Hive is never modified or deleted.
class LegacyHiveImporter {
  LegacyHiveImporter({
    required this.hiveDirectory,
    required this.files,
    required this.appVersion,
    this.backupChoice = 'skipped',
    this.backupArtifact,
    this.fullValidationThresholdBytes = 64 * 1024 * 1024,
    int? validationSeed,
    this.allowReplaceExistingDatabase = false,
    this.onProgress,
  }) : validationSeed = validationSeed ?? Random.secure().nextInt(0x7fffffff);

  final Directory hiveDirectory;
  final ChatDatabaseFiles files;
  final String appVersion;
  final String backupChoice;
  final String? backupArtifact;
  final int fullValidationThresholdBytes;
  final int validationSeed;

  /// Explicit legacy-import actions may pass `true` after the user confirms
  /// that the current live database will be replaced. The normal startup path
  /// never does, so a second run cannot silently overwrite post-migration data.
  final bool allowReplaceExistingDatabase;

  final void Function(String stage, ChatStorageCounts? counts)? onProgress;

  static const List<String> _boxNames = <String>[
    'conversations',
    'messages',
    'tool_events_v1',
    'message_file_records_v1',
    'conversation_workspace_bindings_v2',
    'conversation_workspaces_v1',
  ];

  LazyBox<Conversation>? _conversationsBox;
  LazyBox<ChatMessage>? _messagesBox;
  LazyBox<dynamic>? _toolEventsBox;
  LazyBox<dynamic>? _fileRecordsBox;
  LazyBox<dynamic>? _workspaceV2Box;
  LazyBox<dynamic>? _workspaceV1Box;
  final List<LazyBox<dynamic>> _openedBoxes = <LazyBox<dynamic>>[];

  final Set<String> _conversationIds = <String>{};
  final Set<String> _importedMessageIds = <String>{};
  final Set<String> _importedToolEventKeys = <String>{};
  final Set<String> _importedFileRecordKeys = <String>{};
  final Set<String> _importedSignatureKeys = <String>{};
  final Map<String, List<String>> _expectedMessageIds =
      <String, List<String>>{};
  final Map<String, String> _sourceMessageHashes = <String, String>{};
  final Map<String, List<String>> _sourcePartHashes = <String, List<String>>{};

  int _sourceConversations = 0;
  int _synthesizedConversations = 0;
  int _sourceMessages = 0;
  int _sourceEventElements = 0;
  int _quarantinedEventElements = 0;
  int _sourceSignatureKeys = 0;
  int _quarantinedSignatures = 0;
  int _sourceFileRecords = 0;
  int _quarantinedFileRecords = 0;
  int _duplicateFileRecords = 0;
  int _duplicateMessageReferences = 0;
  int _missingMessageReferences = 0;
  int _conversationIdRepairs = 0;
  final Set<String> _sourceWorkspaceConversationIds = <String>{};
  int _expectedWorkspaceBindings = 0;
  int _quarantinedWorkspaceBindings = 0;
  ChatStorageCounts? _lastCounts;

  int _sourceMessageContentBytes = 0;
  int _sourcePartContentBytes = 0;
  int _sourceArgumentBytes = 0;

  final List<String> _issues = <String>[];
  final DateTime _startedAt = DateTime.now().toUtc();

  Future<LegacyMigrationResult> run() async {
    final lock = await ChatMaintenanceLock.acquire(
      files.directory,
      purpose: 'hive-migration',
    );
    try {
      return await _runLocked();
    } finally {
      await lock.release();
    }
  }

  Future<LegacyMigrationResult> _runLocked() async {
    if (!await hiveDirectory.exists()) {
      throw const LegacyMigrationException('Hive directory does not exist.');
    }
    if (!await files.directory.exists()) {
      await files.directory.create(recursive: true);
    }
    if (await files.publishIntent.exists()) {
      throw const LegacyMigrationException(
        'A publish intent is pending; the installation gate must recover it '
        'before a new import starts.',
      );
    }

    if (!allowReplaceExistingDatabase) {
      final existing = await probeDatabase(files.database);
      if (existing.readable && existing.migrationComplete) {
        throw LegacyMigrationException(
          'A published chat database already exists '
          '(source=${existing.source ?? 'unknown'}, '
          'state=${existing.state ?? 'unknown'}); refusing to import Hive over '
          'it. Use the explicit legacy-import action to replace it.',
        );
      }
    }

    await _checkFreeSpace();

    var validationMode = 'full';
    var quarantineCount = 0;
    var state = 'complete_clean';

    try {
      // Opening happens inside the try so a corrupt later box still closes
      // the boxes opened before it instead of leaving Hive file locks behind.
      onProgress?.call('opening-hive', null);
      await _openHiveBoxes();

      // The temp database is disposable; always start from Hive. If the
      // old temp survived deletion, opening it could mix two imports, so
      // abort rather than trust the result.
      await files.deleteFamily(files.migrating);
      if (await files.migrating.exists() ||
          await File('${files.migrating.path}-wal').exists() ||
          await File('${files.migrating.path}-shm').exists()) {
        throw LegacyMigrationException(
          'Could not remove the stale temporary database; nothing was '
          'published and Hive was not modified.',
        );
      }

      final db = AppDatabase.open(
        files.migrating,
        background: false,
        synchronousFull: true,
      );
      try {
        await db.verifyHealthy();
        final repository = ChatRepository(db);

        onProgress?.call('importing-messages', null);
        await _importConversations(repository);
        await _importOrphanMessages(repository);
        onProgress?.call('importing-tool-events', null);
        await _importRemainingToolEvents(repository);
        await _importRemainingSignatures(repository);
        await _importRemainingFileRecords(repository);
        onProgress?.call('importing-workspaces', null);
        await _importWorkspaces(repository);
        await repository.repairStaleStreaming();

        onProgress?.call('validating', null);
        final validation = await _validate(repository);
        final counts = await repository.counts();
        _lastCounts = counts;
        final sums = await repository.payloadByteSums();
        onProgress?.call('validating', counts);

        quarantineCount = counts.quarantined;
        state = quarantineCount == 0
            ? 'complete_clean'
            : 'complete_with_issues';
        final databaseId = const Uuid().v4();
        final publishId = const Uuid().v4();
        validationMode = validation.mode;

        final destinationCounts = counts.toJson();
        final sourceCounts = <String, int>{
          'conversations': _sourceConversations,
          'synthesized_conversations': _synthesizedConversations,
          'messages': _sourceMessages,
          'tool_event_elements': _sourceEventElements,
          'signature_keys': _sourceSignatureKeys,
          'file_records': _sourceFileRecords,
          'workspace_conversations': _sourceWorkspaceConversationIds.length,
          'duplicate_message_references': _duplicateMessageReferences,
          'missing_message_references': _missingMessageReferences,
          'conversation_id_repairs': _conversationIdRepairs,
          'duplicate_file_records': _duplicateFileRecords,
        };
        final meta = <String, String>{
          'database_id': databaseId,
          'publish_id': publishId,
          'source': 'hive',
          'state': state,
          'installed_schema_version': '$currentChatSchemaVersion',
          'installed_by_app_version': appVersion,
          'quarantine_count': '$quarantineCount',
          'backup': backupChoice,
          if (backupArtifact != null) 'backup_artifact': backupArtifact!,
          'started_at_utc': _startedAt.toIso8601String(),
          'completed_at_utc': DateTime.now().toUtc().toIso8601String(),
          'validation_mode': validationMode,
          'validation_threshold_bytes': '$fullValidationThresholdBytes',
          'validation_seed': '$validationSeed',
          'source_counts_json': jsonEncode(sourceCounts),
          'destination_counts_json': jsonEncode(destinationCounts),
          'source_payload_sums_json': jsonEncode(<String, int>{
            'message_content_bytes': _sourceMessageContentBytes,
            'part_content_bytes': _sourcePartContentBytes,
            'argument_bytes': _sourceArgumentBytes,
          }),
          'destination_payload_sums_json': jsonEncode(sums.toJson()),
          'issues_json': jsonEncode(_issues),
        };
        await repository.putMigrationMeta(meta);
        await db.checkpointAndTruncate();
      } finally {
        await db.close();
      }
      if (!await files.ensureNoSidecars(files.migrating)) {
        throw LegacyMigrationException(
          'Temp database still has a non-empty WAL after close; refusing to '
          'publish.',
          tempPath: files.migrating.path,
        );
      }

      final publisher = DatabaseFamilyPublisher(files, appVersion: appVersion);
      final outcome = await publisher.publish(
        temp: files.migrating,
        operation: 'migrate',
      );
      if (!outcome.success) {
        throw LegacyMigrationException(
          'Publication failed: ${outcome.error}',
          tempPath: files.migrating.path,
        );
      }

      final receipt = <String, dynamic>{
        'format': 1,
        'databaseId': outcome.publishId.isEmpty
            ? null
            : outcome.targetProbe.databaseId,
        'publishId': outcome.publishId,
        'source': 'hive',
        'sourceBoxes': _boxNames,
        'backup': backupChoice,
        'backupArtifact': backupArtifact,
        'startedAtUtc': _startedAt.toIso8601String(),
        'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'sourceCounts': <String, int>{
          'conversations': _sourceConversations,
          'synthesized_conversations': _synthesizedConversations,
          'messages': _sourceMessages,
          'tool_event_elements': _sourceEventElements,
          'signature_keys': _sourceSignatureKeys,
          'file_records': _sourceFileRecords,
          'workspace_conversations': _sourceWorkspaceConversationIds.length,
          'duplicate_message_references': _duplicateMessageReferences,
          'missing_message_references': _missingMessageReferences,
          'conversation_id_repairs': _conversationIdRepairs,
          'duplicate_file_records': _duplicateFileRecords,
        },
        'destinationCounts': _lastCounts?.toJson(),
        'payloadBytes': <String, int>{
          'source_message_content': _sourceMessageContentBytes,
          'source_part_content': _sourcePartContentBytes,
          'source_arguments': _sourceArgumentBytes,
        },
        'validation': <String, dynamic>{
          'mode': validationMode,
          'thresholdBytes': fullValidationThresholdBytes,
          'seed': validationSeed,
          'issues': _issues,
        },
        'quarantineCount': quarantineCount,
        'state': state,
        'publication': <String, dynamic>{
          'verified': true,
          'schemaVersion': outcome.targetProbe.userVersion,
          'previousPath': outcome.previousPath,
        },
        'appVersion': appVersion,
      };
      await files.writeJsonAtomically(files.migrationReceipt, receipt);

      return LegacyMigrationResult(
        receipt: receipt,
        targetProbe: outcome.targetProbe,
        validationMode: validationMode,
        quarantineCount: quarantineCount,
        state: state,
      );
    } finally {
      await _closeHiveBoxes();
    }
  }

  // ---------------------------------------------------------------------------
  // Hive access
  // ---------------------------------------------------------------------------

  Future<void> _openHiveBoxes() async {
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ConversationAdapter());
    }
    Hive.init(hiveDirectory.path);

    _conversationsBox = await _openIfExists<Conversation>('conversations');
    _messagesBox = await _openIfExists<ChatMessage>('messages');
    _toolEventsBox = await _openIfExists<dynamic>('tool_events_v1');
    _fileRecordsBox = await _openIfExists<dynamic>('message_file_records_v1');
    _workspaceV2Box = await _openIfExists<dynamic>(
      'conversation_workspace_bindings_v2',
    );
    _workspaceV1Box = await _openIfExists<dynamic>(
      'conversation_workspaces_v1',
    );
  }

  Future<LazyBox<T>?> _openIfExists<T>(String name) async {
    final boxFile = File(
      '${hiveDirectory.path}${Platform.pathSeparator}$name.hive',
    );
    if (!await boxFile.exists()) return null;
    // crashRecovery would rewrite a damaged box. Migration must keep Hive
    // byte-identical; a corrupt box aborts instead of being repaired. The
    // boundary also settles Hive's internal open-completer error, which can
    // otherwise escape as an unhandled asynchronous error (R5).
    final outcome = await HiveOpenBoundary.run<LazyBox<T>>(
      () => Hive.openLazyBox<T>(
        name,
        path: hiveDirectory.path,
        crashRecovery: false,
      ),
    );
    if (!outcome.succeeded) {
      final opened = outcome.value;
      if (opened != null) {
        try {
          await opened.close();
        } catch (_) {}
      }
      final cause = outcome.primaryError ?? 'unknown Hive error';
      throw LegacyMigrationException(
        'Cannot open Hive box $name: $cause. Hive was not modified. If this '
        'persists, copy/export the legacy chat files before attempting '
        'recovery.',
      );
    }
    final box = outcome.value!;
    _openedBoxes.add(box);
    return box;
  }

  Future<void> _closeHiveBoxes() async {
    for (final box in _openedBoxes) {
      try {
        await box.close();
      } catch (_) {}
    }
    _openedBoxes.clear();
  }

  // ---------------------------------------------------------------------------
  // Import pass
  // ---------------------------------------------------------------------------

  Future<void> _importConversations(ChatRepository repository) async {
    final box = _conversationsBox;
    if (box == null) return;
    final keys = box.keys.toList();
    for (var start = 0; start < keys.length; start += 64) {
      final end = min(start + 64, keys.length);
      for (var i = start; i < end; i++) {
        final key = keys[i];
        Conversation? conversation;
        try {
          conversation = await box.get(key);
        } catch (e) {
          throw LegacyMigrationException(
            'Cannot decode a Hive conversation record (key $key). Hive was '
            'not modified.',
          );
        }
        if (conversation == null) continue;
        if (_conversationIds.contains(conversation.id)) {
          _issues.add('duplicate conversation id ${conversation.id}');
          continue;
        }
        _sourceConversations++;
        _conversationIds.add(conversation.id);
        final convo = conversation;
        onProgress?.call('importing-conversations', null);
        await repository.db.transaction(() async {
          await repository.upsertConversation(convo);
          await _importConversationMessages(repository, convo);
        });
      }
      onProgress?.call('importing-conversations', null);
    }
  }

  Future<void> _importConversationMessages(
    ChatRepository repository,
    Conversation conversation,
  ) async {
    final expected = <String>[];
    final seen = <String>{};
    var ordinal = 0;

    for (final rawId in conversation.messageIds) {
      if (!seen.add(rawId)) {
        _issues.add(
          'duplicate message reference $rawId in '
          '${conversation.id}',
        );
        continue;
      }
      final message = _messagesBox == null ? null : await _getMessage(rawId);
      if (message == null) {
        _missingMessageReferences++;
        _issues.add('missing message $rawId referenced by ${conversation.id}');
        continue;
      }
      if (_importedMessageIds.contains(message.id)) {
        _duplicateMessageReferences++;
        _issues.add(
          'message ${message.id} is referenced by more than one conversation',
        );
        continue;
      }

      var normalized = message;
      if (message.conversationId != conversation.id) {
        _conversationIdRepairs++;
        _issues.add(
          'message ${message.id} claimed conversation '
          '${message.conversationId}; attached to ${conversation.id}',
        );
        normalized = message.copyWith(conversationId: conversation.id);
      }
      normalized = normalized.copyWith(isStreaming: false);

      _recordMessageSource(normalized);
      await repository.insertMessageAt(normalized, ordinal);
      await _importPartData(repository, normalized);
      expected.add(normalized.id);
      _importedMessageIds.add(normalized.id);
      ordinal++;
    }
    _expectedMessageIds[conversation.id] = expected;
  }

  Future<ChatMessage?> _getMessage(String id) async {
    try {
      return await _messagesBox?.get(id);
    } catch (e) {
      throw LegacyMigrationException(
        'Cannot decode Hive message $id. Hive was not modified.',
      );
    }
  }

  void _recordMessageSource(ChatMessage message) {
    _sourceMessages++;
    _sourceMessageContentBytes += utf8Length(message.content);
    _sourceMessageHashes[message.id] = _hashString(message.content);
    _partHashesFor(message.id);
  }

  List<String> _partHashesFor(String messageId) =>
      _sourcePartHashes.putIfAbsent(messageId, () => <String>[]);

  Future<void> _importPartData(
    ChatRepository repository,
    ChatMessage message,
  ) async {
    final isAssistant = message.role == 'assistant';

    final toolBox = _toolEventsBox;
    if (isAssistant && toolBox != null) {
      try {
        final raw = await toolBox.get(message.id);
        _importedToolEventKeys.add(message.id);
        if (raw != null) {
          await _importToolEventPayload(repository, message.id, raw);
        }
      } on LegacyMigrationException {
        rethrow;
      } catch (e) {
        throw LegacyMigrationException(
          'Cannot decode tool events for ${message.id}: $e. '
          'Hive was not modified.',
        );
      }
    }

    final signatureKey = 'sig_${message.id}';
    final signatureBox = _toolEventsBox;
    if (isAssistant && signatureBox != null) {
      try {
        final signature = await signatureBox.get(signatureKey);
        _importedSignatureKeys.add(signatureKey);
        if (signature != null) {
          _sourceSignatureKeys++;
          if (signature is String && signature.trim().isNotEmpty) {
            await repository.setProviderArtifact(
              message.id,
              kGeminiThoughtSignatureKind,
              signature,
            );
          } else {
            await _quarantine(
              repository,
              sourceBox: 'tool_events_v1',
              sourceKey: signatureKey,
              payload: signature,
              error: 'gemini signature is not a non-empty string',
            );
            _quarantinedSignatures++;
          }
        }
      } on LegacyMigrationException {
        rethrow;
      } catch (e) {
        throw LegacyMigrationException(
          'Cannot decode the Gemini signature for ${message.id}: $e. '
          'Hive was not modified.',
        );
      }
    }

    final recordsBox = _fileRecordsBox;
    if (recordsBox != null) {
      try {
        final raw = await recordsBox.get(message.id);
        _importedFileRecordKeys.add(message.id);
        if (raw is List) {
          await _importFileRecordList(repository, message.id, raw);
        } else if (raw != null) {
          _sourceFileRecords++;
          await _quarantine(
            repository,
            sourceBox: 'message_file_records_v1',
            sourceKey: message.id,
            payload: raw,
            error: 'file record value is not a list',
          );
          _quarantinedFileRecords++;
        }
      } on LegacyMigrationException {
        rethrow;
      } catch (e) {
        throw LegacyMigrationException(
          'Cannot decode file records for ${message.id}: $e. '
          'Hive was not modified.',
        );
      }
    }
  }

  Future<void> _importToolEventPayload(
    ChatRepository repository,
    String messageId,
    dynamic raw,
  ) async {
    if (raw is! List) {
      _sourceEventElements++;
      _quarantinedEventElements++;
      await _quarantine(
        repository,
        sourceBox: 'tool_events_v1',
        sourceKey: messageId,
        payload: raw,
        error: 'tool event value is not a list',
      );
      _issues.add('tool events for $messageId are not a list');
      return;
    }

    for (var i = 0; i < raw.length; i++) {
      final element = raw[i];
      _sourceEventElements++;
      if (element is! Map) {
        _quarantinedEventElements++;
        await _quarantine(
          repository,
          sourceBox: 'tool_events_v1',
          sourceKey: '$messageId#$i',
          payload: element,
          error: 'tool event element is not a map',
        );
        _issues.add('tool event $messageId#$i is not a map');
        continue;
      }
      final draft = toolPartDraftFromLegacyEvent(element);
      await repository.db
          .into(repository.db.messageParts)
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
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      _sourcePartContentBytes += utf8Length(draft.content);
      _sourceArgumentBytes += utf8Length(draft.argumentsJson);
      _partHashesFor(messageId).add(_partDraftFingerprint(draft));
    }
  }

  Future<void> _importFileRecordList(
    ChatRepository repository,
    String messageId,
    List<dynamic> raw,
  ) async {
    final seenPaths = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final element = raw[i];
      _sourceFileRecords++;
      if (element is! Map) {
        _quarantinedFileRecords++;
        await _quarantine(
          repository,
          sourceBox: 'message_file_records_v1',
          sourceKey: '$messageId#$i',
          payload: element,
          error: 'file record element is not a map',
        );
        continue;
      }
      FileRecord record;
      try {
        record = FileRecord.fromJson(
          element.map((key, value) => MapEntry(key.toString(), value)),
        );
      } catch (e) {
        _quarantinedFileRecords++;
        await _quarantine(
          repository,
          sourceBox: 'message_file_records_v1',
          sourceKey: '$messageId#$i',
          payload: element,
          error: 'cannot decode file record: $e',
        );
        continue;
      }
      if (!seenPaths.add(record.path)) {
        _duplicateFileRecords++;
        _issues.add('duplicate file record ${record.path} for $messageId');
        continue;
      }
      await repository.db
          .into(repository.db.messageFileRecords)
          .insert(
            MessageFileRecordsCompanion.insert(
              messageId: messageId,
              ordinal: i,
              path: record.path,
              fileName: Value(record.fileName),
              sizeBytes: Value(record.sizeBytes),
              createdAtMs: record.createdAt.millisecondsSinceEpoch,
            ),
            onConflict: DoUpdate(
              (_) => MessageFileRecordsCompanion(
                ordinal: Value(i),
                fileName: Value(record.fileName),
                sizeBytes: Value(record.sizeBytes),
                createdAtMs: Value(record.createdAt.millisecondsSinceEpoch),
              ),
              target: [
                repository.db.messageFileRecords.messageId,
                repository.db.messageFileRecords.path,
              ],
            ),
          );
    }
  }

  Future<void> _importOrphanMessages(ChatRepository repository) async {
    final box = _messagesBox;
    if (box == null) return;
    final keys = box.keys.toList();
    final orphans = <String, List<ChatMessage>>{};

    for (final key in keys) {
      ChatMessage? message;
      try {
        message = await box.get(key);
      } catch (e) {
        throw LegacyMigrationException(
          'Cannot decode Hive message $key. Hive was not modified.',
        );
      }
      if (message == null) continue;
      if (_importedMessageIds.contains(message.id)) continue;
      if (_sourceMessageHashes.containsKey(message.id)) continue;
      _recordMessageSource(message);
      final target = message.conversationId.isEmpty
          ? '__orphan__'
          : message.conversationId;
      (orphans[target] ??= <ChatMessage>[]).add(message);
    }

    for (final entry in orphans.entries) {
      final sourceConversationId = entry.key;
      final messages = entry.value;
      String conversationId;
      var recovered = false;
      if (sourceConversationId != '__orphan__' &&
          _conversationIds.contains(sourceConversationId)) {
        conversationId = sourceConversationId;
      } else {
        conversationId = sourceConversationId == '__orphan__'
            ? const Uuid().v4()
            : sourceConversationId;
        recovered = true;
        final timestamps = messages.map((m) => m.timestamp).toList()..sort();
        final recoveredConversation = Conversation(
          id: conversationId,
          title: 'Recovered messages',
          createdAt: timestamps.first,
          updatedAt: timestamps.last,
        );
        _synthesizedConversations++;
        _issues.add(
          'created recovered conversation $conversationId for '
          '${messages.length} orphan message(s)',
        );
        await repository.upsertConversation(
          recoveredConversation,
          isRecovered: true,
        );
        _conversationIds.add(conversationId);
      }

      await repository.db.transaction(() async {
        var ordinal = recovered
            ? 0
            : await repository.maxMessageOrdinal(conversationId) + 1;
        final expected = _expectedMessageIds.putIfAbsent(
          conversationId,
          () => <String>[],
        );
        for (final message in messages) {
          if (_importedMessageIds.contains(message.id)) continue;
          final normalized = message.copyWith(
            conversationId: conversationId,
            isStreaming: false,
          );
          await repository.insertMessageAt(normalized, ordinal);
          await _importPartData(repository, normalized);
          _importedMessageIds.add(normalized.id);
          expected.add(normalized.id);
          ordinal++;
        }
      });
      _issues.add(
        'attached ${messages.length} orphan message(s) to $conversationId',
      );
    }
  }

  Future<void> _importRemainingToolEvents(ChatRepository repository) async {
    final box = _toolEventsBox;
    if (box == null) return;
    for (final key in box.keys) {
      final keyString = key.toString();
      if (keyString.startsWith('sig_')) continue;
      if (_importedToolEventKeys.contains(keyString)) continue;
      final raw = await box.get(key);
      final elementCount = raw is List ? raw.length : 1;
      _sourceEventElements += elementCount;
      _quarantinedEventElements += elementCount;
      await _quarantine(
        repository,
        sourceBox: 'tool_events_v1',
        sourceKey: keyString,
        payload: raw,
        error: 'tool events reference a missing message',
        payloadUnavailable: raw == null,
      );
      _issues.add('quarantined tool events for missing message $keyString');
    }
  }

  Future<void> _importRemainingSignatures(ChatRepository repository) async {
    final box = _toolEventsBox;
    if (box == null) return;
    for (final key in box.keys) {
      final keyString = key.toString();
      if (!keyString.startsWith('sig_')) continue;
      if (_importedSignatureKeys.contains(keyString)) continue;
      final raw = await box.get(key);
      _sourceSignatureKeys++;
      _quarantinedSignatures++;
      await _quarantine(
        repository,
        sourceBox: 'tool_events_v1',
        sourceKey: keyString,
        payload: raw,
        error: 'signature references a missing message',
        payloadUnavailable: raw == null,
      );
    }
  }

  Future<void> _importRemainingFileRecords(ChatRepository repository) async {
    final box = _fileRecordsBox;
    if (box == null) return;
    for (final key in box.keys) {
      final keyString = key.toString();
      if (_importedFileRecordKeys.contains(keyString)) continue;
      dynamic raw;
      try {
        raw = await box.get(key);
      } catch (e) {
        throw LegacyMigrationException(
          'Cannot decode file records for missing message $keyString: $e. '
          'Hive was not modified.',
        );
      }
      final length = raw is List ? raw.length : 1;
      _sourceFileRecords += length;
      _quarantinedFileRecords += length;
      await _quarantine(
        repository,
        sourceBox: 'message_file_records_v1',
        sourceKey: keyString,
        payload: raw,
        error: 'file records reference a missing message',
      );
    }
  }

  Future<void> _importWorkspaces(ChatRepository repository) async {
    final handled = <String>{};

    final v2 = _workspaceV2Box;
    if (v2 != null) {
      for (final key in v2.keys) {
        final conversationId = key.toString();
        handled.add(conversationId);
        final raw = await v2.get(key);
        if (!_conversationIds.contains(conversationId)) {
          _quarantinedWorkspaceBindings++;
          await _quarantine(
            repository,
            sourceBox: 'conversation_workspace_bindings_v2',
            sourceKey: conversationId,
            payload: raw,
            error: 'workspace binding references a missing conversation',
          );
          continue;
        }
        _sourceWorkspaceConversationIds.add(conversationId);
        try {
          final config = WorkspaceConfig.fromJson(raw);
          await repository.setWorkspaceBinding(conversationId, config);
          _expectedWorkspaceBindings++;
        } catch (e) {
          _quarantinedWorkspaceBindings++;
          await _quarantine(
            repository,
            sourceBox: 'conversation_workspace_bindings_v2',
            sourceKey: conversationId,
            payload: raw,
            error: 'cannot decode workspace binding: $e',
          );
        }
      }
    }

    final v1 = _workspaceV1Box;
    if (v1 != null) {
      for (final key in v1.keys) {
        final conversationId = key.toString();
        if (handled.contains(conversationId)) continue;
        final raw = await v1.get(key);
        if (raw is! String || raw.trim().isEmpty) continue;
        if (!_conversationIds.contains(conversationId)) {
          _quarantinedWorkspaceBindings++;
          await _quarantine(
            repository,
            sourceBox: 'conversation_workspaces_v1',
            sourceKey: conversationId,
            payload: raw,
            error: 'legacy workspace path references a missing conversation',
          );
          continue;
        }
        _sourceWorkspaceConversationIds.add(conversationId);
        await repository.setWorkspaceBinding(
          conversationId,
          WorkspaceConfig.custom(raw.trim()),
        );
        _expectedWorkspaceBindings++;
      }
    }
  }

  Future<void> _quarantine(
    ChatRepository repository, {
    required String sourceBox,
    required String? sourceKey,
    required dynamic payload,
    required String error,
    bool payloadUnavailable = false,
  }) async {
    String? payloadJson;
    String? payloadSha;
    if (!payloadUnavailable && payload != null) {
      try {
        payloadJson = canonicalJsonEncode(payload);
        payloadSha = _hashString(payloadJson);
      } catch (_) {
        payloadJson = payload.toString();
        payloadSha = _hashString(payloadJson);
      }
    }
    await repository.insertQuarantine(
      sourceBox: sourceBox,
      sourceKey: sourceKey,
      payloadJson: payloadJson,
      payloadSha256: payloadSha,
      error: error,
    );
  }

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  Future<_ValidationOutcome> _validate(ChatRepository repository) async {
    final failures = <String>[];
    final counts = await repository.counts();
    final sums = await repository.payloadByteSums();

    final expectedConversations =
        _sourceConversations + _synthesizedConversations;
    if (counts.conversations != expectedConversations) {
      failures.add(
        'conversations: destination ${counts.conversations} != '
        'source $expectedConversations',
      );
    }
    if (counts.messages != _sourceMessages) {
      failures.add(
        'messages: destination ${counts.messages} != source $_sourceMessages',
      );
    }
    if (counts.parts != _sourceEventElements - _quarantinedEventElements) {
      failures.add(
        'parts: destination ${counts.parts} != source '
        '${_sourceEventElements - _quarantinedEventElements}',
      );
    }
    if (counts.providerArtifacts !=
        _sourceSignatureKeys - _quarantinedSignatures) {
      failures.add(
        'provider artifacts: destination ${counts.providerArtifacts} != '
        'source ${_sourceSignatureKeys - _quarantinedSignatures}',
      );
    }
    if (counts.fileRecords !=
        _sourceFileRecords - _quarantinedFileRecords - _duplicateFileRecords) {
      failures.add(
        'file records: destination ${counts.fileRecords} != source '
        '${_sourceFileRecords - _quarantinedFileRecords - _duplicateFileRecords}',
      );
    }
    if (counts.workspaceBindings != _expectedWorkspaceBindings) {
      failures.add(
        'workspace bindings: destination ${counts.workspaceBindings} != '
        'successfully imported $_expectedWorkspaceBindings',
      );
    }
    if (counts.workspaceBindings + _quarantinedWorkspaceBindings <
        _sourceWorkspaceConversationIds.length) {
      failures.add(
        'workspace bindings: ${counts.workspaceBindings} imported + '
        '$_quarantinedWorkspaceBindings quarantined < '
        '${_sourceWorkspaceConversationIds.length} source conversations',
      );
    }

    if (sums.messageContentBytes != _sourceMessageContentBytes) {
      failures.add(
        'message content UTF-8 bytes: destination '
        '${sums.messageContentBytes} != source $_sourceMessageContentBytes',
      );
    }
    if (sums.partContentBytes != _sourcePartContentBytes) {
      failures.add(
        'tool content UTF-8 bytes: destination ${sums.partContentBytes} != '
        'source $_sourcePartContentBytes',
      );
    }
    if (sums.argumentBytes != _sourceArgumentBytes) {
      failures.add(
        'arguments UTF-8 bytes: destination ${sums.argumentBytes} != '
        'source $_sourceArgumentBytes',
      );
    }

    final duplicates = <String>[
      ...await repository.duplicateMessageOrdinals(),
      ...await repository.duplicatePartOrdinals(),
    ];
    if (duplicates.isNotEmpty) {
      failures.add('duplicate ordinals: ${duplicates.join(', ')}');
    }

    final invalidIndexes = await repository.invalidConversationIndexes();
    if (invalidIndexes.isNotEmpty) {
      failures.add(
        'invalid truncate/compact indices: ${invalidIndexes.join(', ')}',
      );
    }

    // Hydrated messageIds order must match the source after skipped refs.
    for (final entry in _expectedMessageIds.entries) {
      final destination = await repository.messageIdsFor(entry.key);
      if (!_listEquals(destination, entry.value)) {
        failures.add(
          'messageIds order mismatch for ${entry.key}: '
          '${entry.value.length} expected, ${destination.length} stored',
        );
      }
    }

    // Select validation mode from total decoded content bytes.
    final totalDecoded = _sourceMessageContentBytes + _sourcePartContentBytes;
    final mode = totalDecoded <= fullValidationThresholdBytes
        ? 'full'
        : 'sampled';
    final random = Random(validationSeed);

    final messageIds = _sourceMessageHashes.keys.toList()..sort();
    final partMessageIds =
        _sourcePartHashes.keys
            .where((id) => _sourcePartHashes[id]!.isNotEmpty)
            .toList()
          ..sort();

    Set<String> sampledMessages;
    if (mode == 'full') {
      sampledMessages = messageIds.toSet();
    } else {
      final desired = max(500, (messageIds.length * 0.01).ceil());
      final shuffled = List<String>.of(messageIds)..shuffle(random);
      sampledMessages = shuffled.take(min(desired, shuffled.length)).toSet();
    }

    // Always verify at least 100 tool contents explicitly.
    final totalPartCount = _sourcePartHashes.values.fold<int>(
      0,
      (sum, hashes) => sum + hashes.length,
    );
    final mustCompareParts = min(100, totalPartCount);
    final partSample = <String>{};
    if (mode == 'full') {
      partSample.addAll(partMessageIds);
    } else {
      final desiredParts = max(500, (totalPartCount * 0.01).ceil());
      final shuffled = List<String>.of(partMessageIds)..shuffle(random);
      var selectedParts = 0;
      for (final messageId in shuffled) {
        if (selectedParts >= desiredParts) break;
        partSample.add(messageId);
        selectedParts += _sourcePartHashes[messageId]!.length;
      }
      // The first 100 tool contents by message order are always compared.
      var guaranteed = 0;
      for (final messageId in partMessageIds) {
        if (guaranteed >= mustCompareParts) break;
        partSample.add(messageId);
        guaranteed += _sourcePartHashes[messageId]!.length;
      }
    }

    var comparedParts = 0;
    final allPartMessages = partSample.toList()..sort();
    for (var start = 0; start < allPartMessages.length; start += 200) {
      final chunk = allPartMessages.sublist(
        start,
        min(start + 200, allPartMessages.length),
      );
      final rows = await repository.allPartsBatch(chunk);
      final byMessage = <String, List<String>>{};
      for (final row in rows) {
        if (row.kind != kToolPartKind) continue;
        (byMessage[row.messageId] ??= <String>[]).add(_partRowFingerprint(row));
      }
      for (final messageId in chunk) {
        final expected = _sourcePartHashes[messageId] ?? const <String>[];
        final actual = byMessage[messageId] ?? const <String>[];
        if (!_listEquals(actual, expected)) {
          failures.add(
            'tool part hash mismatch for $messageId '
            '(${expected.length} expected, ${actual.length} stored)',
          );
          continue;
        }
        comparedParts += expected.length;
      }
    }
    if (comparedParts < mustCompareParts) {
      failures.add(
        'only $comparedParts tool contents were compared; '
        'at least $mustCompareParts are required',
      );
    }

    // Message content hashes (byte-for-byte).
    for (final messageId in sampledMessages) {
      final message = await repository.getMessage(messageId);
      if (message == null) {
        failures.add('message $messageId is missing after import');
        continue;
      }
      if (_hashString(message.content) != _sourceMessageHashes[messageId]) {
        failures.add('message content hash mismatch for $messageId');
      }
    }

    final integrityError = await verifySqliteFile(files.migrating);
    if (integrityError != null) {
      failures.add(integrityError);
    }

    if (failures.isNotEmpty) {
      throw LegacyMigrationException(
        'Migration validation failed; nothing was published and Hive was '
        'left untouched.',
        validationFailures: failures,
        tempPath: files.migrating.path,
      );
    }
    return _ValidationOutcome(mode);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _checkFreeSpace() async {
    var hiveBytes = 0;
    for (final name in _boxNames) {
      final file = File(
        '${hiveDirectory.path}${Platform.pathSeparator}$name.hive',
      );
      if (await file.exists()) hiveBytes += await file.length();
    }
    final required = (hiveBytes * 2 * 1.2).ceil();
    final available = await _availableDiskBytes(files.directory.path);
    if (available == null) return;
    if (available < required) {
      throw LegacyMigrationException(
        'Not enough free disk space for migration: '
        '${(required / (1024 * 1024)).toStringAsFixed(1)} MiB required, '
        '${(available / (1024 * 1024)).toStringAsFixed(1)} MiB available.',
      );
    }
  }

  Future<int?> _availableDiskBytes(String path) async {
    try {
      if (Platform.isWindows) {
        final root = Directory(path).absolute.path;
        if (root.length < 2 || root[1] != ':') return null;
        final drive = root[0].toUpperCase();
        final result = await Process.run('powershell', <String>[
          '-NoProfile',
          '-Command',
          "(Get-PSDrive -Name $drive).Free",
        ]);
        if (result.exitCode == 0) {
          final match = RegExp(r'(\d+)').firstMatch(result.stdout.toString());
          if (match != null) return int.tryParse(match.group(1)!);
        }
        return null;
      }
      final result = await Process.run('df', <String>['-k', path]);
      if (result.exitCode != 0) return null;
      final lines = result.stdout.toString().trim().split('\n');
      if (lines.length < 2) return null;
      final fields = lines.last.trim().split(RegExp(r'\s+'));
      if (fields.length < 4) return null;
      final kib = int.tryParse(fields[3]);
      return kib == null ? null : kib * 1024;
    } catch (_) {
      return null;
    }
  }

  String _hashString(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  String _partDraftFingerprint(ToolPartDraft draft) {
    return _hashString(
      canonicalJsonEncode(<String, dynamic>{
        'tool_call_id': draft.toolCallId,
        'tool_name': draft.toolName,
        'arguments': decodeJsonValue(draft.argumentsJson),
        'content': draft.content,
        'status': draft.status,
        'approval_state': draft.approvalState,
        'metadata': decodeJsonValue(draft.metadataJson),
      }),
    );
  }

  String _partRowFingerprint(MessagePartRow row) {
    return _hashString(
      canonicalJsonEncode(<String, dynamic>{
        'tool_call_id': row.toolCallId,
        'tool_name': row.toolName,
        'arguments': decodeJsonValue(row.argumentsJson),
        'content': row.content,
        'status': row.status,
        'approval_state': row.approvalState ?? kApprovalAuto,
        'metadata': decodeJsonValue(row.metadataJson),
      }),
    );
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _ValidationOutcome {
  const _ValidationOutcome(this.mode);

  final String mode;
}
