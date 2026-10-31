import 'dart:io';

import 'package:hive/hive.dart';

import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import '../../../models/file_record.dart';
import '../../logging/flutter_logger.dart';
import 'app_database.dart';
import 'chat_database_files.dart';
import 'chat_storage.dart';
import 'chat_maintenance_lock.dart';
import 'chat_repository.dart';
import 'database_installation_gate.dart';
import 'hive_chat_storage.dart';
import 'legacy_hive_importer.dart';
import 'message_part_codec.dart';
import 'sqlite_chat_storage.dart';

class LegacyReimportException implements Exception {
  const LegacyReimportException(this.message);

  final String message;

  @override
  String toString() => 'LegacyReimportException: $message';
}

class LegacyReimportReport {
  const LegacyReimportReport({
    required this.sourceConversations,
    required this.sourceMessages,
    required this.importedConversations,
    required this.importedMessages,
    required this.existingConversations,
    required this.existingMessages,
    required this.partsImported,
    required this.signaturesImported,
    required this.fileRecordsImported,
    required this.workspacesImported,
    required this.conflicts,
    required this.conflictIds,
    required this.sentinelRemoved,
  });

  final int sourceConversations;
  final int sourceMessages;
  final int importedConversations;
  final int importedMessages;
  final int existingConversations;
  final int existingMessages;
  final int partsImported;
  final int signaturesImported;
  final int fileRecordsImported;
  final int workspacesImported;
  final int conflicts;
  final List<String> conflictIds;
  final bool sentinelRemoved;
}

/// Explicit §9.8 "import legacy Hive" action.
///
/// The one-time startup importer can only build a fresh database. Re-importing
/// after a reset is a merge: the Hive snapshot is imported into a disposable
/// staging database first, then added to the live SQLite store by stable ids.
/// Existing conversations and messages are never overwritten; missing ones are
/// added, and existing rows only receive missing tool parts/artifacts/records.
class LegacyReimportService {
  LegacyReimportService({
    required this.directory,
    required this.appVersion,
    required this.destination,
  }) : files = ChatDatabaseFiles(directory);

  final Directory directory;
  final String appVersion;
  final SqliteChatStorage destination;
  final ChatDatabaseFiles files;

  static const List<String> _chatBoxNames = <String>[
    HiveChatStorage.conversationsBoxName,
    HiveChatStorage.messagesBoxName,
    HiveChatStorage.toolEventsBoxName,
    HiveChatStorage.conversationWorkspacesBoxName,
    HiveChatStorage.conversationWorkspaceBindingsBoxName,
    HiveChatStorage.messageFileRecordsBoxName,
  ];

