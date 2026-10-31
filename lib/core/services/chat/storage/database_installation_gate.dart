import 'dart:io';

import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'chat_database_files.dart';
import 'chat_maintenance_lock.dart';
import 'chat_repository.dart';
import 'database_family_publisher.dart';

/// Where the gate needs the app to go next.
enum ChatInstallationState {
  /// A healthy, current-schema published database exists.
  ready,

  /// Chat Hive files exist and no database has ever been published.
  needsMigration,

  /// A database is missing/corrupt after a recorded installation: the user
  /// must explicitly restore or reset. Never recreated silently.
  needsRestoreOrReset,

  /// Unknown/newer/unreadable/split-brain state. Nothing is deleted.
  failClosed,
}

class ChatInstallationResult {
  const ChatInstallationResult({
    required this.state,
    required this.message,
    this.probe,
    this.source,
    this.publishRecovered = false,
    this.needsRestart = false,
  });

  final ChatInstallationState state;
  final String message;
  final DatabaseProbe? probe;
  final String? source;
  final bool publishRecovered;

  /// A publish recovery kept the old target and discarded the temp; the
  /// import/upgrade must run again.
  final bool needsRestart;

  bool get isReady => state == ChatInstallationState.ready;
}

/// Pre-live admission (§6.3): creates, upgrades or rejects `chat_v2.sqlite`
/// without ever opening a chat Hive box or running implicit Drift migrations.
class DatabaseInstallationGate {
  DatabaseInstallationGate({
    required this.directory,
    required this.appVersion,
    this.hiveArtifacts,
  }) : files = ChatDatabaseFiles(directory);

  final Directory directory;
  final String appVersion;
  final ChatDatabaseFiles files;

  /// Existing chat Hive files, used only to decide "fresh install" vs
  /// "migration needed". Defaults to inspecting [directory].
  final List<File>? hiveArtifacts;

  List<File> _hiveFiles() {
    final artifacts = hiveArtifacts;
    if (artifacts != null) return artifacts;
    return chatHiveFiles(directory);
  }

  Future<ChatInstallationResult> ensureReady({
    Duration lockTimeout = const Duration(seconds: 30),
  }) async {
    final lock = await ChatMaintenanceLock.acquire(
      directory,
      timeout: lockTimeout,
      purpose: 'installation-gate',
    );
    try {
      return await _ensureReadyLocked();
    } finally {
      await lock.release();
    }
  }

  Future<ChatInstallationResult> _ensureReadyLocked() async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final publisher = DatabaseFamilyPublisher(files, appVersion: appVersion);

