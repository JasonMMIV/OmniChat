import 'dart:io';

import 'app_database.dart';
import 'chat_database_files.dart';

/// Result of publishing a temp/upgrading database family.
class DatabasePublishOutcome {
  const DatabasePublishOutcome({
    required this.success,
    required this.publishId,
    required this.targetProbe,
    this.previousPath,
    this.replacedPath,
    this.error,
  });

  final bool success;
  final String publishId;
  final DatabaseProbe targetProbe;
  final String? previousPath;
  final String? replacedPath;
  final String? error;
}

/// Result of publish-intent recovery. `resolved` means no intent remains and
/// the caller may continue; `failClosed` must stop startup without deleting
/// target, temp or previous.
class PublishRecovery {
  const PublishRecovery({
    required this.resolved,
    required this.failClosed,
    required this.message,
    this.restartRequired = false,
  });

  final bool resolved;
  final bool failClosed;
  final String message;

  /// The old target is intact but the temp database must be rebuilt.
  final bool restartRequired;
}

/// Publishes database families according to §8.2.1: a durable publish-intent
/// marker, `.previous` preservation, publish-id verification, and split-brain
/// diagnostics that never delete both copies.
class DatabaseFamilyPublisher {
  DatabaseFamilyPublisher(this.files, {required this.appVersion});

  final ChatDatabaseFiles files;
  final String appVersion;

  static const String stagePrepared = 'prepared';
  static const String stageTargetPreserved = 'target-preserved';
  static const String stagePublished = 'published';
  static const String stageVerified = 'verified';

