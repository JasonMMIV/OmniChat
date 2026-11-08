import 'dart:io';

import 'package:path/path.dart' as p;

/// One workspace usage measurement (P3-4).
class WorkspaceDiskUsage {
  const WorkspaceDiskUsage({
    required this.totalBytes,
    required this.fileCount,
    required this.directoryCount,
    required this.scannedEntryCount,
    required this.truncated,
  });

  final int totalBytes;
  final int fileCount;

  /// Subdirectories below the workspace root (the root itself is not counted).
  final int directoryCount;

  /// Files, directories and links visited by the scan. This is the value the
  /// partial-scan message must show; [fileCount] excludes directories.
  final int scannedEntryCount;

  /// True when the scan stopped at the entry cap before visiting everything.
  final bool truncated;
}

/// Measures the bytes stored in a workspace without following links and
/// without counting the app-owned `.omnichat/` directory.
///
/// The scan is bounded so a pathological tree cannot keep the settings page
/// waiting forever; [WorkspaceDiskUsage.truncated] tells the UI that the
/// number is a lower bound.
class WorkspaceDiskUsageService {
  WorkspaceDiskUsageService._();

  static const String excludedDirectoryName = '.omnichat';
  static const int maxScannedEntries = 50000;

  static Future<WorkspaceDiskUsage?> measure(
    String workspacePath, {
    int maxScannedEntries = maxScannedEntries,
  }) async {
    assert(maxScannedEntries > 0);
    final root = Directory(workspacePath);
    if (!await root.exists()) return null;

    final excludedPath = p.normalize(
      p.join(root.path, excludedDirectoryName),
    );
    final pending = <Directory>[root];
    var totalBytes = 0;
    var fileCount = 0;
    var directoryCount = 0;
    var scannedEntries = 0;
    var truncated = false;

    scan:
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (p.equals(p.normalize(entity.path), excludedPath)) continue;
          if (scannedEntries >= maxScannedEntries) {
            truncated = true;
            break scan;
          }
          scannedEntries++;

          if (entity is Directory) {
            directoryCount++;
            pending.add(entity);
          } else if (entity is File) {
            try {
              totalBytes += await entity.length();
              fileCount++;
            } on FileSystemException {
              // A file that disappeared or is unreadable does not invalidate
              // the rest of the measurement.
            }
          }
        }
      } on FileSystemException {
        // An unreadable subdirectory is skipped; the workspace root itself
        // was verified above, so an empty result still means "0 bytes".
      }
    }

    return WorkspaceDiskUsage(
      totalBytes: totalBytes,
      fileCount: fileCount,
      directoryCount: directoryCount,
      scannedEntryCount: scannedEntries,
      truncated: truncated,
    );
  }
}

/// Compact binary-size text for the disk usage card.
String formatWorkspaceBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  while (true) {
    final text = value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    // A value just below 1024 can round to "1024 KB"; promote it instead of
    // showing an impossible unit value.
    if (text == '1024' && unit < units.length - 1) {
      value /= 1024;
      unit++;
      continue;
    }
    final trimmed = text.endsWith('.0')
        ? text.substring(0, text.length - 2)
        : text;
    return '$trimmed ${units[unit]}';
  }
}
