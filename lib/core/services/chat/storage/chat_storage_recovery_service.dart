import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../models/chat_message.dart';
import '../../../models/conversation.dart';
import 'chat_database_files.dart';
import 'chat_maintenance_lock.dart';
import 'database_installation_gate.dart';

/// A recoverable but deliberate chat-storage failure.
class ChatStorageRecoveryException implements Exception {
  const ChatStorageRecoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// File-level recovery for `ChatStorageGateStage.needsRestoreOrReset`.
///
/// Nothing here opens a chat Hive box. [clearForLegacyImport] only removes the
/// SQLite family/markers so the normal gate can re-run the migration; the Hive
/// source files stay byte-identical. [resetToFreshDatabase] uses the same reset
/// marker as `clearAllData`, so it gets the gate's crash recovery and sentinel
/// semantics instead of deleting files ad hoc.
class ChatStorageRecoveryService {
  ChatStorageRecoveryService({
    required this.directory,
    required this.appVersion,
  }) : files = ChatDatabaseFiles(directory);

  final Directory directory;
  final String appVersion;
  final ChatDatabaseFiles files;

  bool get hasLegacyHive => chatHiveFiles(directory).isNotEmpty;

  /// Deletes the SQLite family and recreates an empty `source='reset'` database.
  /// The durable `legacy_import_disabled` sentinel prevents a later Hive
  /// import. Hive files are never touched.
  Future<void> resetToFreshDatabase() async {
    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'chat-storage-recovery-reset',
    );
    try {
      final probe = await probeDatabase(files.database);
      await files.writeJsonAtomically(files.resetMarker, <String, dynamic>{
        'format': 1,
        'requestedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'databaseId': probe.databaseId,
      });
      final result = await DatabaseInstallationGate(
        directory: directory,
        appVersion: appVersion,
      ).ensureReady();
      if (!result.isReady) {
        throw ChatStorageRecoveryException(
          'Could not create a fresh chat database: ${result.message}',
        );
      }
      if (!await files.legacyImportDisabled.exists()) {
        throw const ChatStorageRecoveryException(
          'The reset database was created without the legacy-import sentinel.',
        );
      }
    } finally {
      await lock.release();
    }
  }

  /// Removes only SQLite artifacts and the markers that block a Hive import.
  ///
  /// The next `DatabaseInstallationGate` pass sees the untouched Hive files and
  /// returns `needsMigration`; the normal backup prompt and importer then run.
  Future<void> clearForLegacyImport() async {
    if (!hasLegacyHive) {
      throw const ChatStorageRecoveryException(
        'No legacy Hive chat files were found to rebuild from.',
      );
    }

    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'chat-storage-recovery-rebuild',
    );
    try {
      // A failed restore can leave a freshly reset, empty SQLite database in
      // place. Rebuild may replace that, but never a database with chat rows.
      if (await files.database.exists()) {
        final probe = await probeDatabase(files.database);
        if (!probe.readable || !probe.schemaIsCurrent) {
          throw const ChatStorageRecoveryException(
            'A chat database is present but is not readable; use Reset instead.',
          );
        }
        if (await _conversationCount(files.database) != 0) {
          throw const ChatStorageRecoveryException(
            'A chat database with conversations is present; use Reset instead.',
          );
        }
      }

      // The family is empty or absent; remove orphaned WAL/SHM companions as a
      // unit before the normal gate runs.
      await files.deleteFamily(files.database);
      await files.deleteFamily(files.migrating);
      await files.deleteFamily(files.upgrading);
      await files.deleteFamily(files.previous);
      for (final file in <File>[
        files.installationReceipt,
        files.migrationReceipt,
        files.publishIntent,
        files.resetMarker,
        files.legacyImportDisabled,
      ]) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      try {
        await for (final entity in directory.list()) {
          final name = entity.uri.pathSegments.last;
          if (entity is File &&
              (name.contains('.replaced-') || name.endsWith('.tmp'))) {
            await entity.delete();
          }
        }
      } catch (_) {}

      final result = await DatabaseInstallationGate(
        directory: directory,
        appVersion: appVersion,
      ).ensureReady();
      if (result.state != ChatInstallationState.needsMigration) {
        throw ChatStorageRecoveryException(
          'Legacy rebuild could not start: ${result.message}',
        );
      }
    } finally {
      await lock.release();
    }
  }

  Future<int> _conversationCount(File database) async {
    Database? handle;
    try {
      handle = sqlite3.open(database.path);
      final rows = handle.select('SELECT COUNT(*) AS count FROM conversations');
      return rows.isEmpty ? -1 : (rows.first['count'] as int? ?? -1);
    } catch (_) {
      return -1;
    } finally {
      try {
        handle?.close();
      } catch (_) {}
    }
  }

  /// Checks the archive's central directory before any destructive step. A
  /// non-empty `chats.json` is the minimum contract shared by normal backups
  /// and pre-migration backups; settings-only archives are rejected.
  Future<void> validateBackup(File archiveFile) async {
    if (!await archiveFile.exists()) {
      throw const ChatStorageRecoveryException('The backup file is missing.');
    }
    if (await archiveFile.length() == 0) {
      throw const ChatStorageRecoveryException('The backup file is empty.');
    }

    InputFileStream? input;
    try {
      input = InputFileStream(archiveFile.path);
      final archive = ZipDecoder().decodeStream(input);
      final entry = archive.find('chats.json');
      if (entry == null || !entry.isFile || entry.size <= 0) {
        throw const ChatStorageRecoveryException(
          'This backup does not contain chat history (chats.json).',
        );
      }
      final bytes = entry.readBytes();
      if (bytes == null || bytes.isEmpty) {
        throw const ChatStorageRecoveryException(
          'The chat history entry is empty.',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['conversations'] is! List) {
        throw const ChatStorageRecoveryException(
          'The backup chats.json is not a valid OmniChat chat export.',
        );
      }
      final version = decoded['version'];
      if (version != null && (version is! int || version < 1 || version > 3)) {
        throw ChatStorageRecoveryException(
          'Unsupported chat export version: $version.',
        );
      }
      // Parse the rows now so a malformed entry never triggers a destructive
      // reset followed by DataSync silently swallowing the import error.
      for (final raw in decoded['conversations'] as List) {
        if (raw is! Map) {
          throw const ChatStorageRecoveryException(
            'The backup contains an invalid conversation entry.',
          );
        }
        Conversation.fromJson(raw.cast<String, dynamic>());
      }
      final rawMessages = decoded['messages'];
      if (rawMessages != null) {
        if (rawMessages is! List) {
          throw const ChatStorageRecoveryException(
            'The backup contains an invalid message list.',
          );
        }
        for (final raw in rawMessages) {
          if (raw is! Map) {
            throw const ChatStorageRecoveryException(
              'The backup contains an invalid message entry.',
            );
          }
          ChatMessage.fromJson(raw.cast<String, dynamic>());
        }
      }
    } on ChatStorageRecoveryException {
      rethrow;
    } catch (error) {
      throw ChatStorageRecoveryException(
        'The backup archive could not be read: $error',
      );
    } finally {
      try {
        await input?.close();
      } catch (_) {}
    }
  }
}
