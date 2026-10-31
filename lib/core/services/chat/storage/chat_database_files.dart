import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'app_database.dart';

/// Names and locations of the chat SQLite family and its markers/receipts.
/// The publication unit is the family (database + WAL/SHM), never one file.
class ChatDatabaseFiles {
  ChatDatabaseFiles(this.directory);

  final Directory directory;

  String get _dir => directory.path;

  File get database => File(p.join(_dir, 'chat_v2.sqlite'));
  File get wal => File(p.join(_dir, 'chat_v2.sqlite-wal'));
  File get shm => File(p.join(_dir, 'chat_v2.sqlite-shm'));

  File get migrating => File(p.join(_dir, 'chat_v2.sqlite.migrating'));
  File get upgrading => File(p.join(_dir, 'chat_v2.sqlite.upgrading'));
  File get previous => File(p.join(_dir, 'chat_v2.sqlite.previous'));

  File get installationReceipt =>
      File(p.join(_dir, 'chat_v2.installation.json'));
  File get migrationReceipt => File(p.join(_dir, 'chat_v2.migration.json'));
  File get publishIntent => File(p.join(_dir, 'chat_v2.publish-intent.json'));
  File get resetMarker => File(p.join(_dir, 'chat_v2.reset'));
  File get legacyImportDisabled =>
      File(p.join(_dir, 'chat_v2.legacy_import_disabled'));
  File get legacyRetirement =>
      File(p.join(_dir, 'chat_v2.legacy-retirement.json'));
  File get legacyExportReceipt =>
      File(p.join(_dir, 'chat_v2.legacy-export.json'));
  File get maintenanceLock => File(p.join(_dir, 'chat_v2.maintenance.lock'));

  List<File> family(File base) => [
    base,
    File('${base.path}-wal'),
    File('${base.path}-shm'),
  ];

  List<File> get publishedFamily => family(database);

  List<File> get workflows => [
    database,
    wal,
    shm,
    migrating,
    File('${migrating.path}-wal'),
    File('${migrating.path}-shm'),
    upgrading,
    File('${upgrading.path}-wal'),
    File('${upgrading.path}-shm'),
    previous,
    File('${previous.path}-wal'),
    File('${previous.path}-shm'),
    publishIntent,
  ];

