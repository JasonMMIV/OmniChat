import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'chat_database_files.dart';
import 'chat_maintenance_lock.dart';
import 'database_installation_gate.dart';

/// Legacy cleanup is refused because the database or its receipt is not in a
/// state that proves the Hive snapshot is redundant.
class LegacyRetirementException implements Exception {
  const LegacyRetirementException(this.message);

  final String message;

  @override
  String toString() => 'LegacyRetirementException: $message';
}

class LegacyArtifact {
  const LegacyArtifact({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAtMs,
    this.sha256,
  });

  final String name;
  final int sizeBytes;
  final int modifiedAtMs;

  /// Recorded at inventory time; when present it must match before unlink.
  final String? sha256;

  Map<String, dynamic> toJson() => {
    'name': name,
    'sizeBytes': sizeBytes,
    'modifiedAtMs': modifiedAtMs,
    if (sha256 != null) 'sha256': sha256,
  };

  static LegacyArtifact? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    final size = raw['sizeBytes'];
    final modified = raw['modifiedAtMs'];
    if (name == null || name.isEmpty || size is! num || modified is! num) {
      return null;
    }
    return LegacyArtifact(
      name: name,
      sizeBytes: size.toInt(),
      modifiedAtMs: modified.toInt(),
      sha256: raw['sha256']?.toString(),
    );
  }
}

enum LegacyRetirementState { none, deleting, completed }

class LegacyRetirementStatus {
  const LegacyRetirementStatus({
    required this.state,
    required this.artifacts,
    required this.totalBytes,
    this.requestedAtUtc,
    this.completedAtUtc,
    this.databaseId,
    this.source,
    this.migrationState,
    this.quarantineCount = 0,
    this.error,
    this.blockReason,
    this.requiresExport = false,
    this.canDelete = false,
    this.canDeleteAfterExport = false,
    this.canResume = false,
    this.canDiscardNeverMigrated = false,
    this.hasValidExport = false,
  });

  final LegacyRetirementState state;
  final List<LegacyArtifact> artifacts;
  final int totalBytes;
  final DateTime? requestedAtUtc;
  final DateTime? completedAtUtc;
  final String? databaseId;
  final String? source;
  final String? migrationState;
  final int quarantineCount;

  /// Set when the marker or database is malformed; nothing may be deleted.
  final String? error;

  /// Why the normal one-click cleanup is unavailable.
  final String? blockReason;

  /// `complete_with_issues`/quarantine cleanup needs a successful legacy
  /// export first.
  final bool requiresExport;
  final bool canDelete;
  final bool canDeleteAfterExport;
  final bool canResume;
  final bool hasValidExport;

  /// `source='reset'/'fresh'` files were never imported; only the explicit
  /// discard action (after export) may remove them.
  final bool canDiscardNeverMigrated;

  bool get hasLegacyFiles => artifacts.isNotEmpty;
}

/// Marker-backed deletion of the legacy Hive chat snapshot (§8.8).
///
/// The service never touches the SQLite database or user files. It refuses to
/// delete unless the database carries a complete migration receipt proving the
/// Hive snapshot is redundant, and it revalidates size/mtime/SHA-256 before
/// every unlink so a file changed after the inventory is never removed.
class LegacyRetirementService {
  LegacyRetirementService({required this.directory, required this.appVersion})
    : files = ChatDatabaseFiles(directory);

  static const int markerFormat = 1;
  static const String markerFormatName = 'omnichat.legacy-retirement';

  final Directory directory;
  final String appVersion;
  final ChatDatabaseFiles files;

