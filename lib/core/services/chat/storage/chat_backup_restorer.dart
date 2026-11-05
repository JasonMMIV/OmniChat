import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';

import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import '../../../models/file_record.dart';
import '../../../models/workspace_config.dart';
import '../../logging/flutter_logger.dart';
import 'app_database.dart';
import 'chat_database_files.dart';
import 'chat_repository.dart';
import 'database_family_publisher.dart';
import 'message_part_codec.dart';

/// A deliberate restore failure that the UI may present. [stage] is a stable
/// identifier (parse/import/verify/publish/open/rollback), never a message body.
class ChatRestoreException implements Exception {
  const ChatRestoreException(this.stage, this.message, {this.cause});

  final String stage;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'ChatRestoreException($stage): $message${cause == null ? '' : ' ($cause)'}';
}

/// Result of a committed restore. Settings are reported separately because
/// SharedPreferences is not transactional.
class ChatRestoreResult {
  const ChatRestoreResult({
    required this.restoredConversations,
    required this.restoredMessages,
    required this.filesRestored,
    required this.settingsApplied,
    this.settingsError,
  });

  final int restoredConversations;
  final int restoredMessages;
  final bool filesRestored;
  final bool settingsApplied;
  final String? settingsError;
}

/// Parsed and validated contents of `chats.json` plus optional settings.
class ChatBackupPayload {
  const ChatBackupPayload({
    required this.conversations,
    required this.messagesByConversation,
    required this.toolEvents,
    required this.geminiThoughtSigs,
    required this.workspaceBindings,
    required this.fileRecords,
    required this.settings,
    required this.archiveSha256,
  });

  final List<Conversation> conversations;
  final Map<String, List<ChatMessage>> messagesByConversation;
  final Map<String, List<Map<String, dynamic>>> toolEvents;
  final Map<String, String> geminiThoughtSigs;
  final Map<String, WorkspaceConfig> workspaceBindings;
  final Map<String, List<FileRecord>> fileRecords;
  final Map<String, dynamic>? settings;
  final String archiveSha256;

  int get messageCount =>
      messagesByConversation.values.fold(0, (sum, list) => sum + list.length);

  int get partCount =>
      toolEvents.values.fold(0, (sum, list) => sum + list.length);

  int get signatureCount => geminiThoughtSigs.length;

  int get fileRecordCount =>
      fileRecords.values.fold(0, (sum, list) => sum + list.length);

  int get workspaceBindingCount => workspaceBindings.length;
}

/// Builds a complete staging database from an archive, verifies its counts and
/// publishes it through [DatabaseFamilyPublisher]. The live database is never
/// cleared before the publish commit point.
class ChatBackupRestorer {
  ChatBackupRestorer({
    required this.directory,
    required this.appVersion,
  }) : files = ChatDatabaseFiles(directory);

  /// Test seam: throw after N imported conversations (0 disables).
  static int debugFailAfterConversations = 0;

  /// Test seam: runs after a failed publish and before the publisher decides,
  /// so a test can force the fail-closed recovery branch.
  static void Function()? debugAfterPublishFailure;

  final Directory directory;
  final String appVersion;
  final ChatDatabaseFiles files;

  /// True when the archive carries a non-empty `chats.json` entry.
  static Future<bool> containsChats(File archive) async {
    if (!await archive.exists() || await archive.length() == 0) return false;
    InputFileStream? input;
    try {
      input = InputFileStream(archive.path);
      final decoded = ZipDecoder().decodeStream(input);
      final entry = decoded.find('chats.json');
      return entry != null && entry.isFile && entry.size > 0;
    } catch (_) {
      return false;
    } finally {
      try {
        await input?.close();
      } catch (_) {}
    }
  }