  /// Publishes [temp] as the live database. The temp database must already be
  /// complete, checkpointed, closed, and carry `migration_meta.publish_id`.
  Future<DatabasePublishOutcome> publish({
    required File temp,
    required String operation,
  }) async {
    if (operation != 'migrate' && operation != 'upgrade') {
      throw ArgumentError.value(operation, 'operation');
    }

    final tempProbe = await probeDatabase(temp, includeHash: true);
    if (!tempProbe.readable || !tempProbe.schemaIsCurrent) {
      return DatabasePublishOutcome(
        success: false,
        publishId: tempProbe.publishId ?? '',
        targetProbe: tempProbe,
        error: 'Temp database is not a readable current-schema database.',
      );
    }
    final publishId = tempProbe.publishId;
    final tempDatabaseId = tempProbe.databaseId;
    if (publishId == null ||
        publishId.isEmpty ||
        tempDatabaseId == null ||
        tempDatabaseId.isEmpty) {
      return DatabasePublishOutcome(
        success: false,
        publishId: publishId ?? '',
        targetProbe: tempProbe,
        error: 'Temp database is missing publish_id/database_id.',
      );
    }
    if (!tempProbe.migrationComplete) {
      return DatabasePublishOutcome(
        success: false,
        publishId: publishId,
        targetProbe: tempProbe,
        error: 'Temp database is not marked complete (state=${tempProbe.state}).',
      );
    }

    // A closed temp database must not leave committed frames in a WAL.
    if (!await files.ensureNoSidecars(temp)) {
      return DatabasePublishOutcome(
        success: false,
        publishId: publishId,
        targetProbe: tempProbe,
        error: 'Temp database still has a non-empty WAL after close.',
      );
    }
    final tempIntegrityError = await verifySqliteFile(temp);
    if (tempIntegrityError != null) {
      return DatabasePublishOutcome(
        success: false,
        publishId: publishId,
        targetProbe: tempProbe,
        error: tempIntegrityError,
      );
    }

    final target = files.database;
    final targetProbe = await probeDatabase(target, includeHash: true);
    final previousPath = files.previous.path;

    final intent = <String, dynamic>{
      'format': 1,
      'operation': operation,
      'tempPath': temp.path,
      'targetPath': target.path,
      'previousPath': previousPath,
      'publishId': publishId,
      'tempDatabaseId': tempDatabaseId,
      'targetDatabaseId': targetProbe.exists ? targetProbe.databaseId : null,
      'previousDatabaseId': null,
      'previousSchemaVersion': null,
      'previousSizeBytes': null,
      'previousSha256': null,
      'targetSchemaVersion': currentChatSchemaVersion,
      'tempSizeBytes': tempProbe.sizeBytes,
      'tempSha256': tempProbe.sha256Hex,
      'stage': stagePrepared,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
    };
    await files.writeJsonAtomically(files.publishIntent, intent);

    String? previousUsed;
    String? replacedPath;

    // Preserve the current target before mutating it. If a `.previous` family
    // already exists, never overwrite it: move the target aside as
    // `.replaced-<publish_id>` for cleanup instead. A family counts as
    // existing when any of its sidecars exists, otherwise the rename would
    // silently replace recovery material.
    if (await target.exists() || await files.wal.exists() || await files.shm.exists()) {
      final preserveAsPrevious = !await _previousFamilyExists();
      final destination = preserveAsPrevious
          ? files.previous
          : File('${target.path}.replaced-$publishId');

      if (!targetProbe.readable) {
        // An unreadable target is not opened as live data again; keep it as
        // quarantine material.
        final corrupt = File('${target.path}.corrupt-$publishId');
        await _moveFamily(target, corrupt);
        replacedPath = corrupt.path;
      } else {
        await _moveFamily(target, destination);
        if (preserveAsPrevious) {
          previousUsed = destination.path;
        } else {
          replacedPath = destination.path;
        }
      }

      // Only probe `.previous` when the target was actually moved there. An
      // unreadable target is quarantined as `.corrupt-*`; requiring a
      // `.previous` in that case would block publication forever.
      final preserved = previousUsed != null
          ? await probeDatabase(files.previous, includeHash: true)
          : null;
      if (preserved != null && !preserved.exists) {
        return DatabasePublishOutcome(
          success: false,
          publishId: publishId,
          targetProbe: targetProbe,
          error: 'Failed to preserve the existing target as .previous.',
        );
      }

      intent
        ..['stage'] = stageTargetPreserved
        ..['previousDatabaseId'] = preserved?.databaseId
        ..['previousSchemaVersion'] = preserved?.userVersion
        ..['previousSizeBytes'] = preserved?.sizeBytes
        ..['previousSha256'] = preserved?.sha256Hex
        ..['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
      await files.writeJsonAtomically(files.publishIntent, intent);
    }

    // A `-wal`/`-shm` whose base file is missing must never remain at the
    // target path: after the rename below SQLite would attach it to the new
    // database and could report corruption or replay foreign frames.
    await _quarantineOrphanTargetSidecars(publishId);

    // Rename the temp family into place.
    await _moveFamily(temp, target);
    await fsyncDirectory(files.directory);
    intent
      ..['stage'] = stagePublished
      ..['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    await files.writeJsonAtomically(files.publishIntent, intent);

    final verification = await _verifyTarget(target, publishId);
    if (verification != null) {
      return DatabasePublishOutcome(
        success: false,
        publishId: publishId,
        targetProbe: await probeDatabase(target),
        error: verification,
      );
    }

    intent
      ..['stage'] = stageVerified
      ..['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    await files.writeJsonAtomically(files.publishIntent, intent);
    try {
      await files.publishIntent.delete();
    } catch (_) {}
    await files.deleteSidecars(temp);

    return DatabasePublishOutcome(
      success: true,
      publishId: publishId,
      targetProbe: await probeDatabase(target),
      previousPath: previousUsed,
      replacedPath: replacedPath,
    );
  }

  /// Inspects `chat_v2.publish-intent.json` and completes/aborts a crashed
  /// publication. Never deletes both target and temp.
  Future<PublishRecovery> recoverIfNeeded() async {
    if (!await files.publishIntent.exists()) {
      return const PublishRecovery(
        resolved: true,
        failClosed: false,
        message: 'No publish intent.',
      );
    }

    final raw = await files.readJson(files.publishIntent);
    if (raw == null) {
      return const PublishRecovery(
        resolved: false,
        failClosed: true,
        message: 'Malformed publish intent; files were kept for diagnostics.',
      );
    }

    final publishId = raw['publishId']?.toString() ?? '';
    final tempPath = raw['tempPath']?.toString() ?? '';
    final tempDatabaseId = raw['tempDatabaseId']?.toString() ?? '';
    final previousDatabaseId = raw['previousDatabaseId']?.toString();
    final stage = raw['stage']?.toString() ?? '';
    final temp = File(tempPath.isEmpty ? files.migrating.path : tempPath);

    if (publishId.isEmpty || tempDatabaseId.isEmpty) {
      return const PublishRecovery(
        resolved: false,
        failClosed: true,
        message: 'Publish intent is missing identity fields.',
      );
    }

    final targetProbe = await probeDatabase(files.database, includeHash: false);
    final tempProbe = await probeDatabase(temp, includeHash: false);
    final previousProbe =
        await probeDatabase(files.previous, includeHash: false);

    final targetHasPublishId = targetProbe.publishId == publishId;
    final targetIsPrevious =
        previousDatabaseId != null && targetProbe.databaseId == previousDatabaseId;
    final tempMatches = tempProbe.databaseId == tempDatabaseId;

    // 1. Target already carries the intent publish id: publication completed
    // (or crashed after the rename). Verify, then clean up.
    if (targetHasPublishId) {
      final verification = await _verifyTarget(files.database, publishId);
      if (verification != null) {
        return PublishRecovery(
          resolved: false,
          failClosed: true,
          message: 'Published target failed verification: $verification',
        );
      }
      if (tempProbe.exists) {
        if (tempMatches) {
          await _removeFamily(temp);
        } else if (tempProbe.readable) {
          return const PublishRecovery(
            resolved: false,
            failClosed: true,
            message: 'Split-brain: target is published but temp has a '
                'different database id. Nothing was deleted.',
          );
        } else {
          await _removeFamily(temp);
        }
      }
      try {
        await files.publishIntent.delete();
      } catch (_) {}
      return const PublishRecovery(
        resolved: true,
        failClosed: false,
        message: 'Recovered a published database.',
      );
    }

    // 2. Temp identity mismatch is a split-brain, not a retry.
    if (tempProbe.exists && tempProbe.readable && !tempMatches) {
      return const PublishRecovery(
        resolved: false,
        failClosed: true,
        message: 'Split-brain: temp database id does not match the intent. '
            'Nothing was deleted.',
      );
    }

    // 3. Target is a valid old database (move not yet performed, or restore).
    if (targetProbe.readable && !targetHasPublishId) {
      final targetProblem = _recoveryTargetProblem(targetProbe);
      if (targetProblem != null) {
        return PublishRecovery(
          resolved: false,
          failClosed: true,
          message: 'Split-brain: $targetProblem. Nothing was deleted.',
        );
      }
      if (targetIsPrevious || previousDatabaseId == null) {
        if (tempProbe.readable && tempMatches) {
          // Normal pre-publish crash: preserve the target and complete.
          if (await _previousFamilyExists()) {
            // A previous already exists; keep the target as replaced material.
            await _moveFamily(
              files.database,
              File('${files.database.path}.replaced-$publishId'),
            );
          } else {
            await _moveFamily(files.database, files.previous);
          }
          await _quarantineOrphanTargetSidecars(publishId);
          await _moveFamily(temp, files.database);
          final verification = await _verifyTarget(files.database, publishId);
          if (verification != null) {
            return PublishRecovery(
              resolved: false,
              failClosed: true,
              message: 'Recovered publish failed verification: $verification',
            );
          }
          try {
            await files.publishIntent.delete();
          } catch (_) {}
          return const PublishRecovery(
            resolved: true,
            failClosed: false,
            message: 'Completed an interrupted publication.',
          );
        }
        // Target is intact; discard the bad/absent temp and rebuild.
        if (tempProbe.exists) await _removeFamily(temp);
        try {
          await files.publishIntent.delete();
        } catch (_) {}
        return const PublishRecovery(
          resolved: true,
          failClosed: false,
          restartRequired: true,
          message: 'Kept the intact target and discarded the invalid temp; '
              'the import/upgrade must be restarted.',
        );
      }
      return const PublishRecovery(
        resolved: false,
        failClosed: true,
        message: 'Split-brain: target matches neither the publish id nor the '
            'recorded previous database. Nothing was deleted.',
      );
    }

    // 4. Target missing/unreadable.
    if (tempProbe.readable && tempMatches) {
      if (targetProbe.exists && !targetProbe.readable) {
        await _moveFamily(
          files.database,
          File('${files.database.path}.corrupt-$publishId'),
        );
      }
      await _quarantineOrphanTargetSidecars(publishId);
      await _moveFamily(temp, files.database);
      final verification = await _verifyTarget(files.database, publishId);
      if (verification != null) {
        return PublishRecovery(
          resolved: false,
          failClosed: true,
          message: 'Recovered publish failed verification: $verification',
        );
      }
      try {
        await files.publishIntent.delete();
      } catch (_) {}
      return const PublishRecovery(
        resolved: true,
        failClosed: false,
        message: 'Completed publication from a valid temp database.',
      );
    }

    // 5. Nothing publishable: restore .previous only when its identity matches.
    if (stage == stagePublished || stage == stageVerified) {
      return PublishRecovery(
        resolved: false,
        failClosed: true,
        message: 'Split-brain: publish reached $stage but the target does not '
            'carry the publish id. Nothing was deleted.',
      );
    }
    if (previousProbe.exists &&
        previousProbe.readable &&
        previousDatabaseId != null &&
        previousProbe.databaseId == previousDatabaseId &&
        await _previousMatchesRecorded(raw, previousProbe)) {
      await _moveFamily(files.previous, files.database);
      try {
        await files.publishIntent.delete();
      } catch (_) {}
      return const PublishRecovery(
        resolved: true,
        failClosed: false,
        restartRequired: true,
        message: 'Restored the verified previous database; retry the operation.',
      );
    }

    return const PublishRecovery(
      resolved: false,
      failClosed: true,
      message: 'No publishable copy remains. All files were kept for '
          'diagnostics.',
    );
  }

  /// Verifies the preserved family against the intent before restoring it.
  /// A matching database id alone is not enough: a changed or truncated copy
  /// must never become live data.
  Future<bool> _previousMatchesRecorded(
    Map<String, dynamic> intent,
    DatabaseProbe probe,
  ) async {
    final recordedSchema = intent['previousSchemaVersion'];
    if (recordedSchema is int && probe.userVersion != recordedSchema) {
      return false;
    }
    final recordedSha = intent['previousSha256'];
    if (recordedSha is String && recordedSha.isNotEmpty) {
      try {
        return await sha256File(files.previous) == recordedSha;
      } catch (_) {
        return false;
      }
    }
    final recordedSize = intent['previousSizeBytes'];
    if (recordedSize is int && probe.sizeBytes != recordedSize) {
      return false;
    }
    return true;
  }

  /// Why a readable target must not be replaced by an intent's temp, or
  /// `null` when it is a published schema this app may preserve.
  String? _recoveryTargetProblem(DatabaseProbe probe) {
    if (!probe.schemaIsPublished) {
      return 'target schema ${probe.userVersion} has never been published';
    }
    if (probe.databaseId == null || probe.databaseId!.isEmpty) {
      return 'target has no installation identity';
    }
    if (probe.userVersion == currentChatSchemaVersion &&
        !probe.migrationComplete) {
      return 'target is not marked complete (state=${probe.state})';
    }
    return null;
  }

  /// True when any part of the `.previous` family exists. Checking only the
  /// base file would let a sidecar-only leftover be overwritten by a rename.
  Future<bool> _previousFamilyExists() async {
    return await files.previous.exists() ||
        await File('${files.previous.path}-wal').exists() ||
        await File('${files.previous.path}-shm').exists();
  }

  /// Moves target sidecars whose base file is gone to a diagnostic path next
  /// to the database. They must not stay where the new database is renamed in.
  Future<void> _quarantineOrphanTargetSidecars(String publishId) async {
    final target = files.database;
    if (await target.exists()) return;
    final wal = files.wal;
    final shm = files.shm;
    if (!await wal.exists() && !await shm.exists()) return;

    var destination = File('${target.path}.orphan-$publishId');
    var suffix = 1;
    while (await File('${destination.path}-wal').exists() ||
        await File('${destination.path}-shm').exists()) {
      destination = File('${target.path}.orphan-$publishId-${suffix++}');
    }
    if (await wal.exists()) {
      await wal.rename('${destination.path}-wal');
    }
    if (await shm.exists()) {
      await shm.rename('${destination.path}-shm');
    }
  }

  Future<String?> _verifyTarget(File target, String publishId) async {
    final probe = await probeDatabase(target, includeHash: false);
    if (!probe.readable || !probe.schemaIsCurrent) {
      return 'Target is not a readable current-schema database.';
    }
    if (probe.publishId != publishId) {
      return 'Target does not carry the intent publish id.';
    }
    if (!probe.migrationComplete) {
      return 'Target migration state is ${probe.state}.';
    }
    return verifySqliteFile(target);
  }

  Future<void> _moveFamily(File from, File to) async {
    if (!await from.exists()) return;
    final destinationParent = to.parent;
    if (!await destinationParent.exists()) {
      await destinationParent.create(recursive: true);
    }
    if (await to.exists()) {
      // Never overwrite a preserved family silently.
      throw FileSystemException('Destination already exists', to.path);
    }
    await from.rename(to.path);
    for (final suffix in const <String>['-wal', '-shm']) {
      final sidecar = File('${from.path}$suffix');
      if (await sidecar.exists()) {
        await sidecar.rename('${to.path}$suffix');
      }
    }
  }

  Future<void> _removeFamily(File base) async {
    await files.deleteFamily(base);
  }
}
