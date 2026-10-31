import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../../../utils/app_directories.dart';
import 'chat_database_files.dart';
import 'database_installation_gate.dart';
import 'legacy_retirement_service.dart';

/// Read-only snapshot of the chat storage for the settings page (§9.8).
class ChatStorageInfo {
  const ChatStorageInfo({
    required this.databaseBytes,
    required this.walBytes,
    required this.shmBytes,
    required this.previousBytes,
    required this.migratingBytes,
    required this.legacyBytes,
    required this.conversations,
    required this.messages,
    required this.parts,
    required this.fileRecords,
    required this.quarantineCount,
    required this.legacyImportDisabled,
    required this.retirement,
    this.schemaVersion,
    this.databaseId,
    this.source,
    this.migrationState,
    this.error,
  });

  final int databaseBytes;
  final int walBytes;
  final int shmBytes;
  final int previousBytes;
  final int migratingBytes;
  final int legacyBytes;
  final int conversations;
  final int messages;
  final int parts;
  final int fileRecords;
  final int quarantineCount;
  final bool legacyImportDisabled;
  final LegacyRetirementStatus retirement;
  final int? schemaVersion;
  final String? databaseId;
  final String? source;
  final String? migrationState;
  final String? error;

  bool get sqliteExists => databaseBytes > 0;
  int get sqliteTotalBytes => databaseBytes + walBytes + shmBytes;
  int get remainingWorkflowBytes => previousBytes + migratingBytes;
}

abstract final class ChatStorageInfoService {
  ChatStorageInfoService._();

  static Future<ChatStorageInfo> inspect({
    String appVersion = 'unknown',
  }) async {
    final directory = await AppDirectories.getAppDataDirectory();
    final files = ChatDatabaseFiles(directory);
    final probe = await probeDatabase(files.database);
    final retirement = await LegacyRetirementService(
      directory: directory,
      appVersion: appVersion,
    ).inspect();

    var conversations = 0;
    var messages = 0;
    var parts = 0;
    var fileRecords = 0;
    var quarantine = 0;
    if (await files.database.exists() && probe.readable) {
      Database? handle;
      try {
        handle = sqlite3.open(files.database.path, mode: OpenMode.readOnly);
        handle.execute('PRAGMA busy_timeout = 5000');
        int count(String table) {
          final rows = handle!.select('SELECT COUNT(*) AS c FROM $table');
          if (rows.isEmpty) return 0;
          final value = rows.first['c'];
          return value is int ? value : 0;
        }

        conversations = count('conversations');
        messages = count('messages');
        parts = count('message_parts');
        fileRecords = count('message_file_records');
        quarantine = count('legacy_quarantine');
      } catch (_) {
        // The probe error already carries the actionable diagnostic.
      } finally {
        try {
          handle?.close();
        } catch (_) {}
      }
    }

    return ChatStorageInfo(
      databaseBytes: await _size(files.database),
      walBytes: await _size(files.wal),
      shmBytes: await _size(files.shm),
      previousBytes: await _familySize(files.previous),
      migratingBytes:
          await _familySize(files.migrating) +
          await _familySize(files.upgrading),
      legacyBytes: retirement.totalBytes,
      conversations: conversations,
      messages: messages,
      parts: parts,
      fileRecords: fileRecords,
      quarantineCount: quarantine,
      legacyImportDisabled: await files.legacyImportDisabled.exists(),
      retirement: retirement,
      schemaVersion: probe.userVersion,
      databaseId: probe.databaseId,
      source: probe.source,
      migrationState: probe.state,
      error: probe.error ?? retirement.error,
    );
  }

  static Future<int> _size(File file) async {
    try {
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> _familySize(File base) async {
    var total = await _size(base);
    for (final sidecar in <File>[
      File('${base.path}-wal'),
      File('${base.path}-shm'),
    ]) {
      total += await _size(sidecar);
    }
    return total;
  }
}