    // 1. Publish intent first: never open Hive or delete the target before it
    // resolves.
    final recovery = await publisher.recoverIfNeeded();
    if (recovery.failClosed) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: recovery.message,
        probe: await probeDatabase(files.database),
      );
    }

    // 2. Reset marker: finish a clearAllData that was interrupted, never
    // import Hive.
    if (await files.resetMarker.exists()) {
      return _completeReset();
    }

    final receiptExists = await files.installationReceipt.exists();
    final receipt = await files.readJson(files.installationReceipt);
    if (receiptExists && receipt == null) {
      return const ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'The installation receipt is malformed; nothing was deleted.',
      );
    }
    final hasReceipt = receipt != null;
    final hasHive = _hiveFiles().isNotEmpty;
    final dbExists = await files.database.exists();

    // 3. Durable "never import Hive again" sentinel.
    if (await files.legacyImportDisabled.exists()) {
      if (!dbExists) {
        return _createFreshOrReset(
          source: 'reset',
          keepLegacyImportDisabled: true,
          recoveredPublication: recovery.resolved && !recovery.restartRequired,
        );
      }
      final probe = await probeDatabase(files.database);
      if (!probe.readable) {
        return ChatInstallationResult(
          state: ChatInstallationState.failClosed,
          message: 'Legacy import is disabled but the database is unreadable. '
              'Nothing was deleted.',
          probe: probe,
        );
      }
      if (!probe.schemaIsCurrent) {
        return ChatInstallationResult(
          state: ChatInstallationState.failClosed,
          message: 'Legacy import is disabled and the database is not at the '
              'current schema (user_version=${probe.userVersion}).',
          probe: probe,
        );
      }
      if (!probe.migrationComplete) {
        return ChatInstallationResult(
          state: ChatInstallationState.failClosed,
          message: 'Legacy import is disabled and the database is not marked '
              'complete (state=${probe.state}).',
          probe: probe,
        );
      }
      final admissionError = await _verifyAndAdmit(probe, receipt);
      if (admissionError != null) {
        return ChatInstallationResult(
          state: ChatInstallationState.failClosed,
          message: admissionError,
          probe: probe,
        );
      }
      return ChatInstallationResult(
        state: ChatInstallationState.ready,
        message: 'SQLite is authoritative.',
        probe: probe,
        source: probe.source,
        publishRecovered: recovery.resolved && !recovery.restartRequired,
      );
    }

    // 4. No database at all.
    if (!dbExists) {
      if (hasReceipt) {
        return ChatInstallationResult(
          state: ChatInstallationState.needsRestoreOrReset,
          message: 'A prior installation was recorded but chat_v2.sqlite is '
              'missing. Restore a backup or explicitly reset chat storage.',
          source: receipt['source']?.toString(),
        );
      }
      if (hasHive) {
        return ChatInstallationResult(
          state: ChatInstallationState.needsMigration,
          message: 'Chat Hive data is present and no SQLite database exists.',
          source: 'hive',
        );
      }
      return _createFreshOrReset(
        source: 'fresh',
        keepLegacyImportDisabled: false,
      );
    }

    final probe = await probeDatabase(files.database);

    // 5. Zero-byte database: a crashed first launch ONLY when there is no
    // installation receipt. After an installation this is data loss.
    if (probe.isEmpty) {
      if (hasReceipt) {
        return ChatInstallationResult(
          state: ChatInstallationState.failClosed,
          message: 'chat_v2.sqlite is empty but an installation was recorded. '
              'Nothing was deleted.',
          probe: probe,
        );
      }
      await files.deleteFamily(files.database);
      if (hasHive) {
        return ChatInstallationResult(
          state: ChatInstallationState.needsMigration,
          message: 'Discarded an empty crashed database; Hive migration needed.',
          source: 'hive',
        );
      }
      return _createFreshOrReset(
        source: 'fresh',
        keepLegacyImportDisabled: false,
      );
    }

    if (!probe.readable) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: probe.error ?? 'The chat database is unreadable.',
        probe: probe,
      );
    }

    final version = probe.userVersion;
    if (version == null) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'Cannot read PRAGMA user_version.',
        probe: probe,
      );
    }
    if (version > currentChatSchemaVersion) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'This database was created by a newer version '
            '(schema $version > $currentChatSchemaVersion).',
        probe: probe,
      );
    }
    if (!publishedChatSchemaVersions.contains(version)) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'Database schema $version has never shipped. Nothing was '
            'deleted.',
        probe: probe,
      );
    }
    if (version < currentChatSchemaVersion) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'No upgrade steps are published from schema $version. '
            'Nothing was deleted.',
        probe: probe,
      );
    }

    // 6. Current schema: verify, reconcile the sidecar, and clean up recovery
    // material after one clean admission.
    final health = await _verifyHealth();
    if (health != null) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: health,
        probe: probe,
      );
    }
    if (probe.databaseId == null || probe.databaseId!.isEmpty) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'The database has no installation metadata.',
        probe: probe,
      );
    }
    if (!probe.migrationComplete) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'The database is not marked complete (state=${probe.state}).',
        probe: probe,
      );
    }
    if (hasReceipt &&
        receipt['databaseId']?.toString() != probe.databaseId) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'The installation receipt and database identity disagree.',
        probe: probe,
      );
    }
    final admissionError = await _verifyAndAdmit(probe, receipt);
    if (admissionError != null) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: admissionError,
        probe: probe,
      );
    }
    return ChatInstallationResult(
      state: ChatInstallationState.ready,
      message: 'SQLite is authoritative.',
      probe: probe,
      source: probe.source,
      publishRecovered: recovery.resolved && !recovery.restartRequired,
    );
  }

  /// Opens the live schema once for verification, repairs a missing sidecar,
  /// and removes `.previous`/temp/replaced recovery material.
  Future<String?> _verifyAndAdmit(
    DatabaseProbe probe,
    Map<String, dynamic>? receipt,
  ) async {
    if (probe.databaseId == null || probe.databaseId!.isEmpty) {
      return 'The database has no installation metadata.';
    }
    final db = AppDatabase.open(files.database, background: false);
    try {
      await db.verifyHealthy();
      final meta = await ChatRepository(db).readMigrationMeta();
      if (meta['database_id'] != probe.databaseId) {
        return 'migration_meta identity changed during admission.';
      }
    } on ChatSchemaAdmissionException catch (e) {
      return e.message;
    } catch (e) {
      return 'Database admission failed: $e';
    } finally {
      try {
        await db.checkpointAndTruncate();
      } catch (_) {}
      try {
        await db.close();
      } catch (_) {}
    }

    if (receipt == null || receipt['databaseId'] != probe.databaseId) {
      await _writeInstallationReceipt(probe);
    }
    await _cleanupRecoveryMaterial();
    return null;
  }

  Future<void> _cleanupRecoveryMaterial() async {
    // Defined "started successfully once": the target was verified and the
    // publish intent is gone. Keep .corrupt-* and publish-intent diagnostics.
    if (await files.publishIntent.exists()) return;
    await files.deleteFamily(files.previous);
    await files.deleteFamily(files.migrating);
    await files.deleteFamily(files.upgrading);
    try {
      await for (final entity in directory.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && name.contains('.replaced-')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  Future<String?> _verifyHealth() async {
    final db = AppDatabase.open(files.database, background: false);
    try {
      await db.verifyHealthy();
      return null;
    } on ChatSchemaAdmissionException catch (e) {
      return e.message;
    } catch (e) {
      return 'Database verification failed: $e';
    } finally {
      try {
        await db.close();
      } catch (_) {}
    }
  }

  Future<ChatInstallationResult> _createFreshOrReset({
    required String source,
    required bool keepLegacyImportDisabled,
    bool recoveredPublication = false,
  }) async {
    final databaseId = const Uuid().v4();
    final target = files.database;

    // Only reached with no readable published database. Never delete the
    // sidecars of a base file that survived deletion: they may contain
    // committed frames.
    if (await target.exists()) {
      await files.deleteFamily(target);
      if (await target.exists()) {
        return ChatInstallationResult(
          state: ChatInstallationState.failClosed,
          message: 'Could not remove the existing chat database; refusing to '
              'create a new database beside it.',
          probe: await probeDatabase(target),
        );
      }
    }
    await files.deleteSidecars(target);
    if (await files.wal.exists() || await files.shm.exists()) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'Stale SQLite sidecars could not be removed; refusing to '
            'create a database beside them.',
        probe: await probeDatabase(target),
      );
    }

    final db = AppDatabase.open(
      target,
      background: false,
      synchronousFull: true,
    );
    try {
      await db.verifyHealthy();
      await ChatRepository(db).putMigrationMeta(<String, String>{
        'database_id': databaseId,
        'source': source,
        'state': 'complete_clean',
        'installed_schema_version': '$currentChatSchemaVersion',
        'installed_by_app_version': appVersion,
        'installed_at_utc': DateTime.now().toUtc().toIso8601String(),
        'quarantine_count': '0',
      });
      await db.checkpointAndTruncate();
    } finally {
      await db.close();
    }
    if (!await files.ensureNoSidecars(target)) {
      return ChatInstallationResult(
        state: ChatInstallationState.failClosed,
        message: 'The new chat database still has a non-empty WAL; '
            'refusing to discard committed data.',
        probe: await probeDatabase(target),
      );
    }

    final probe = await probeDatabase(target);
    await _writeInstallationReceipt(probe);

    if (keepLegacyImportDisabled) {
      await files.writeJsonAtomically(files.legacyImportDisabled, <String, dynamic>{
        'format': 1,
        'disabledAtUtc': DateTime.now().toUtc().toIso8601String(),
        'reason': 'reset',
      });
    }

    return ChatInstallationResult(
      state: ChatInstallationState.ready,
      message: source == 'reset'
          ? 'Created a reset chat database; Hive will not be imported.'
          : 'Created a fresh chat database.',
      probe: probe,
      source: source,
      publishRecovered: recoveredPublication,
    );
  }

  /// Finishes §8.10 steps 6-9 after a `chat_v2.reset` marker.
  Future<ChatInstallationResult> _completeReset() async {
    final existing = await probeDatabase(files.database);
    final hasIdentity =
        existing.databaseId != null && existing.databaseId!.isNotEmpty;
    // A reset marker authorizes deleting a bad database, but a database we
    // keep must be healthy and identifiable. Otherwise the next launch would
    // fail closed after the marker was already removed.
    if (existing.readable &&
        existing.schemaIsCurrent &&
        existing.source == 'reset' &&
        existing.migrationComplete &&
        hasIdentity &&
        (await _verifyHealth()) == null) {
      await _writeInstallationReceipt(existing);
      await files.writeJsonAtomically(files.legacyImportDisabled, <String, dynamic>{
        'format': 1,
        'disabledAtUtc': DateTime.now().toUtc().toIso8601String(),
        'reason': 'reset',
      });
      try {
        await files.resetMarker.delete();
      } catch (_) {}
      return ChatInstallationResult(
        state: ChatInstallationState.ready,
        message: 'Kept the post-reset database.',
        probe: existing,
        source: 'reset',
      );
    }

    // Reset is an explicit destructive action: remove SQLite artifacts, never
    // Hive files.
    await files.deleteFamily(files.database);
    await files.deleteFamily(files.migrating);
    await files.deleteFamily(files.upgrading);
    await files.deleteFamily(files.previous);
    try {
      await for (final entity in directory.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File &&
            (name.contains('.replaced-') || name.endsWith('.tmp'))) {
          await entity.delete();
        }
      }
    } catch (_) {}
    for (final file in <File>[
      files.publishIntent,
      files.migrationReceipt,
      files.installationReceipt,
    ]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    final result = await _createFreshOrReset(
      source: 'reset',
      keepLegacyImportDisabled: true,
    );
    // The marker is the reset authorization. If creation failed closed, keep
    // it so the next launch retries instead of treating a partial state as
    // a completed reset.
    if (result.state == ChatInstallationState.ready) {
      try {
        await files.resetMarker.delete();
      } catch (_) {}
    }
    return result;
  }

  Future<void> _writeInstallationReceipt(DatabaseProbe probe) async {
    await files.writeJsonAtomically(files.installationReceipt, <String, dynamic>{
      'format': 1,
      'version': 1,
      'databaseId': probe.databaseId,
      'schemaVersion': probe.userVersion,
      'source': probe.source,
      'state': probe.state,
      'installedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
    });
  }
}

/// Chat Hive artifacts owned by the chat store, including `.lock` companions.
/// Never includes unrelated Hive boxes or the retired snapshots box.
List<File> chatHiveFiles(Directory directory) {
  const boxes = <String>[
    'conversations',
    'messages',
    'tool_events_v1',
    'message_file_records_v1',
    'conversation_workspace_bindings_v2',
    'conversation_workspaces_v1',
  ];
  final result = <File>[];
  for (final box in boxes) {
    final file = File('${directory.path}${Platform.pathSeparator}$box.hive');
    if (file.existsSync()) result.add(file);
    final lock = File('${file.path}.lock');
    if (lock.existsSync()) result.add(lock);
  }
  return result;
}