  /// Builds the storage-view status. The optional [verifyDatabase] runs the
  /// expensive `integrity_check`/`foreign_key_check`; the settings page uses
  /// the shallow form and `delete` performs the deep check before unlinking.
  Future<LegacyRetirementStatus> inspect({bool verifyDatabase = false}) async {
    final markerRead = await _readMarker();
    if (markerRead.error != null) {
      return LegacyRetirementStatus(
        state: LegacyRetirementState.none,
        artifacts: const <LegacyArtifact>[],
        totalBytes: 0,
        error: markerRead.error,
        blockReason: markerRead.error,
      );
    }

    List<LegacyArtifact> artifacts;
    try {
      artifacts = await _inventory();
    } on LegacyRetirementException catch (e) {
      return LegacyRetirementStatus(
        state: markerRead.state,
        artifacts: const <LegacyArtifact>[],
        totalBytes: 0,
        requestedAtUtc: markerRead.requestedAtUtc,
        completedAtUtc: markerRead.completedAtUtc,
        error: e.message,
        blockReason: e.message,
      );
    }
    final totalBytes = artifacts.fold<int>(0, (sum, a) => sum + a.sizeBytes);

    final probe = await probeDatabase(files.database);
    final meta = probe.meta;
    final source = probe.source;
    final migrationState = probe.state;
    final quarantine = int.tryParse(meta['quarantine_count'] ?? '') ?? 0;
    final dbVerified =
        probe.readable &&
        probe.schemaIsCurrent &&
        probe.migrationComplete &&
        (!verifyDatabase || await verifySqliteFile(files.database) == null);
    final hasValidExport = await _hasValidExport(
      databaseId: probe.databaseId,
      artifacts: artifacts,
    );

    String? blockReason;
    var requiresExport = false;
    var canDelete = false;
    var canDeleteAfterExport = false;
    var canResume = false;
    var canDiscardNeverMigrated = false;

    switch (markerRead.state) {
      case LegacyRetirementState.completed:
        blockReason = 'Legacy cleanup already completed.';
        break;
      case LegacyRetirementState.deleting:
        canResume = dbVerified && artifacts.isNotEmpty;
        blockReason = canResume
            ? 'Legacy cleanup was interrupted; resume it to finish.'
            : 'Legacy cleanup was interrupted and cannot be resumed '
                  '(database not verified or no artifacts remain).';
        break;
      case LegacyRetirementState.none:
        if (artifacts.isEmpty) {
          blockReason = 'No legacy chat files remain.';
        } else if (!dbVerified) {
          blockReason =
              'The SQLite chat database is missing, corrupt, or has no '
              'complete migration receipt. Legacy files may be the only copy.';
        } else if (source == 'hive') {
          requiresExport =
              migrationState == 'complete_with_issues' || quarantine > 0;
          canDelete = !requiresExport;
          canDeleteAfterExport = requiresExport;
          if (requiresExport) {
            blockReason =
                'This migration completed with issues; export the legacy '
                'files before deleting them.';
          }
        } else if (source == 'reset' || source == 'fresh') {
          canDiscardNeverMigrated = true;
          requiresExport = true;
          blockReason =
              'The legacy files were never imported into this database. '
              'Export them before discarding.';
        } else {
          blockReason =
              'The database has no recognized migration source; refusing to '
              'delete legacy files.';
        }
        break;
    }

    return LegacyRetirementStatus(
      state: markerRead.state,
      artifacts: artifacts,
      totalBytes: totalBytes,
      requestedAtUtc: markerRead.requestedAtUtc,
      completedAtUtc: markerRead.completedAtUtc,
      databaseId: probe.databaseId,
      source: source,
      migrationState: migrationState,
      quarantineCount: quarantine,
      blockReason: blockReason,
      requiresExport: requiresExport,
      canDelete: canDelete,
      canDeleteAfterExport: canDeleteAfterExport,
      canResume: canResume,
      canDiscardNeverMigrated: canDiscardNeverMigrated,
      hasValidExport: hasValidExport,
    );
  }

