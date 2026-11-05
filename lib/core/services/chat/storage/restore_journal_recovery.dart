import 'dart:io';

import 'package:path/path.dart' as p;

import '../../logging/flutter_logger.dart';
import 'chat_database_files.dart';
import 'database_family_publisher.dart';
import 'file_restore_stager.dart';
import 'restore_journal.dart';
import 'settings_snapshot.dart';

class RestoreRecoveryResult {
  const RestoreRecoveryResult({
    required this.resolved,
    required this.failClosed,
    required this.message,
  });

  final bool resolved;
  final bool failClosed;
  final String message;

  bool get ok => resolved && !failClosed;
}

/// Completes or rolls back a restore journal left by a crashed process (§2.3).
///
/// Must run before the installation gate: the gate deletes `.previous` and
/// `.replaced-*` recovery material during a clean admission.
class RestoreJournalRecovery {
  RestoreJournalRecovery({
    required this.directory,
    required this.appVersion,
  }) : files = ChatDatabaseFiles(directory);

  final Directory directory;
  final String appVersion;
  final ChatDatabaseFiles files;

  Future<RestoreRecoveryResult> recoverIfNeeded() async {
    RestoreJournal? journal;
    try {
      journal = await RestoreJournal.read(files);
    } on RestoreJournalCorruptException catch (error) {
      // Fail closed: a journal we cannot read may describe partially moved
      // live data, so nothing is deleted or renamed without it.
      return RestoreRecoveryResult(
        resolved: false,
        failClosed: true,
        message: '${error.message} Nothing was deleted.',
      );
    }
    if (journal == null) {
      return const RestoreRecoveryResult(
        resolved: true,
        failClosed: false,
        message: 'No restore journal.',
      );
    }

    FlutterLogger.log(
      'Recovering ${restoreJournalSummary(journal)}',
      tag: 'backup-restore',
    );

    final publisher = DatabaseFamilyPublisher(files, appVersion: appVersion);
    try {
      final publishRecovery = await publisher.recoverIfNeeded();
      if (publishRecovery.failClosed) {
        return RestoreRecoveryResult(
          resolved: false,
          failClosed: true,
          message:
              'Restore recovery stopped at the database publisher: '
              '${publishRecovery.message}',
        );
      }
    } catch (error) {
      return RestoreRecoveryResult(
        resolved: false,
        failClosed: true,
        message:
            'Restore recovery could not inspect the publish intent: $error. '
            'Nothing was deleted.',
      );
    }

    final target = await probeDatabase(files.database);
    final targetIsRestored = target.publishId == journal.publishId;

    if (journal.stage == RestoreJournal.stageRollingBack) {
      if (!targetIsRestored &&
          target.readable &&
          target.schemaIsPublished &&
          target.migrationComplete) {
        // The publisher already reinstated a readable old target (for example
        // after `publish()` resolved to the old family). Only staging and file
        // swaps remain; there is nothing to roll back.
        return _abandonPreCommit(journal);
      }
      return _rollback(journal, target);
    }
    if (journal.stage == RestoreJournal.stagePublishUnresolved) {
      if (targetIsRestored) return _rollback(journal, target);
      return _abandonPreCommit(journal);
    }

    if (targetIsRestored) {
      final problem = await _verifyRestoredTarget(journal, target);
      if (problem != null) {
        return _rollback(journal, target);
      }
      return _finish(journal);
    }

    // The publication did not commit. A readable published target is the old
    // database and must stay live.
    if (target.readable &&
        target.schemaIsPublished &&
        target.migrationComplete) {
      return _abandonPreCommit(journal);
    }
    if (!target.exists) {
      // Nothing has ever been published (fresh install) or the restore never
      // reached the commit point; abandoning the staging copy is safe.
      final wasGoingToPublish = journal.stage == RestoreJournal.stageDbPublished ||
          journal.stage == RestoreJournal.stageLiveVerified ||
          journal.stage == RestoreJournal.stageSettingsApplied ||
          journal.stage == RestoreJournal.stageDone;
      if (!wasGoingToPublish) return _abandonPreCommit(journal);
    }
    return RestoreRecoveryResult(
      resolved: false,
      failClosed: true,
      message:
          'Restore recovery found an unreadable live database. Every file was '
          'kept for diagnostics.',
    );
  }

  /// In-process rollback after a failed pre-live or live verification.
  Future<RestoreRecoveryResult> rollbackCommitted(RestoreJournal journal) async {
    final target = await probeDatabase(files.database);
    if (target.publishId == journal.publishId || !target.readable) {
      return _rollback(journal, target);
    }
    // The publisher already returned to a readable old target; only files
    // remain.
    return _abandonPreCommit(journal);
  }

  Future<String?> _verifyRestoredTarget(
    RestoreJournal journal,
    DatabaseProbe target,
  ) async {
    if (!target.readable ||
        !target.schemaIsCurrent ||
        !target.migrationComplete) {
      return 'The restored database is not a readable complete database.';
    }
    if (journal.stagingDatabaseId.isNotEmpty &&
        target.databaseId != journal.stagingDatabaseId) {
      return 'The restored database identity does not match the journal.';
    }
    return verifySqliteFile(files.database);
  }