  /// Parses the archive without touching the live database. Orphan messages
  /// (a `conversationId` absent from `conversations`) are rejected outright.
  Future<ChatBackupPayload> parseAndValidate(File archive) async {
    if (!await archive.exists()) {
      throw const ChatRestoreException('parse', 'The backup file is missing.');
    }
    if (await archive.length() == 0) {
      throw const ChatRestoreException('parse', 'The backup file is empty.');
    }

    Map<String, dynamic>? chats;
    Map<String, dynamic>? settings;
    InputFileStream? input;
    try {
      input = InputFileStream(archive.path);
      final decoded = ZipDecoder().decodeStream(input);
      final chatsEntry = decoded.find('chats.json');
      if (chatsEntry == null || !chatsEntry.isFile || chatsEntry.size <= 0) {
        throw const ChatRestoreException(
          'parse',
          'This backup does not contain chat history (chats.json).',
        );
      }
      final chatsBytes = chatsEntry.readBytes();
      if (chatsBytes == null || chatsBytes.isEmpty) {
        throw const ChatRestoreException('parse', 'The chat history is empty.');
      }
      final decodedChats = jsonDecode(utf8.decode(chatsBytes));
      if (decodedChats is! Map<String, dynamic> ||
          decodedChats['conversations'] is! List) {
        throw const ChatRestoreException(
          'parse',
          'The backup chats.json is not a valid OmniChat chat export.',
        );
      }
      chats = decodedChats;

      final settingsEntry = decoded.find('settings.json');
      if (settingsEntry != null && settingsEntry.isFile) {
        final settingsBytes = settingsEntry.readBytes();
        if (settingsBytes != null && settingsBytes.isNotEmpty) {
          final decodedSettings = jsonDecode(utf8.decode(settingsBytes));
          if (decodedSettings is Map<String, dynamic>) settings = decodedSettings;
        }
      }
    } on ChatRestoreException {
      rethrow;
    } on FormatException catch (error) {
      throw ChatRestoreException(
        'parse',
        'The backup archive could not be read: $error',
        cause: error,
      );
    } catch (error) {
      throw ChatRestoreException(
        'parse',
        'The backup archive could not be read: $error',
        cause: error,
      );
    } finally {
      try {
        await input?.close();
      } catch (_) {}
    }

    final hash = await sha256File(archive);
    return _parseChats(chats, settings, hash);
  }

  /// Validates a caller-built payload (third-party importers, plan §3 Phase
  /// 1c) with the same rules as [parseAndValidate]: no duplicate conversation
  /// ids, no duplicate message ids, no orphan messages. A payload that
  /// violates these rules would fail the staging count verification anyway;
  /// failing here keeps the error message actionable.
  void validatePayload(ChatBackupPayload payload) {
    final conversationIds = <String>{};
    for (final conversation in payload.conversations) {
      if (!conversationIds.add(conversation.id)) {
        throw ChatRestoreException(
          'parse',
          'The import contains a duplicate conversation id (${conversation.id}).',
        );
      }
    }
    final messageIds = <String>{};
    for (final entry in payload.messagesByConversation.entries) {
      for (final message in entry.value) {
        if (!conversationIds.contains(message.conversationId)) {
          throw ChatRestoreException(
            'parse',
            'The import contains a message whose conversation is missing '
            '(${message.id} -> ${message.conversationId}).',
          );
        }
        if (!messageIds.add(message.id)) {
          throw ChatRestoreException(
            'parse',
            'The import contains a duplicate message id (${message.id}).',
          );
        }
      }
    }
  }

