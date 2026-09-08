// Workspace snapshot + one-click rollback (IMPORT_PLAN_COWORK.md P1-5).
//
// When an agent run starts with an enabled workspace, the whole workspace is
// zipped (streaming, `archive` package — the same dependency the backup
// pipeline uses) to `{workspace}/.omnichat/snapshots/{runId}.zip`. At most
// [retentionMaxSnapshots] snapshots are kept and the total snapshot size is
// bounded by [retentionMaxTotalBytes] — a huge workspace must never blow up
// app storage. Rollback = restore the snapshot over the workspace.
//
// Exclusions: the `.omnichat/` directory itself (snapshots, externalized
// tool outputs) is never captured, so snapshot → restore cycles are stable
// and app-managed files never leak into user data.
//
// The FileRecord boundary (CLI v4 §九.2) still holds: files created by
// shell tools do not get FileRecords, so a "N files changed" list is
// incomplete for shell mutations — the zip snapshot is the only complete
// rollback guarantee. Callers must word their UI accordingly.
//
// Pure Dart (no Flutter imports) so it can be unit-tested without bindings.
// Every public entry point is non-throwing: a snapshot/restore failure must
// never break the conversation flow it wraps.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// P1-5: log-only tool event name for the run-start snapshot card. The event
/// is a UI affordance only — excluded from §3.11 replay (the snapshot zip
/// never reaches the model).
const String workspaceSnapshotToolName = 'workspace_snapshot';

class WorkspaceSnapshotResult {
  const WorkspaceSnapshotResult({
    required this.ok,
    this.zipPath,
    this.fileCount = 0,
    this.totalBytes = 0,
    this.error,
  });

  final bool ok;
  final String? zipPath;
  final int fileCount;
  final int totalBytes;
  final String? error;

  static const WorkspaceSnapshotResult skipped = WorkspaceSnapshotResult(
    ok: false,
    error: 'skipped',
  );

  factory WorkspaceSnapshotResult.failure(String message) =>
      WorkspaceSnapshotResult(ok: false, error: message);
}

class WorkspaceSnapshotService {
  WorkspaceSnapshotService._();

  /// Relative directory (under the workspace root) holding run snapshots.
  /// Kept dot-prefixed so it stays out of typical user flows and matches
  /// the P1-4 externalizer layout (`{workspace}/.omnichat/...`).
  static const String snapshotsDirRelative = '.omnichat/snapshots';

  /// Retention: at most this many snapshots per workspace (newest kept).
  static const int retentionMaxSnapshots = 5;

  /// Retention: hard total-size guard across all snapshots. When exceeded,
  /// oldest snapshots are evicted until the directory fits again (or only
  /// the newest snapshot remains).
  static const int retentionMaxTotalBytes = 512 * 1024 * 1024;

  /// Per-run snapshot budget: a single snapshot larger than this is deleted
  /// immediately (a huge workspace would otherwise monopolize the guard).
  static const int maxSnapshotBytes = 256 * 1024 * 1024;

  /// Zip level (archive package: 0 = store, 6 = default deflate).
  static const int zipLevel = 6;