  /// Deletes staging, rolls back swapped file directories, and discards the
  /// journal. The live database is untouched.
  Future<RestoreRecoveryResult> _abandonPreCommit(
    RestoreJournal journal,
  ) async {
    final stager = FileRestoreStager(
      appDataDirectory: directory,
      restoreId: journal.restoreId,
    );
    await stager.rollback(journal);
    await files.deleteFamily(files.restoring);
    await stager.cleanup();
    await journal.discard();
    FlutterLogger.log(
      'Restore abandoned before publish; live data was kept.',
      tag: 'backup-restore',
    );
    return const RestoreRecoveryResult(
      resolved: true,
      failClosed: false,
      message: 'Restore rolled back; the previous data is live.',
    );
  }

  /// Restores the identity-matching preserved family and the previous file
  /// directories. Fails closed (keeping every file) when no such family exists.
  Future<RestoreRecoveryResult> _rollback(
    RestoreJournal journal,
    DatabaseProbe currentTarget,
  ) async {
    final preservedPath = journal.preservedPath;
    final preservedDatabaseId = journal.preservedDatabaseId;
    if (preservedPath == null || preservedDatabaseId == null) {
      return const RestoreRecoveryResult(
        resolved: false,
        failClosed: true,
        message:
            'The restore must be rolled back but the journal has no preserved '
            'database identity. Nothing was deleted.',
      );
    }

    final preserved = File(preservedPath);
    final preservedProbe = await probeDatabase(preserved);
    if (!preservedProbe.readable ||
        preservedProbe.databaseId != preservedDatabaseId) {
      return const RestoreRecoveryResult(
        resolved: false,
        failClosed: true,
        message:
            'The preserved database no longer matches the restore journal. '
            'Nothing was deleted.',
      );
    }

    if (currentTarget.exists) {
      final failed = File(
        '${files.database.path}.failed-restore-${journal.restoreId}',
      );
      if (await failed.exists()) {
        return const RestoreRecoveryResult(
          resolved: false,
          failClosed: true,
          message:
              'A quarantine copy for this restore already exists; nothing was '
              'deleted.',
        );
      }
      await files.moveFamily(files.database, failed);
    }
    await files.moveFamily(preserved, files.database);

    final restored = await probeDatabase(files.database);
    if (!restored.readable ||
        restored.databaseId != preservedDatabaseId ||
        !restored.schemaIsPublished) {
      return const RestoreRecoveryResult(
        resolved: false,
        failClosed: true,
        message:
            'The preserved database could not be reinstated; every file was '
            'kept.',
      );
    }

    final stager = FileRestoreStager(
      appDataDirectory: directory,
      restoreId: journal.restoreId,
    );
    await stager.rollback(journal);
    await files.deleteFamily(files.restoring);
    await stager.cleanup();
    await journal.discard();
    FlutterLogger.log(
      'Restore rolled back to the preserved database ($preservedDatabaseId).',
      tag: 'backup-restore',
    );
    return const RestoreRecoveryResult(
      resolved: true,
      failClosed: false,
      message: 'Restore rolled back to the previous database.',
    );
  }

  /// Finishes a committed restore: removes staging and the preserved family,
  /// applies any staged settings (best effort), and discards the journal.
  Future<RestoreRecoveryResult> _finish(RestoreJournal journal) async {
    final stager = FileRestoreStager(
      appDataDirectory: directory,
      restoreId: journal.restoreId,
    );
    await stager.cleanup();
    await files.deleteFamily(files.restoring);

    final preservedPath = journal.preservedPath;
    if (preservedPath != null && preservedPath.isNotEmpty) {
      final preserved = File(preservedPath);
      if (await preserved.exists()) {
        // `.corrupt-*` is quarantined old data, not a rollback source; keep it
        // for diagnostics but do not block the committed restore on it.
        final isQuarantine = preservedPath.contains('.corrupt-');
        final expectedId = journal.preservedDatabaseId;
        final probe = await probeDatabase(preserved);
        final identityMatches = expectedId != null &&
            probe.readable &&
            probe.databaseId == expectedId;
        if (identityMatches && !isQuarantine) {
          await files.deleteFamily(preserved);
        } else if (!isQuarantine) {
          // The gate deletes `.previous`/`.replaced-*` after this journal is
          // gone. Keep the journal so unknown recovery material survives.
          return RestoreRecoveryResult(
            resolved: false,
            failClosed: true,
            message:
                'The restore committed, but the preserved database family '
                'does not match the journal. Every file was kept; inspect '
                '$preservedPath before retrying.',
          );
        }
      }
    }

    final settings = SettingsSnapshot(files);
    var settingsResolved = true;
    if (await settings.hasPending()) {
      try {
        await settings.applyPending();
      } catch (error) {
        settingsResolved = false;
        FlutterLogger.log(
          'Staged settings could not be applied during recovery: $error',
          tag: 'backup-restore',
        );
      }
    }
    if (settingsResolved) await settings.discardSnapshot();

    await journal.discard();
    FlutterLogger.log(
      'Restore recovery completed the committed restore.',
      tag: 'backup-restore',
    );
    return const RestoreRecoveryResult(
      resolved: true,
      failClosed: false,
      message: 'Restore completed.',
    );
  }
}

/// Diagnostics for tests: the quarantine path for a failed restore.
String failedRestorePath(ChatDatabaseFiles files, String restoreId) =>
    '${files.database.path}.failed-restore-$restoreId';

/// Helper kept close to recovery for logging paths without exposing app data.
String restoreStagingPath(Directory appDataDirectory, String restoreId) =>
    p.join(appDataDirectory.path, 'restore_staging_$restoreId');