  ChatBackupPayload _parseChats(
    Map<String, dynamic> raw,
    Map<String, dynamic>? settings,
    String archiveHash,
  ) {
    final version = raw['version'];
    if (version != null && (version is! int || version < 1 || version > 3)) {
      throw ChatRestoreException(
        'parse',
        'Unsupported chat export version: $version.',
      );
    }

    final conversations = <Conversation>[];
    final conversationIds = <String>{};
    for (final entry in raw['conversations'] as List) {
      if (entry is! Map) {
        throw const ChatRestoreException(
          'parse',
          'The backup contains an invalid conversation entry.',
        );
      }
      final conversation = Conversation.fromJson(
        entry.cast<String, dynamic>(),
      );
      if (!conversationIds.add(conversation.id)) {
        throw ChatRestoreException(
          'parse',
          'The backup contains a duplicate conversation id (${conversation.id}).',
        );
      }
      conversations.add(conversation);
    }

    final messagesByConversation = <String, List<ChatMessage>>{
      for (final id in conversationIds) id: <ChatMessage>[],
    };
    final messageIds = <String>{};

    final rawMessages = raw['messages'];
    if (rawMessages != null) {
      if (rawMessages is! List) {
        throw const ChatRestoreException(
          'parse',
          'The backup contains an invalid message list.',
        );
      }
      for (final entry in rawMessages) {
        if (entry is! Map) {
          throw const ChatRestoreException(
            'parse',
            'The backup contains an invalid message entry.',
          );
        }
        final message = ChatMessage.fromJson(entry.cast<String, dynamic>());
        if (!conversationIds.contains(message.conversationId)) {
          throw ChatRestoreException(
            'parse',
            'The backup contains a message whose conversation is missing '
            '(${message.id} -> ${message.conversationId}).',
          );
        }
        if (!messageIds.add(message.id)) {
          throw ChatRestoreException(
            'parse',
            'The backup contains a duplicate message id (${message.id}).',
          );
        }
        messagesByConversation[message.conversationId]!.add(message);
      }
    }

    final toolEvents = <String, List<Map<String, dynamic>>>{};
    final rawToolEvents = raw['toolEvents'];
    if (rawToolEvents is Map) {
      for (final entry in rawToolEvents.entries) {
        final messageId = entry.key.toString();
        if (!messageIds.contains(messageId)) continue;
        final value = entry.value;
        if (value is! List) {
          throw ChatRestoreException(
            'parse',
            'Invalid tool events for message $messageId.',
          );
        }
        final events = <Map<String, dynamic>>[];
        for (final event in value) {
          if (event is! Map) {
            throw ChatRestoreException(
              'parse',
              'Invalid tool event for message $messageId.',
            );
          }
          events.add(event.cast<String, dynamic>());
        }
        if (events.isNotEmpty) toolEvents[messageId] = events;
      }
    }

    final signatures = <String, String>{};
    final rawSignatures = raw['geminiThoughtSigs'];
    if (rawSignatures is Map) {
      for (final entry in rawSignatures.entries) {
        final messageId = entry.key.toString();
        if (!messageIds.contains(messageId)) continue;
        final value = entry.value?.toString() ?? '';
        if (value.isNotEmpty) signatures[messageId] = value;
      }
    }

    final workspaceBindings = <String, WorkspaceConfig>{};
    final rawBindings = raw['workspaceBindings'];
    if (rawBindings is Map) {
      for (final entry in rawBindings.entries) {
        final conversationId = entry.key.toString();
        if (!conversationIds.contains(conversationId)) continue;
        final config = WorkspaceConfig.fromJson(entry.value);
        if (config.mode != WorkspaceMode.inheritProject) {
          workspaceBindings[conversationId] = config;
        }
      }
    }
    // Legacy `workspaces` map (conversationId -> path) fills gaps only.
    final rawWorkspaces = raw['workspaces'];
    if (rawWorkspaces is Map) {
      for (final entry in rawWorkspaces.entries) {
        final conversationId = entry.key.toString();
        if (!conversationIds.contains(conversationId)) continue;
        final path = entry.value?.toString().trim() ?? '';
        if (path.isEmpty) continue;
        workspaceBindings.putIfAbsent(
          conversationId,
          () => WorkspaceConfig.custom(path),
        );
      }
    }

    final fileRecords = <String, List<FileRecord>>{};
    final rawFileRecords = raw['fileRecords'];
    if (rawFileRecords is Map) {
      for (final entry in rawFileRecords.entries) {
        final messageId = entry.key.toString();
        if (!messageIds.contains(messageId)) continue;
        final value = entry.value;
        if (value is! List) continue;
        final records = <FileRecord>[];
        for (final record in value) {
          if (record is! Map) continue;
          try {
            records.add(
              FileRecord.fromJson(Map<String, dynamic>.from(record)),
            );
          } catch (_) {
            // A malformed optional record must not block the chat rows.
          }
        }
        if (records.isNotEmpty) fileRecords[messageId] = records;
      }
    }

    FlutterLogger.log(
      'Parsed backup: conversations=${conversations.length} '
      'messages=${messagesByConversation.values.fold<int>(0, (sum, list) => sum + list.length)} '
      'toolEventMessages=${toolEvents.length} settings=${settings != null}',
      tag: 'backup-restore',
    );

    return ChatBackupPayload(
      conversations: conversations,
      messagesByConversation: messagesByConversation,
      toolEvents: toolEvents,
      geminiThoughtSigs: signatures,
      workspaceBindings: workspaceBindings,
      fileRecords: fileRecords,
      settings: settings,
      archiveSha256: archiveHash,
    );
  }