  /// Create a zip snapshot of [workspaceRoot] for the agent run [runId].
  ///
  /// Returns [WorkspaceSnapshotResult.skipped] when the workspace root is
  /// empty/missing — nothing to roll back to. Never throws.
  static Future<WorkspaceSnapshotResult> create({
    required String workspaceRoot,
    required String runId,
  }) async {
    final root = workspaceRoot.trim();
    if (root.isEmpty) return WorkspaceSnapshotResult.skipped;
    try {
      final dir = Directory(root);
      if (!await dir.exists()) return WorkspaceSnapshotResult.skipped;

      final snapshotDir = Directory(p.join(root, snapshotsDirRelative));
      await snapshotDir.create(recursive: true);

      final zipPath = await _buildZip(
        workspaceRoot: root,
        snapshotDir: snapshotDir,
        runId: runId,
      );
      if (zipPath == null) return WorkspaceSnapshotResult.skipped;

      // Per-run guard: drop oversized snapshots immediately.
      final stat = await File(zipPath).stat();
      if (stat.size > maxSnapshotBytes) {
        try {
          await File(zipPath).delete();
        } catch (_) {}
        return WorkspaceSnapshotResult.failure('snapshot_too_large');
      }

      // Retention sweep (count + total size), best-effort.
      try {
        await sweepSnapshots(root);
      } catch (_) {}

      final count = await _countWorkspaceFiles(root);
      return WorkspaceSnapshotResult(
        ok: true,
        zipPath: zipPath,
        fileCount: count,
        totalBytes: stat.size,
      );
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[workspace-snapshot] create failed: $e');
        return true;
      }());
      return WorkspaceSnapshotResult.failure(e.toString());
    }
  }

  /// Restore [zipPath] over the workspace: wipe the current contents
  /// (except `.omnichat/`) and extract the snapshot. Never throws.
  static Future<WorkspaceSnapshotResult> restore({
    required String workspaceRoot,
    required String zipPath,
  }) async {
    final root = workspaceRoot.trim();
    if (root.isEmpty) {
      return WorkspaceSnapshotResult.failure('no_workspace');
    }
    try {
      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        return WorkspaceSnapshotResult.failure('snapshot_missing');
      }

      // 1. Wipe the workspace except the app-managed `.omnichat/` directory.
      final entities = await Directory(root).list(followLinks: false).toList();
      for (final e in entities) {
        final base = p.basename(e.path);
        if (base == '.omnichat') continue;
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }

      // 2. Extract the snapshot with path-traversal validation (mirrors the
      // file_extract_zip tool guards).
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      var restored = 0;
      for (final entry in archive.files) {
        if (entry.isDirectory) continue;
        final name = entry.name;
        if (name.contains('..') ||
            name.startsWith('/') ||
            name.startsWith('\\') ||
            p.isAbsolute(name) ||
            p.normalize(name).startsWith('..')) {
          // `..` and absolute entries are the classic zip-slip vectors; the
          // root-relative check also matters on Windows where p.isAbsolute
          //('/x') is false but p.join(root, '/x') still escapes the root.
          continue;
        }
        final target = File(p.join(root, name));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.content as List<int>, flush: true);
        restored++;
      }
      return WorkspaceSnapshotResult(ok: true, fileCount: restored);
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[workspace-snapshot] restore failed: $e');
        return true;
      }());
      return WorkspaceSnapshotResult.failure(e.toString());
    }
  }

  /// Newest snapshot zip for a workspace, or null when none exists.
  static Future<String?> latestSnapshotPath(String workspaceRoot) async {
    final snapshots = await listSnapshots(workspaceRoot);
    return snapshots.isEmpty ? null : snapshots.first;
  }

  /// All snapshot zips for a workspace, newest first (by modification time).
  static Future<List<String>> listSnapshots(String workspaceRoot) async {
    try {
      final dir = Directory(
        p.join(workspaceRoot.trim(), snapshotsDirRelative),
      );
      if (!await dir.exists()) return const <String>[];
      final entries = await dir.list(followLinks: false).toList();
      final files = <File>[];
      for (final e in entries) {
        if (e is File && e.path.endsWith('.zip')) files.add(e);
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      // Sort by mtime for real ordering (names are run ids, not ordered).
      final stats = <(File, DateTime)>[];
      for (final f in files) {
        try {
          stats.add((f, (await f.stat()).modified));
        } catch (_) {}
      }
      stats.sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final s in stats) s.$1.path];
    } catch (_) {
      return const <String>[];
    }
  }

  /// Retention sweep: keep at most [maxSnapshots] snapshots within
  /// [maxTotalBytes] across the snapshot directory. Newest kept first — the
  /// newest snapshot is always retained so a rollback target always exists
  /// (the per-run [maxSnapshotBytes] guard bounds individual snapshots).
  static Future<void> sweepSnapshots(
    String workspaceRoot, {
    int maxSnapshots = retentionMaxSnapshots,
    int maxTotalBytes = retentionMaxTotalBytes,
  }) async {
    final paths = await listSnapshots(workspaceRoot); // newest first
    var totalSize = 0;
    var kept = 0;
    for (final path in paths) {
      int size = 0;
      try {
        size = (await File(path).stat()).size;
      } catch (_) {}
      // The newest is unconditionally kept; older ones are kept while the
      // running total fits both caps, evicted otherwise (sweep continues so
      // a smaller older snapshot can still fit).
      if (kept < maxSnapshots &&
          (kept == 0 || totalSize + size <= maxTotalBytes)) {
        kept++;
        totalSize += size;
        continue;
      }
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Delete every snapshot for a workspace (conversation cleanup).
  static Future<void> clearSnapshots(String workspaceRoot) async {
    try {
      final dir = Directory(
        p.join(workspaceRoot.trim(), snapshotsDirRelative),
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Stream the workspace into a zip file. Uses [ZipFileEncoder] (file-level
  /// streaming via InputFileStream) — never reads whole files into memory.
  /// The `.omnichat/` directory is excluded.
  static Future<String?> _buildZip({
    required String workspaceRoot,
    required Directory snapshotDir,
    required String runId,
  }) async {
    final safeRunId = _sanitizeRunId(runId);
    final zipPath = p.join(snapshotDir.path, '$safeRunId.zip');
    final encoder = ZipFileEncoder();
    encoder.create(zipPath, level: zipLevel);
    try {
      await _addDirectoryToZip(
        encoder,
        Directory(workspaceRoot),
        workspaceRoot,
      );
    } catch (_) {
      try {
        encoder.closeSync();
      } catch (_) {}
      try {
        await File(zipPath).delete();
      } catch (_) {}
      rethrow;
    }
    await encoder.close();
    return zipPath;
  }

  static Future<void> _addDirectoryToZip(
    ZipFileEncoder encoder,
    Directory dir,
    String workspaceRoot,
  ) async {
    final entities = await dir.list(followLinks: false).toList();
    for (final e in entities) {
      final base = p.basename(e.path);
      if (base == '.omnichat') continue;
      if (e is Directory) {
        await _addDirectoryToZip(encoder, e, workspaceRoot);
      } else if (e is File) {
        final rel = p.relative(e.path, from: workspaceRoot).replaceAll('\\', '/');
        await encoder.addFile(e, rel, zipLevel);
      }
      // Links are skipped (followLinks: false list + no Link branch).
    }
  }

  /// Run ids come from message ids (uuid) — sanitize defensively so a
  /// hostile id can never escape the snapshots directory.
  static String _sanitizeRunId(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final trimmed = cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
    return trimmed.isEmpty
        ? 'run-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        : trimmed;
  }

  static Future<int> _countWorkspaceFiles(String workspaceRoot) async {
    var count = 0;
    try {
      await for (final e
          in Directory(workspaceRoot).list(recursive: true, followLinks: false)) {
        if (e is File) count++;
      }
    } catch (_) {}
    return count;
  }


}