  /// Streams every legacy artifact into [target] and writes a manifest with
  /// names, sizes, mtimes, and SHA-256. The copies are re-read and verified
  /// before the method returns.
  Future<File> exportToDirectory(Directory target) async {
    // §8.8 precondition 2: no export may race a migration, publish, or
    // retirement. The lock is shared with those workflows.
    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'legacy-export',
    );
    try {
      return await _exportToDirectoryLocked(target);
    } finally {
      await lock.release();
    }
  }

  Future<File> _exportToDirectoryLocked(Directory target) async {
    final artifacts = await _inventory();
    if (artifacts.isEmpty) {
      throw const LegacyRetirementException('No legacy chat files to export.');
    }
    if (!await target.exists()) {
      await target.create(recursive: true);
    }

    final probe = await probeDatabase(files.database);
    final manifestArtifacts = <Map<String, dynamic>>[];
    for (final artifact in artifacts) {
      final source = File(p.join(directory.path, artifact.name));
      final destination = File(p.join(target.path, artifact.name));
      final sourceDigest = await sha256.bind(source.openRead()).first;
      await source.copy(destination.path);
      final stat = await destination.stat();
      final digest = await sha256.bind(destination.openRead()).first;
      if (stat.size != artifact.sizeBytes || digest != sourceDigest) {
        throw LegacyRetirementException(
          'Exported ${artifact.name} failed source/destination verification.',
        );
      }
      manifestArtifacts.add({
        'name': artifact.name,
        'sizeBytes': stat.size,
        // Record the source mtime, not the copy's: some platforms do not
        // preserve timestamps on copy, and the export receipt is compared
        // against the current source inventory.
        'modifiedAtMs': artifact.modifiedAtMs,
        'sha256': digest.toString(),
      });
    }

    final manifest = File(p.join(target.path, 'manifest.json'));
    final manifestJson = const JsonEncoder.withIndent('  ').convert({
      'format': markerFormatName,
      'version': markerFormat,
      'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
      'databaseId': probe.databaseId,
      'source': probe.source,
      'migrationState': probe.state,
      'quarantineCount': probe.meta['quarantine_count'],
      'artifacts': manifestArtifacts,
    });
    await manifest.writeAsString(manifestJson, flush: true);

    await fsyncDirectory(target);

    // Durable proof that a verified export exists for the current database.
    // `delete` requires it when the migration completed with issues and when
    // the legacy files were never imported at all.
    await files.writeJsonAtomically(files.legacyExportReceipt, {
      'format': 'omnichat.legacy-export',
      'version': 1,
      'databaseId': probe.databaseId,
      'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'targetPath': target.path,
      'artifacts': manifestArtifacts,
    });
    return manifest;
  }

  /// Deletes the inventory after revalidating every artifact. A new deletion
  /// writes the `deleting` marker before the first unlink; [resume] reuses an
  /// existing marker.
  Future<LegacyRetirementStatus> delete({
    required bool confirmed,
    bool discardNeverMigrated = false,
    bool resume = false,
    List<LegacyArtifact>? expectedArtifacts,
  }) async {
    if (!confirmed) {
      throw const LegacyRetirementException(
        'Legacy deletion requires explicit confirmation.',
      );
    }
    final current = await inspect(verifyDatabase: true);
    if (current.error != null) {
      throw LegacyRetirementException(current.error!);
    }
    if (resume) {
      if (!current.canResume) {
        throw LegacyRetirementException(
          current.blockReason ?? 'Legacy cleanup cannot be resumed.',
        );
      }
    } else {
      if (current.state != LegacyRetirementState.none) {
        throw LegacyRetirementException(
          current.blockReason ?? 'Legacy cleanup is not available.',
        );
      }
      if (!current.canDelete &&
          !current.canDeleteAfterExport &&
          !current.canDiscardNeverMigrated) {
        throw LegacyRetirementException(
          current.blockReason ?? 'Legacy cleanup is not available.',
        );
      }
      if (current.requiresExport && !current.hasValidExport) {
        throw const LegacyRetirementException(
          'Export the legacy chat files before deleting them.',
        );
      }
      if (current.canDiscardNeverMigrated && !discardNeverMigrated) {
        throw const LegacyRetirementException(
          'The legacy files were never imported; use the explicit discard '
          'action after exporting them.',
        );
      }
    }

    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'legacy-retirement',
    );
    try {
      final existingMarker = await _readMarker();
      final List<LegacyArtifact> artifacts;
      final String databaseId;
      final DateTime requestedAt;
      if (resume) {
        final markerArtifacts = existingMarker.artifacts;
        if (markerArtifacts.isEmpty) {
          throw const LegacyRetirementException(
            'The retirement marker has no artifacts to resume.',
          );
        }
        artifacts = markerArtifacts;
        final markerDatabaseId = existingMarker.databaseId;
        if (markerDatabaseId != null &&
            markerDatabaseId.isNotEmpty &&
            markerDatabaseId != current.databaseId) {
          throw const LegacyRetirementException(
            'The retirement marker belongs to a different database; refusing '
            'to resume.',
          );
        }
        databaseId = markerDatabaseId ?? current.databaseId ?? '';
        requestedAt = existingMarker.requestedAtUtc ?? DateTime.now().toUtc();
      } else {
        final inventory = await _inventory();
        if (inventory.isEmpty) {
          throw const LegacyRetirementException(
            'No legacy chat files to delete.',
          );
        }
        // The user confirmed a specific inventory. If a file appeared or
        // changed between `inspect` and the lock, abort instead of deleting
        // data the confirmation did not cover.
        final expected = expectedArtifacts ?? current.artifacts;
        if (!_sameInventory(inventory, expected)) {
          throw const LegacyRetirementException(
            'The legacy artifacts changed after the storage view was loaded; '
            'refresh and try again.',
          );
        }
        // Record hashes before the marker so a file changed between inventory
        // and deletion fails closed. Hashing is explicit and one-time.
        final hashed = <LegacyArtifact>[];
        for (final artifact in inventory) {
          final file = File(p.join(directory.path, artifact.name));
          final digest = await sha256.bind(file.openRead()).first;
          hashed.add(
            LegacyArtifact(
              name: artifact.name,
              sizeBytes: artifact.sizeBytes,
              modifiedAtMs: artifact.modifiedAtMs,
              sha256: digest.toString(),
            ),
          );
        }
        if (current.hasValidExport) {
          await _verifyExportedHashes(hashed);
        }
        artifacts = hashed;
        databaseId = current.databaseId ?? '';
        requestedAt = DateTime.now().toUtc();
        await files.writeJsonAtomically(files.legacyRetirement, {
          'format': markerFormatName,
          'version': markerFormat,
          'state': 'deleting',
          'requestedAtUtc': requestedAt.toIso8601String(),
          'databaseId': databaseId,
          'migrationState': current.migrationState,
          'appVersion': appVersion,
          'artifacts': artifacts.map((a) => a.toJson()).toList(),
        });
        await _fsyncMarker();
      }

      for (final artifact in artifacts) {
        final file = File(p.join(directory.path, artifact.name));
        // Never allow a marker to point outside the app-data directory.
        final normalized = p.normalize(file.absolute.path);
        final root = p.normalize(directory.absolute.path);
        if (!p.isWithin(root, normalized)) {
          throw LegacyRetirementException(
            'Retirement marker references a path outside the app data '
            'directory: ${artifact.name}',
          );
        }
        if (!await file.exists()) continue;
        final link = await FileSystemEntity.isLink(file.path);
        final stat = await file.stat();
        if (link || stat.type != FileSystemEntityType.file) {
          throw LegacyRetirementException(
            'Refusing to delete non-regular file ${artifact.name}.',
          );
        }
        if (stat.size != artifact.sizeBytes ||
            stat.modified.millisecondsSinceEpoch != artifact.modifiedAtMs) {
          throw LegacyRetirementException(
            '${artifact.name} changed after the retirement inventory; '
            'nothing further was deleted.',
          );
        }
        final recordedHash = artifact.sha256;
        if (recordedHash != null && recordedHash.isNotEmpty) {
          final digest = await sha256.bind(file.openRead()).first;
          if (digest.toString() != recordedHash) {
            throw LegacyRetirementException(
              '${artifact.name} failed SHA-256 verification; '
              'nothing further was deleted.',
            );
          }
        }
        await file.delete();
        await fsyncDirectory(directory);
      }

      await files.writeJsonAtomically(files.legacyRetirement, {
        'format': markerFormatName,
        'version': markerFormat,
        'state': 'completed',
        'requestedAtUtc': requestedAt.toIso8601String(),
        'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'databaseId': databaseId,
        'migrationState': current.migrationState,
        'appVersion': appVersion,
        'artifacts': artifacts.map((a) => a.toJson()).toList(),
      });
      await _fsyncMarker();
      return inspect();
    } finally {
      await lock.release();
    }
  }

  Future<LegacyRetirementStatus> resume() =>
      delete(confirmed: true, resume: true);

  /// Removes a `completed` marker after new legacy artifacts have appeared
  /// (for example, a later launch fell back to Hive). The marker is an audit
  /// record, not data; deleting it only re-enables the normal export/delete
  /// flow. Refuses unless the marker is completed and files are present.
  Future<void> resetCompletedMarker() async {
    final current = await inspect();
    if (current.state != LegacyRetirementState.completed) {
      throw const LegacyRetirementException(
        'The retirement marker is not in a completed state.',
      );
    }
    if (!current.hasLegacyFiles) {
      throw const LegacyRetirementException(
        'There are no legacy files to clean up.',
      );
    }

    final lock = await ChatMaintenanceLock.acquire(
      directory,
      purpose: 'legacy-retirement',
    );
    try {
      final marker = await _readMarker();
      if (marker.error != null) {
        throw LegacyRetirementException(marker.error!);
      }
      if (marker.state != LegacyRetirementState.completed) {
        throw const LegacyRetirementException(
          'The retirement marker changed; refresh and try again.',
        );
      }
      await files.legacyRetirement.delete();
      await fsyncDirectory(directory);
    } finally {
      await lock.release();
    }
  }

  bool _sameInventory(List<LegacyArtifact> left, List<LegacyArtifact> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      final a = left[i];
      final b = right[i];
      if (a.name != b.name ||
          a.sizeBytes != b.sizeBytes ||
          a.modifiedAtMs != b.modifiedAtMs) {
        return false;
      }
    }
    return true;
  }

  /// Compares the delete-time SHA-256 with the export receipt. This closes
  /// the size+mtime-preserved content-change window without hashing every
  /// source file on page load.
  Future<void> _verifyExportedHashes(List<LegacyArtifact> artifacts) async {
    final receipt = await files.readJson(files.legacyExportReceipt);
    if (receipt == null) return;
    final entries = receipt['artifacts'];
    if (entries is! List) return;
    final byName = <String, Map<Object?, Object?>>{};
    for (final entry in entries) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString();
      if (name == null || name.isEmpty) continue;
      byName[name] = entry;
    }
    for (final artifact in artifacts) {
      final expected = byName[artifact.name]?['sha256']?.toString();
      if (expected == null || expected.isEmpty) continue;
      if (artifact.sha256 != expected) {
        throw LegacyRetirementException(
          '${artifact.name} no longer matches the verified export; '
          're-export before deleting.',
        );
      }
    }
  }

  Future<bool> _hasValidExport({
    required String? databaseId,
    required List<LegacyArtifact> artifacts,
  }) async {
    if (artifacts.isEmpty) return false;
    final receipt = await files.readJson(files.legacyExportReceipt);
    if (receipt == null) return false;
    if (receipt['format']?.toString() != 'omnichat.legacy-export' ||
        receipt['version']?.toString() != '1') {
      return false;
    }
    if (databaseId == null || receipt['databaseId']?.toString() != databaseId) {
      return false;
    }
    final entries = receipt['artifacts'];
    if (entries is! List) return false;
    final byName = <String, Map<Object?, Object?>>{};
    for (final entry in entries) {
      if (entry is! Map) return false;
      final name = entry['name']?.toString();
      if (name == null || name.isEmpty) return false;
      byName[name] = entry;
    }
    for (final artifact in artifacts) {
      final entry = byName[artifact.name];
      if (entry == null) return false;
      if (entry['sizeBytes'] != artifact.sizeBytes ||
          entry['modifiedAtMs'] != artifact.modifiedAtMs ||
          (entry['sha256']?.toString().isEmpty ?? true)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _fsyncMarker() async {
    // File writes are flushed by writeJsonAtomically; on POSIX also flush the
    // directory entry. Windows cannot fsync a directory from Dart.
    await fsyncDirectory(directory);
  }

  Future<List<LegacyArtifact>> _inventory() async {
    final expected = chatHiveFiles(
      directory,
    ).map((file) => p.basename(file.path)).toSet();
    final artifacts = <LegacyArtifact>[];
    for (final name in expected) {
      final file = File(p.join(directory.path, name));
      if (!await file.exists()) continue;
      final link = await FileSystemEntity.isLink(file.path);
      final stat = await file.stat();
      if (link || stat.type != FileSystemEntityType.file) {
        throw LegacyRetirementException(
          'Legacy artifact $name is not a regular file.',
        );
      }
      artifacts.add(
        LegacyArtifact(
          name: name,
          sizeBytes: stat.size,
          modifiedAtMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    artifacts.sort((a, b) => a.name.compareTo(b.name));
    return artifacts;
  }

  Future<_MarkerRead> _readMarker() async {
    final file = files.legacyRetirement;
    if (!await file.exists()) {
      return const _MarkerRead(state: LegacyRetirementState.none);
    }
    final raw = await files.readJson(file);
    if (raw == null) {
      return const _MarkerRead(
        state: LegacyRetirementState.none,
        error:
            'The legacy retirement marker is malformed; nothing was deleted.',
      );
    }
    final state = raw['state']?.toString();
    final artifactsRaw = raw['artifacts'];
    final artifacts = <LegacyArtifact>[];
    if (artifactsRaw is List) {
      for (final entry in artifactsRaw) {
        final artifact = LegacyArtifact.fromJson(entry);
        if (artifact == null) {
          return const _MarkerRead(
            state: LegacyRetirementState.none,
            error:
                'The legacy retirement marker contains an invalid artifact; '
                'nothing was deleted.',
          );
        }
        artifacts.add(artifact);
      }
    } else if (state == 'deleting' || state == 'completed') {
      return const _MarkerRead(
        state: LegacyRetirementState.none,
        error:
            'The legacy retirement marker has no artifact list; '
            'nothing was deleted.',
      );
    }
    if (state != null && state != 'completed' && state != 'deleting') {
      return const _MarkerRead(
        state: LegacyRetirementState.none,
        error:
            'The legacy retirement marker has an unknown state; '
            'nothing was deleted.',
      );
    }
    return _MarkerRead(
      state: state == 'completed'
          ? LegacyRetirementState.completed
          : state == 'deleting'
          ? LegacyRetirementState.deleting
          : LegacyRetirementState.none,
      requestedAtUtc: _parseUtc(raw['requestedAtUtc']),
      completedAtUtc: _parseUtc(raw['completedAtUtc']),
      databaseId: raw['databaseId']?.toString(),
      artifacts: artifacts,
    );
  }

  DateTime? _parseUtc(Object? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString())?.toUtc();
  }
}

class _MarkerRead {
  const _MarkerRead({
    required this.state,
    this.requestedAtUtc,
    this.completedAtUtc,
    this.databaseId,
    this.artifacts = const <LegacyArtifact>[],
    this.error,
  });

  final LegacyRetirementState state;
  final DateTime? requestedAtUtc;
  final DateTime? completedAtUtc;
  final String? databaseId;
  final List<LegacyArtifact> artifacts;
  final String? error;
}