  /// Reuses the installation receipt's identity when present, then the live
  /// probe, and only then generates a new UUID. The installation gate requires
  /// the receipt and the database identity to agree after publish.
  Future<String> resolveDatabaseId() async {
    final receiptExists = await files.installationReceipt.exists();
    final receipt = await files.readJson(files.installationReceipt);
    if (receiptExists && receipt == null) {
      throw const ChatRestoreException(
        'preflight',
        'The installation receipt is malformed; nothing was changed.',
      );
    }
    final receiptId = receipt?['databaseId']?.toString() ?? '';
    if (receiptId.isNotEmpty) return receiptId;

    final live = await probeDatabase(files.database);
    final liveId = live.databaseId ?? '';
    if (liveId.isNotEmpty) return liveId;
    return const Uuid().v4();
  }

  /// Creates and fills `chat_v2.sqlite.restoring`, verifies counts, then
  /// checkpoints and closes it. On any failure the staging family is removed.
  Future<ChatStorageCounts> buildStagingDatabase({
    required ChatBackupPayload payload,
    required String databaseId,
    required String publishId,
  }) async {
    await files.deleteFamily(files.restoring);
    final db = AppDatabase.open(
      files.restoring,
      background: false,
      synchronousFull: true,
    );
    ChatStorageCounts? counts;
    Object? failure;
    try {
      await db.verifyHealthy();
      final repository = ChatRepository(db);
      await repository.putMigrationMeta(<String, String>{
        'database_id': databaseId,
        'publish_id': publishId,
        'source': 'restore',
        'state': 'complete_clean',
        'installed_schema_version': '$currentChatSchemaVersion',
        'installed_by_app_version': appVersion,
        'installed_at_utc': DateTime.now().toUtc().toIso8601String(),
        'restored_at_utc': DateTime.now().toUtc().toIso8601String(),
        'quarantine_count': '0',
      });

      var imported = 0;
      for (final conversation in payload.conversations) {
        await repository.restoreConversation(
          conversation,
          payload.messagesByConversation[conversation.id] ??
              const <ChatMessage>[],
        );
        imported++;
        if (debugFailAfterConversations > 0 &&
            imported >= debugFailAfterConversations) {
          debugFailAfterConversations = 0;
          throw const ChatRestoreException(
            'import',
            'Injected conversation import failure (debug).',
          );
        }
      }

      for (final entry in payload.toolEvents.entries) {
        await repository.replaceToolEvents(
          entry.key,
          entry.value.map(toolPartDraftFromLegacyEvent).toList(),
        );
      }
      for (final entry in payload.geminiThoughtSigs.entries) {
        await repository.setProviderArtifact(
          entry.key,
          kGeminiThoughtSignatureKind,
          entry.value,
        );
      }
      for (final entry in payload.fileRecords.entries) {
        for (final record in entry.value) {
          await repository.upsertFileRecord(entry.key, record);
        }
      }
      for (final entry in payload.workspaceBindings.entries) {
        await repository.setWorkspaceBinding(entry.key, entry.value);
      }

      counts = await repository.counts();
      verifyCounts(counts, payload);
      await db.checkpointAndTruncate();
    } catch (error) {
      failure = error;
    }

    try {
      await db.close();
    } catch (_) {}

    if (failure != null) {
      await files.deleteFamily(files.restoring);
      if (failure is ChatRestoreException) throw failure;
      throw ChatRestoreException(
        'import',
        'The staging database could not be built: $failure',
        cause: failure,
      );
    }
    if (!await files.ensureNoSidecars(files.restoring)) {
      await files.deleteFamily(files.restoring);
      throw const ChatRestoreException(
        'import',
        'The staging database still has a non-empty WAL after close.',
      );
    }
    FlutterLogger.log(
      'Staging database ready: conversations=${counts?.conversations} '
      'messages=${counts?.messages} parts=${counts?.parts}',
      tag: 'backup-restore',
    );
    return counts!;
  }