  Future<LegacyReimportReport> run({
    void Function(String stage)? onProgress,
  }) async {
    if (destination.backend != ChatStorageBackend.sqlite) {
      throw const LegacyReimportException(
        'The legacy import requires the SQLite chat store. Restart OmniChat '
        'so SQLite can be admitted, then try again.',
      );
    }
    if (chatHiveFiles(directory).isEmpty) {
      throw const LegacyReimportException('No legacy chat files remain.');
    }
    if (await files.legacyRetirement.exists()) {
      final retirement = await files.readJson(files.legacyRetirement);
      if (retirement == null) {
        throw const LegacyReimportException(
          'The legacy retirement marker is malformed. Nothing was imported.',
        );
      }
      if (retirement['state'] == 'deleting') {
        throw const LegacyReimportException(
          'Legacy cleanup is in progress. Resume or finish cleanup before '
          'importing the same files.',
        );
      }
    }
    for (final name in _chatBoxNames) {
      if (Hive.isBoxOpen(name)) {
        throw const LegacyReimportException(
          'The legacy chat store is currently open. Restart OmniChat before '
          'importing it into SQLite.',
        );
      }
    }

    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'legacy-reimport',
    );
    try {
      return await _runLocked(onProgress);
    } finally {
      await lock.release();
    }
  }

  Future<LegacyReimportReport> _runLocked(
    void Function(String stage)? onProgress,
  ) async {
    final staging = await Directory.systemTemp.createTemp(
      'omnichat_legacy_reimport_',
    );
    final stagingFiles = ChatDatabaseFiles(staging);
    AppDatabase? sourceDb;
    try {
      onProgress?.call('preparing');
      await staging.create(recursive: true);
      await LegacyHiveImporter(
        hiveDirectory: directory,
        files: stagingFiles,
        appVersion: appVersion,
        backupChoice: 'skipped',
        onProgress: (stage, counts) => onProgress?.call(stage),
      ).run();

      sourceDb = AppDatabase.open(stagingFiles.database, background: false);
      await sourceDb.verifyHealthy();
      final source = ChatRepository(sourceDb);
      final sourceProbe = await probeDatabase(stagingFiles.database);
      if (!sourceProbe.readable || !sourceProbe.migrationComplete) {
        throw const LegacyReimportException(
          'The legacy import produced an unreadable staging database.',
        );
      }

      onProgress?.call('merging');
      final report = await _merge(source, onProgress);
      onProgress?.call('verifying');
      await destination.refreshCache();

      var sentinelRemoved = false;
      try {
        if (await files.legacyImportDisabled.exists()) {
          await files.legacyImportDisabled.delete();
          sentinelRemoved = true;
        }
      } catch (_) {
        // The merge is already committed and idempotent. Leave the sentinel
        // for the next successful action rather than reporting a false failure.
      }

      return LegacyReimportReport(
        sourceConversations: report.sourceConversations,
        sourceMessages: report.sourceMessages,
        importedConversations: report.importedConversations,
        importedMessages: report.importedMessages,
        existingConversations: report.existingConversations,
        existingMessages: report.existingMessages,
        partsImported: report.partsImported,
        signaturesImported: report.signaturesImported,
        fileRecordsImported: report.fileRecordsImported,
        workspacesImported: report.workspacesImported,
        conflicts: report.conflicts,
        conflictIds: report.conflictIds,
        sentinelRemoved: sentinelRemoved,
      );
    } on LegacyReimportException {
      rethrow;
    } catch (e) {
      throw LegacyReimportException('Legacy import failed: $e');
    } finally {
      try {
        await sourceDb?.close();
      } catch (_) {}
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<LegacyReimportReport> _merge(
    ChatRepository source,
    void Function(String stage)? onProgress,
  ) async {
    final dest = destination.repository;
    final sourceConversations = await source.listConversations();
    final sourceMessages = <String, List<ChatMessage>>{
      for (final conversation in sourceConversations)
        conversation.id: await source.getMessages(conversation.id),
    };
    final sourceSignatures = await source.allProviderArtifactsOfKind(
      kGeminiThoughtSignatureKind,
    );
    final sourceFileRecords = await source.allFileRecordsGrouped();
    final sourceWorkspaces = await source.allWorkspaceBindings();

    // The merge needs to compare every existing message; this is an explicit
    // full-history operation, not a startup path.
    await destination.ensureAllMessagesLoaded();
    final destConversations = <String, Conversation>{
      for (final conversation in await dest.listConversations())
        conversation.id: conversation,
    };
    final destMessages = <String, List<ChatMessage>>{
      for (final conversation in destConversations.values)
        conversation.id: List<ChatMessage>.of(
          destination.getMessages(conversation.id),
        ),
    };
    final destMessagesById = <String, ChatMessage>{
      for (final messages in destMessages.values)
        for (final message in messages) message.id: message,
    };
    final destSignatures = await dest.allProviderArtifactsOfKind(
      kGeminiThoughtSignatureKind,
    );
    final destFileRecords = await dest.allFileRecordsGrouped();
    final destWorkspaces = await dest.allWorkspaceBindings();

    var importedConversations = 0;
    var importedMessages = 0;
    var existingMessages = 0;
    var partsImported = 0;
    var signaturesImported = 0;
    var fileRecordsImported = 0;
    var workspacesImported = 0;
    var conflicts = 0;
    final conflictIds = <String>[];
    final expectedParts = <String>{};
    final expectedSignatures = <String>{};
    final expectedFileRecords = <String>{};
    final expectedWorkspaces = <String>{};
    final importedContents = <String, String>{};

    await dest.db.transaction(() async {
      for (final conversation in sourceConversations) {
        final messages =
            sourceMessages[conversation.id] ?? const <ChatMessage>[];
        final existing = destConversations[conversation.id];
        final targetMessages = destMessages[conversation.id] ?? <ChatMessage>[];
        var nextOrdinal = targetMessages.length;

        if (existing == null) {
          await dest.upsertConversation(conversation);
          destConversations[conversation.id] = conversation;
          destMessages[conversation.id] = targetMessages;
          importedConversations++;
        }

        for (final message in messages) {
          final existingMessage = destMessagesById[message.id];
          if (existingMessage != null) {
            existingMessages++;
            if (existingMessage.conversationId != conversation.id ||
                existingMessage.content != message.content) {
              conflicts++;
              conflictIds.add(message.id);
              FlutterLogger.log(
                'Legacy reimport kept existing message ${message.id}: '
                'source conversation=${conversation.id}, destination '
                'conversation=${existingMessage.conversationId}, content '
                '${existingMessage.content == message.content ? 'equal' : 'different'}.',
                tag: 'chat-storage',
              );
            }
            if (message.role == 'assistant') {
              if (existingMessage.conversationId == conversation.id &&
                  (await dest.getToolEvents(message.id)).isEmpty) {
                final events = await source.getToolEvents(message.id);
                if (events.isNotEmpty) {
                  await dest.replaceToolEvents(
                    message.id,
                    events.map(toolPartDraftFromLegacyEvent).toList(),
                  );
                  expectedParts.add(message.id);
                  partsImported += events.length;
                }
              }
              final signature = sourceSignatures[message.id];
              if (signature != null &&
                  signature.isNotEmpty &&
                  destSignatures[message.id] == null) {
                await dest.setProviderArtifact(
                  message.id,
                  kGeminiThoughtSignatureKind,
                  signature,
                );
                destSignatures[message.id] = signature;
                expectedSignatures.add(message.id);
                signaturesImported++;
              }
            }
            if ((destFileRecords[message.id] ?? const <FileRecord>[]).isEmpty) {
              final records = sourceFileRecords[message.id];
              if (records != null && records.isNotEmpty) {
                await dest.replaceFileRecords(message.id, records);
                destFileRecords[message.id] = records;
                expectedFileRecords.add(message.id);
                fileRecordsImported += records.length;
              }
            }
            continue;
          }

          final copied = message.copyWith(
            conversationId: conversation.id,
            isStreaming: false,
          );
          await dest.insertMessageAt(copied, nextOrdinal++);
          targetMessages.add(copied);
          destMessagesById[copied.id] = copied;
          importedContents[copied.id] = copied.content;
          importedMessages++;

          if (copied.role == 'assistant') {
            final events = await source.getToolEvents(copied.id);
            if (events.isNotEmpty) {
              await dest.replaceToolEvents(
                copied.id,
                events.map(toolPartDraftFromLegacyEvent).toList(),
              );
              expectedParts.add(copied.id);
              partsImported += events.length;
            }
            final signature = sourceSignatures[copied.id];
            if (signature != null && signature.isNotEmpty) {
              await dest.setProviderArtifact(
                copied.id,
                kGeminiThoughtSignatureKind,
                signature,
              );
              destSignatures[copied.id] = signature;
              expectedSignatures.add(copied.id);
              signaturesImported++;
            }
          }
          final records = sourceFileRecords[copied.id];
          if (records != null && records.isNotEmpty) {
            await dest.replaceFileRecords(copied.id, records);
            destFileRecords[copied.id] = records;
            expectedFileRecords.add(copied.id);
            fileRecordsImported += records.length;
          }
        }

        final workspace = sourceWorkspaces[conversation.id];
        if (workspace != null && destWorkspaces[conversation.id] == null) {
          await dest.setWorkspaceBinding(conversation.id, workspace);
          destWorkspaces[conversation.id] = workspace;
          expectedWorkspaces.add(conversation.id);
          workspacesImported++;
        }
      }

      // The merge is idempotent: verify every source id exists in its own
      // conversation, then re-check the rows that were supposed to be added.
      for (final conversation in sourceConversations) {
        if (await dest.getConversation(conversation.id) == null) {
          throw LegacyReimportException(
            'Verification failed: conversation ${conversation.id} is missing.',
          );
        }
        final finalIds = (await dest.messageIdsFor(conversation.id)).toSet();
        for (final message
            in sourceMessages[conversation.id] ?? const <ChatMessage>[]) {
          if (!finalIds.contains(message.id)) {
            throw LegacyReimportException(
              'Verification failed: message ${message.id} is missing from '
              'conversation ${conversation.id}.',
            );
          }
        }
      }
      for (final entry in importedContents.entries) {
        final stored = await dest.getMessage(entry.key);
        if (stored == null || stored.content != entry.value) {
          throw LegacyReimportException(
            'Verification failed: imported message ${entry.key} did not '
            'persist.',
          );
        }
      }
      for (final id in expectedParts) {
        if ((await dest.getToolEvents(id)).isEmpty) {
          throw LegacyReimportException(
            'Verification failed: tool parts for $id are missing.',
          );
        }
      }
      for (final id in expectedSignatures) {
        if (await dest.getProviderArtifact(id, kGeminiThoughtSignatureKind) ==
            null) {
          throw LegacyReimportException(
            'Verification failed: signature for $id is missing.',
          );
        }
      }
      for (final id in expectedFileRecords) {
        if ((await dest.getFileRecords(id)).isEmpty) {
          throw LegacyReimportException(
            'Verification failed: file records for $id are missing.',
          );
        }
      }
      for (final id in expectedWorkspaces) {
        if (await dest.getWorkspaceBinding(id) == null) {
          throw LegacyReimportException(
            'Verification failed: workspace for $id is missing.',
          );
        }
      }
    });

    return LegacyReimportReport(
      sourceConversations: sourceConversations.length,
      sourceMessages: sourceMessages.values.fold(
        0,
        (sum, messages) => sum + messages.length,
      ),
      importedConversations: importedConversations,
      importedMessages: importedMessages,
      existingConversations: sourceConversations.length - importedConversations,
      existingMessages: existingMessages,
      partsImported: partsImported,
      signaturesImported: signaturesImported,
      fileRecordsImported: fileRecordsImported,
      workspacesImported: workspacesImported,
      conflicts: conflicts,
      conflictIds: conflictIds,
      sentinelRemoved: false,
    );
  }
}