  /// Ensures a closed database has no non-empty WAL. A non-empty WAL that
  /// survives close means the checkpoint did not complete; deleting it would
  /// lose committed frames, so this attempts a truncating checkpoint first
  /// and refuses (returns false) when frames remain.
  Future<bool> ensureNoSidecars(File base) async {
    final wal = File('${base.path}-wal');
    final shm = File('${base.path}-shm');

    if (await wal.exists() && await wal.length() > 0) {
      Database? handle;
      try {
        handle = sqlite3.open(base.path);
        handle.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (_) {
        // Fall through to the size check.
      } finally {
        try {
          handle?.close();
        } catch (_) {}
      }
    }
    if (await wal.exists()) {
      if (await wal.length() > 0) return false;
      try {
        await wal.delete();
      } catch (_) {}
    }
    if (await shm.exists()) {
      try {
        await shm.delete();
      } catch (_) {}
    }
    return true;
  }

  /// Removes `-wal`/`-shm` companions for [base] if they still exist.
  Future<void> deleteSidecars(File base) async {
    for (final file in family(base).skip(1)) {
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> deleteFamily(File base) async {
    // The family is a unit. If the base cannot be deleted, its sidecars may
    // contain committed frames; deleting them would lose data. Keep the whole
    // family for a later retry. A sidecar-only orphan family can be removed.
    var baseDeleted = !await base.exists();
    if (!baseDeleted) {
      try {
        await base.delete();
        baseDeleted = true;
      } catch (_) {}
    }
    if (!baseDeleted) return;
    for (final file in family(base).skip(1)) {
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  /// Atomically writes a small JSON receipt/marker: temp file, flush, rename.
  Future<void> writeJsonAtomically(
    File target,
    Map<String, dynamic> json,
  ) async {
    final tmp = File('${target.path}.tmp');
    final handle = await tmp.open(mode: FileMode.write);
    try {
      await handle.writeString(
        const JsonEncoder.withIndent('  ').convert(json),
      );
      await handle.flush();
    } finally {
      await handle.close();
    }
    // File.rename replaces an existing file atomically on the supported
    // platforms. Deleting the old receipt first would leave a crash window
    // with no intent/receipt at all, after files may already have moved.
    await tmp.rename(target.path);
  }

  Future<Map<String, dynamic>?> readJson(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// Identity + admission information read directly from a SQLite file, without
/// starting Drift migrations or side effects.
class DatabaseProbe {
  const DatabaseProbe({
    required this.exists,
    required this.sizeBytes,
    required this.headerValid,
    required this.userVersion,
    required this.meta,
    required this.error,
    required this.sha256Hex,
  });

  final bool exists;
  final int sizeBytes;
  final bool headerValid;
  final int? userVersion;
  final Map<String, String> meta;
  final String? error;
  final String? sha256Hex;

  bool get isEmpty => exists && sizeBytes == 0;

  bool get readable => exists && sizeBytes > 0 && headerValid && error == null;

  bool get schemaIsCurrent => userVersion == currentChatSchemaVersion;

  bool get schemaIsPublished =>
      userVersion != null && publishedChatSchemaVersions.contains(userVersion);

  String? get databaseId => meta['database_id'];
  String? get publishId => meta['publish_id'];
  String? get source => meta['source'];
  String? get state => meta['state'];
  bool get migrationComplete =>
      state == 'complete_clean' || state == 'complete_with_issues';

  Map<String, dynamic> toJson() => {
    'exists': exists,
    'size_bytes': sizeBytes,
    'header_valid': headerValid,
    'user_version': userVersion,
    'database_id': databaseId,
    'publish_id': publishId,
    'source': source,
    'state': state,
    'error': error,
  };
}

const List<int> _sqliteHeader = <int>[
  0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, //
  0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
];

Future<DatabaseProbe> probeDatabase(
  File file, {
  bool includeHash = false,
}) async {
  if (!await file.exists()) {
    return const DatabaseProbe(
      exists: false,
      sizeBytes: 0,
      headerValid: false,
      userVersion: null,
      meta: <String, String>{},
      error: null,
      sha256Hex: null,
    );
  }

  final size = await file.length();
  if (size == 0) {
    return DatabaseProbe(
      exists: true,
      sizeBytes: 0,
      headerValid: false,
      userVersion: null,
      meta: const <String, String>{},
      error: null,
      sha256Hex: includeHash ? await sha256File(file) : null,
    );
  }

  var headerValid = false;
  try {
    final handle = await file.open();
    try {
      final bytes = await handle.read(16);
      headerValid = bytes.length == 16;
      for (var i = 0; headerValid && i < 16; i++) {
        if (bytes[i] != _sqliteHeader[i]) headerValid = false;
      }
    } finally {
      await handle.close();
    }
  } catch (_) {
    headerValid = false;
  }

  if (!headerValid) {
    return DatabaseProbe(
      exists: true,
      sizeBytes: size,
      headerValid: false,
      userVersion: null,
      meta: const <String, String>{},
      error: 'invalid SQLite header',
      sha256Hex: includeHash ? await sha256File(file) : null,
    );
  }

  int? version;
  var meta = <String, String>{};
  String? error;
  Database? handle;
  try {
    handle = sqlite3.open(file.path);
    // The settings page probes while the live connection may be writing;
    // wait briefly instead of reporting a transient SQLITE_BUSY as corruption.
    handle.execute('PRAGMA busy_timeout = 5000');
    final versionRows = handle.select('PRAGMA user_version');
    if (versionRows.isNotEmpty) {
      version = versionRows.first.values.first as int?;
    }
    final tableCheck = handle.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'migration_meta'",
    );
    if (tableCheck.isNotEmpty) {
      final rows = handle.select('SELECT key, value FROM migration_meta');
      meta = {
        for (final row in rows) row['key'].toString(): row['value'].toString(),
      };
    }
  } catch (e) {
    error = 'unreadable database: $e';
  } finally {
    try {
      handle?.close();
    } catch (_) {}
  }

  return DatabaseProbe(
    exists: true,
    sizeBytes: size,
    headerValid: headerValid,
    userVersion: version,
    meta: meta,
    error: error,
    sha256Hex: includeHash ? await sha256File(file) : null,
  );
}

/// Streams a SHA-256 over the file without loading it into memory.
Future<String> sha256File(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Best-effort flush of the containing directory (POSIX only; Dart cannot
/// fsync a directory on Windows).
Future<void> fsyncDirectory(Directory directory) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('sync', const <String>[]);
  } catch (_) {}
}

/// Runs `PRAGMA integrity_check` and `foreign_key_check` on a closed file.
Future<String?> verifySqliteFile(File file) async {
  Database? handle;
  try {
    handle = sqlite3.open(file.path);
    handle.execute('PRAGMA busy_timeout = 5000');
    final integrity = handle.select('PRAGMA integrity_check');
    final integrityResult = integrity.isEmpty
        ? 'empty result'
        : integrity.first.values.first?.toString();
    if (integrityResult != 'ok') return 'integrity_check: $integrityResult';
    final fk = handle.select('PRAGMA foreign_key_check');
    if (fk.isNotEmpty) return 'foreign_key_check: ${fk.length} row(s)';
    return null;
  } catch (e) {
    return 'unreadable database: $e';
  } finally {
    try {
      handle?.close();
    } catch (_) {}
  }
}
