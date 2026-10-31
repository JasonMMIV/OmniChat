import 'dart:io';

import 'chat_database_files.dart';
import 'chat_maintenance_lock.dart';
import 'chat_repository.dart' show ChatStorageCounts;
import 'database_installation_gate.dart';
import 'legacy_hive_importer.dart';
import 'pre_migration_backup_service.dart';

enum ChatStorageGateStage {
  /// A healthy current-schema SQLite database is ready.
  ready,

  /// The Hive migration completed and the published database was admitted.
  migrated,

  /// The user must decide whether to restore a backup or reset storage.
  needsRestoreOrReset,

  /// SQLite is unusable (unknown/newer/corrupt/split-brain). The caller stays
  /// on Hive for this release; nothing was deleted.
  failed,
}

enum ChatMigrationBackupDecisionKind { backup, skip, cancel }

class ChatMigrationBackupDecision {
  const ChatMigrationBackupDecision._(this.kind, this.destination);

  const ChatMigrationBackupDecision.skip()
    : this._(ChatMigrationBackupDecisionKind.skip, null);

  const ChatMigrationBackupDecision.cancel()
    : this._(ChatMigrationBackupDecisionKind.cancel, null);

  const ChatMigrationBackupDecision.backup(Directory destination)
    : this._(ChatMigrationBackupDecisionKind.backup, destination);

  final ChatMigrationBackupDecisionKind kind;
  final Directory? destination;
}

typedef ChatMigrationBackupPrompt =
    Future<ChatMigrationBackupDecision> Function();

class ChatStorageGateResult {
  const ChatStorageGateResult({
    required this.stage,
    required this.message,
    this.migration,
    this.installation,
  });

  final ChatStorageGateStage stage;
  final String message;
  final LegacyMigrationResult? migration;
  final ChatInstallationResult? installation;

  bool get sqliteReady =>
      stage == ChatStorageGateStage.ready ||
      stage == ChatStorageGateStage.migrated;
}

/// Startup orchestration for the chat-storage cutover (§9.6): installation
/// admission first, optional one-time Hive migration second, admission of the
/// published database third.
///
/// This class does not switch `ChatService` to SQLite and never opens a live
/// chat connection. Callers use [sqliteReady] to decide whether the future
/// SQLite-backed facade may be used; on [ChatStorageGateStage.failed] they keep
/// the existing Hive storage for one release.
class ChatStorageGate {
  ChatStorageGate({
    required this.directory,
    required this.appVersion,
    this.backupChoice = 'skipped',
    this.backupArtifact,
    this.backupPrompt,
    this.requireBackupPrompt = false,
    this.onMigrationProgress,
  }) : files = ChatDatabaseFiles(directory);

  final Directory directory;
  final String appVersion;
  final String backupChoice;
  final String? backupArtifact;
  final ChatMigrationBackupPrompt? backupPrompt;

  /// Production startup requires an explicit backup/skip decision before the
  /// one-time import. Direct gate tests may opt out to exercise the importer.
  final bool requireBackupPrompt;
  final void Function(String stage, ChatStorageCounts? counts)?
  onMigrationProgress;

  final ChatDatabaseFiles files;