  /// Verifies the staged row counts against the parsed payload.
  void verifyCounts(ChatStorageCounts actual, ChatBackupPayload payload) {
    final mismatches = <String>[];
    if (actual.conversations != payload.conversations.length) {
      mismatches.add(
        'conversations ${actual.conversations}/${payload.conversations.length}',
      );
    }
    if (actual.messages != payload.messageCount) {
      mismatches.add('messages ${actual.messages}/${payload.messageCount}');
    }
    if (actual.parts != payload.partCount) {
      mismatches.add('tool parts ${actual.parts}/${payload.partCount}');
    }
    if (actual.providerArtifacts != payload.signatureCount) {
      mismatches.add(
        'signatures ${actual.providerArtifacts}/${payload.signatureCount}',
      );
    }
    if (actual.fileRecords != payload.fileRecordCount) {
      mismatches.add(
        'file records ${actual.fileRecords}/${payload.fileRecordCount}',
      );
    }
    if (actual.workspaceBindings != payload.workspaceBindingCount) {
      mismatches.add(
        'workspace bindings '
        '${actual.workspaceBindings}/${payload.workspaceBindingCount}',
      );
    }
    if (actual.quarantined != 0) {
      mismatches.add('quarantine rows ${actual.quarantined}/0');
    }
    if (mismatches.isNotEmpty) {
      throw ChatRestoreException(
        'verify',
        'The restored row counts do not match the backup: '
        '${mismatches.join(', ')}.',
      );
    }
  }

  Future<DatabasePublishOutcome> publishStaging() {
    return DatabaseFamilyPublisher(
      files,
      appVersion: appVersion,
    ).publish(temp: files.restoring, operation: 'restore');
  }

  /// Finds the family that the publisher actually preserved for [oldTarget].
  /// Only an identity-matching family may later be used for a rollback.
  Future<({String? path, String? databaseId})> resolvePreservedFamily(
    DatabaseProbe oldTarget,
    String publishId,
  ) async {
    final wanted = oldTarget.databaseId ?? '';
    if (wanted.isEmpty) {
      return (path: null, databaseId: null);
    }

    // The replaced family is specific to this publish; a pre-existing
    // `.previous` may belong to an older publish and must not win.
    final candidates = <File>[
      File('${files.database.path}.replaced-$publishId'),
      File('${files.database.path}.corrupt-$publishId'),
      files.previous,
    ];
    try {
      await for (final entity in directory.list()) {
        if (entity is File &&
            (entity.path.contains('.replaced-') ||
                entity.path.contains('.corrupt-'))) {
          if (!candidates.any((candidate) => candidate.path == entity.path)) {
            candidates.add(entity);
          }
        }
      }
    } catch (_) {}

    for (final candidate in candidates) {
      final probe = await probeDatabase(candidate);
      if (probe.readable && probe.databaseId == wanted) {
        return (path: candidate.path, databaseId: wanted);
      }
    }
    return (path: null, databaseId: null);
  }

  /// Removes staging and preserved copies after the commit is verified.
  Future<void> cleanupCommitted({
    String? preservedPath,
    Directory? stagingDirectory,
    Directory? previousDirectory,
  }) async {
    await files.deleteFamily(files.restoring);
    if (stagingDirectory != null) {
      try {
        await stagingDirectory.delete(recursive: true);
      } catch (_) {}
    }
    if (previousDirectory != null) {
      try {
        await previousDirectory.delete(recursive: true);
      } catch (_) {}
    }
    if (preservedPath != null && preservedPath.isNotEmpty) {
      try {
        await files.deleteFamily(File(preservedPath));
      } catch (_) {}
    }
  }
}
