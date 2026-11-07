// P1-6: approximate changed-files audit for one shell command.
//
// A command can touch files the model never sees in the transcript. Before /
// after `(mtime, size)` snapshots of the workspace report which paths changed.
// This is explicitly an APPROXIMATION (plan §2.2 incremental 2):
// - a rewrite that preserves both mtime tick and size is missed;
// - tools that preserve mtime (`touch -r`) are missed;
// - the snapshot is capped (20k entries) and memory-only, so the workspace
//   keeps zero residue.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class WorkspaceFileStamp {
  const WorkspaceFileStamp({required this.modifiedMs, required this.size});

  final int modifiedMs;
  final int size;

  bool differsFrom(WorkspaceFileStamp other) =>
      modifiedMs != other.modifiedMs || size != other.size;
}

class WorkspaceSnapshot {
  const WorkspaceSnapshot({required this.files, this.truncated = false});

  final Map<String, WorkspaceFileStamp> files;
  final bool truncated;

  /// Directories that never belong in a workspace change audit (noise +
  /// very large generated trees).
  static const Set<String> skippedDirectoryNames = <String>{
    '.git',
    '.dart_tool',
    '.idea',
    '.vscode',
    '.gradle',
    '.next',
    '.cache',
    'node_modules',
    'build',
    'dist',
    'target',
    'coverage',
    '__pycache__',
    'pods',
  };

  static Future<WorkspaceSnapshot> capture(
    String rootPath, {
    int maxEntries = 20000,
  }) async {
    final files = <String, WorkspaceFileStamp>{};
    var visited = 0;
    var truncated = false;
    final root = Directory(rootPath);

    Future<void> walk(Directory directory) async {
      if (truncated) return;
      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      for (final entity in entries) {
        if (truncated) return;
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (skippedDirectoryNames.contains(name.toLowerCase())) continue;
          await walk(entity);
          continue;
        }
        if (entity is! File) continue; // Skip links: never follow them.
        if (visited >= maxEntries) {
          truncated = true;
          return;
        }
        try {
          final stat = await entity.stat();
          files[p
              .relative(entity.path, from: rootPath)
              .replaceAll('\\', '/')] = WorkspaceFileStamp(
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
          visited++;
        } catch (_) {}
      }
    }

    await walk(root);
    return WorkspaceSnapshot(files: files, truncated: truncated);
  }
}

class ChangedFilesResult {
  const ChangedFilesResult({
    required this.paths,
    required this.deleted,
    required this.truncated,
    required this.total,
  });

  const ChangedFilesResult.empty()
    : paths = const <String>[],
      deleted = const <String>[],
      truncated = false,
      total = 0;

  final List<String> paths;
  final List<String> deleted;
  final bool truncated;

  /// Full changed count before the 50-path display cap.
  final int total;
}

/// Added/modified paths plus deletions, capped for the tool payload.
ChangedFilesResult diffWorkspaceSnapshots(
  WorkspaceSnapshot before,
  WorkspaceSnapshot after, {
  int cap = 50,
}) {
  final changed = <String>[];
  for (final entry in after.files.entries) {
    final previous = before.files[entry.key];
    if (previous == null || previous.differsFrom(entry.value)) {
      changed.add(entry.key);
    }
  }
  // A truncated after-snapshot has not seen every current file, so an absent
  // key cannot be interpreted as a deletion. Report the truncation instead.
  final deleted = after.truncated
      ? <String>[]
      : <String>[
          for (final key in before.files.keys)
            if (!after.files.containsKey(key)) key,
        ];
  changed.sort();
  deleted.sort();
  final total = changed.length + deleted.length;
  final displayedPaths = changed.take(cap).toList();
  final remaining = cap - displayedPaths.length;
  final displayedDeleted = remaining > 0
      ? deleted.take(remaining).toList()
      : <String>[];
  return ChangedFilesResult(
    paths: displayedPaths,
    deleted: displayedDeleted,
    truncated:
        before.truncated ||
        after.truncated ||
        total > displayedPaths.length + displayedDeleted.length,
    total: total,
  );
}