  Future<ChatStorageGateResult> ensureReady() async {
    ChatMaintenanceLock lock;
    try {
      lock = await ChatMaintenanceLock.acquire(
        directory,
        purpose: 'chat-storage-gate',
      );
    } on ChatMaintenanceLockBusy catch (e) {
      return ChatStorageGateResult(
        stage: ChatStorageGateStage.failed,
        message: e.toString(),
      );
    }
    try {
      onMigrationProgress?.call('checking', null);
      final installation = await DatabaseInstallationGate(
        directory: directory,
        appVersion: appVersion,
      ).ensureReady();

      switch (installation.state) {
        case ChatInstallationState.ready:
          return ChatStorageGateResult(
            stage: ChatStorageGateStage.ready,
            message: installation.message,
            installation: installation,
          );
        case ChatInstallationState.failClosed:
          return ChatStorageGateResult(
            stage: ChatStorageGateStage.failed,
            message: installation.message,
            installation: installation,
          );
        case ChatInstallationState.needsRestoreOrReset:
          return ChatStorageGateResult(
            stage: ChatStorageGateStage.needsRestoreOrReset,
            message: installation.message,
            installation: installation,
          );
        case ChatInstallationState.needsMigration:
          break;
      }

      // No active stream may exist while the migration runs; the caller is
      // responsible for pausing chat before calling this gate.
      var resolvedBackupChoice = backupChoice;
      String? resolvedBackupArtifact = backupArtifact;
      final prompt = backupPrompt;
      if (prompt == null && requireBackupPrompt) {
        return const ChatStorageGateResult(
          stage: ChatStorageGateStage.failed,
          message:
              'A backup decision is required before migrating legacy '
              'chat data. Restart OmniChat from the chat screen to retry; '
              'Hive remains in use.',
        );
      }
      if (prompt != null) {
        final decision = await prompt();
        if (decision.kind == ChatMigrationBackupDecisionKind.cancel) {
          return const ChatStorageGateResult(
            stage: ChatStorageGateStage.failed,
            message:
                'Chat storage setup was cancelled before migration; '
                'Hive remains in use.',
          );
        }
        if (decision.kind == ChatMigrationBackupDecisionKind.backup) {
          final destination = decision.destination;
          if (destination == null || destination.path.trim().isEmpty) {
            return const ChatStorageGateResult(
              stage: ChatStorageGateStage.failed,
              message:
                  'A backup folder was not selected; Hive remains in '
                  'use.',
            );
          }
          onMigrationProgress?.call('backing-up', null);
          try {
            final backup =
                await PreMigrationBackupService(
                  directory: directory,
                  appVersion: appVersion,
                ).create(
                  destination: destination,
                  onProgress: (stage) => onMigrationProgress?.call(stage, null),
                );
            resolvedBackupChoice = 'completed';
            resolvedBackupArtifact = backup.archive.path;
          } catch (e) {
            return ChatStorageGateResult(
              stage: ChatStorageGateStage.failed,
              message:
                  'Pre-migration backup failed: $e. Hive was not '
                  'modified; retry or skip the backup on the next launch.',
            );
          }
        }
      }

      onMigrationProgress?.call('migrating', null);
      final migration = await LegacyHiveImporter(
        hiveDirectory: directory,
        files: files,
        appVersion: appVersion,
        backupChoice: resolvedBackupChoice,
        backupArtifact: resolvedBackupArtifact,
        onProgress: onMigrationProgress,
      ).run();

      onMigrationProgress?.call('validating', null);
      final admitted = await DatabaseInstallationGate(
        directory: directory,
        appVersion: appVersion,
      ).ensureReady();
      if (!admitted.isReady) {
        return ChatStorageGateResult(
          stage: ChatStorageGateStage.failed,
          message:
              'Migration published but admission failed: '
              '${admitted.message}',
          migration: migration,
          installation: admitted,
        );
      }
      return ChatStorageGateResult(
        stage: ChatStorageGateStage.migrated,
        message: 'Chat Hive data migrated to SQLite.',
        migration: migration,
        installation: admitted,
      );
    } on ChatMaintenanceLockBusy catch (e) {
      return ChatStorageGateResult(
        stage: ChatStorageGateStage.failed,
        message: e.toString(),
      );
    } on LegacyMigrationException catch (e) {
      // Hive is intact; the caller can keep using the legacy storage.
      return ChatStorageGateResult(
        stage: ChatStorageGateStage.failed,
        message: e.toString(),
      );
    } catch (e) {
      // Storage initialization must fail closed, never crash the app.
      return ChatStorageGateResult(
        stage: ChatStorageGateStage.failed,
        message: 'Chat storage initialization failed: $e',
      );
    } finally {
      await lock.release();
    }
  }
}
