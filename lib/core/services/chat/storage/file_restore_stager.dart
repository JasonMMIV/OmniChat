import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../logging/flutter_logger.dart';
import 'restore_journal.dart';

/// Moves a directory, retrying transient Windows sharing violations
/// (`Access is denied` / file locked) with bounded backoff.
Future<void> moveDirectoryWithRetry(
  Directory from,
  Directory to, {
  int attempts = 5,
}) async {
  if (!await from.exists()) return;
  await to.parent.create(recursive: true);
  var delayMs = 100;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      if (await to.exists()) {
        throw FileSystemException('Destination already exists', to.path);
      }
      await from.rename(to.path);
      return;
    } on FileSystemException {
      if (attempt == attempts - 1) rethrow;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      delayMs *= 2;
    }
  }
}

Future<void> deleteDirectoryWithRetry(
  Directory directory, {
  int attempts = 5,
}) async {
  if (!await directory.exists()) return;
  var delayMs = 100;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == attempts - 1) rethrow;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      delayMs *= 2;
    }
  }
}

/// Stages backup attachments inside the app data directory (same volume as
/// `upload/`, `images/`, `avatars/`) and swaps them into place only after the
/// archive has been fully extracted and verified.
class FileRestoreStager {
  FileRestoreStager({
    required this.appDataDirectory,
    required this.restoreId,
  });

  /// Test seam: fail after the first extracted file.
  static bool debugFailOnFileCopy = false;

  static const List<String> directoryNames = <String>[
    'upload',
    'images',
    'avatars',
  ];

  final Directory appDataDirectory;
  final String restoreId;

  Directory get stagingRoot =>
      Directory(p.join(appDataDirectory.path, 'restore_staging_$restoreId'));

  Directory get previousRoot =>
      Directory(p.join(appDataDirectory.path, '.previous-restore-$restoreId'));

  /// Extracts `upload/`, `images/` and `avatars/` entries into [stagingRoot].
  /// Directories absent from the archive are not staged and keep their live
  /// contents untouched.
  Future<Map<String, RestoreJournalEntry>> stageArchive(File archive) async {
    final counts = <String, int>{};
    InputFileStream? input;
    try {
      input = InputFileStream(archive.path);
      final decoded = ZipDecoder().decodeStream(input);
      for (final entry in decoded) {
        if (!entry.isFile) continue;
        final normalized = entry.name.replaceAll('\\', '/');
        final parts = normalized
            .split('/')
            .where((segment) => segment.isNotEmpty && segment != '.' && segment != '..')
            .toList();
        if (parts.length < 2) continue;
        final top = parts.first;
        if (!directoryNames.contains(top)) continue;

        final relative = parts.sublist(1);
        final target = File(
          p.joinAll(<String>[stagingRoot.path, top, ...relative]),
        );
        await target.parent.create(recursive: true);
        final bytes = entry.readBytes();
        if (bytes == null) {
          throw FileSystemException(
            'The backup entry could not be read',
            entry.name,
          );
        }
        await target.writeAsBytes(bytes, flush: true);
        if (await target.length() != entry.size) {
          throw FileSystemException(
            'Extracted file size does not match the archive entry',
            target.path,
          );
        }
        counts[top] = (counts[top] ?? 0) + 1;
        if (debugFailOnFileCopy) {
          debugFailOnFileCopy = false;
          throw FileSystemException(
            'Injected file copy failure (debug)',
            target.path,
          );
        }
      }
    } catch (_) {
      await cleanup();
      rethrow;
    } finally {
      try {
        await input?.close();
      } catch (_) {}
    }

    final entries = <String, RestoreJournalEntry>{};
    for (final name in directoryNames) {
      if ((counts[name] ?? 0) == 0) continue;
      final staging = Directory(p.join(stagingRoot.path, name));
      if (!await staging.exists()) continue;
      entries[name] = RestoreJournalEntry(
        livePath: p.join(appDataDirectory.path, name),
        stagingPath: staging.path,
        previousPath: p.join(previousRoot.path, name),
        staged: true,
      );
    }
    FlutterLogger.log(
      'Staged backup files: '
      '${entries.entries.map((entry) => '${entry.key}=${counts[entry.key]}').join(', ')}',
      tag: 'backup-restore',
    );
    return entries;
  }

  /// Moves each live directory aside and renames the staged directory into
  /// place. Each completed directory is journaled before the next one starts.
  Future<void> swap(RestoreJournal journal) async {
    for (final entry in journal.fileEntries.entries) {
      final name = entry.key;
      final paths = entry.value;
      if (!paths.staged || paths.rolledBack) continue;

      final live = Directory(paths.livePath);
      final staging = Directory(paths.stagingPath);
      final previous = Directory(paths.previousPath);

      // A previous crashed attempt may have moved the live directory aside
      // already. Put it back before redoing the swap.
      if (await previous.exists()) {
        if (await live.exists()) {
          throw FileSystemException(
            'Both the live and preserved directories exist',
            previous.path,
          );
        }
        await moveDirectoryWithRetry(previous, live);
      }
      if (!await staging.exists()) continue;
      if (await live.exists()) {
        await moveDirectoryWithRetry(live, previous);
      }
      await moveDirectoryWithRetry(staging, live);
      await journal.markFileSwapped(name);
    }
  }

  /// Restores every swapped directory from its `.previous-restore-*` copy.
  /// Idempotent: a directory already rolled back is skipped.
  Future<void> rollback(RestoreJournal journal) async {
    final entries = journal.fileEntries.entries.toList().reversed;
    for (final entry in entries) {
      final name = entry.key;
      final paths = entry.value;
      if (paths.rolledBack) continue;

      final live = Directory(paths.livePath);
      final previous = Directory(paths.previousPath);
      if (await previous.exists()) {
        if (await live.exists()) {
          await deleteDirectoryWithRetry(live);
        }
        await moveDirectoryWithRetry(previous, live);
      } else if (paths.swapped && await live.exists()) {
        // Nothing existed before the restore (fresh install); restore absence.
        await deleteDirectoryWithRetry(live);
      }
      await journal.markFileRolledBack(name);
    }
    await _deleteQuietly(stagingRoot);
  }

  /// Removes staging and preserved copies after a committed restore.
  Future<void> cleanup() async {
    await _deleteQuietly(stagingRoot);
    await _deleteQuietly(previousRoot);
  }

  Future<void> _deleteQuietly(Directory directory) async {
    try {
      await deleteDirectoryWithRetry(directory);
    } catch (error) {
      FlutterLogger.log(
        'Could not remove ${directory.path}: $error',
        tag: 'backup-restore',
      );
    }
  }
}
