import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../utils/markdown_media_sanitizer.dart';

/// Result of the backup attachment manifest preflight (plan §3 Phase 2):
/// [missingFiles] fail the whole backup, [notBackedUpPaths] are
/// workspace/external references that are not backed up by design.
class BackupPreflightResult {
  const BackupPreflightResult({
    required this.missingFiles,
    required this.notBackedUpPaths,
  });

  final List<String> missingFiles;
  final List<String> notBackedUpPaths;

  bool get ok => missingFiles.isEmpty;
}

/// Thrown before anything is added to a backup zip when the chat data
/// references app data attachment files that do not exist. The missing list
/// is structured so the UI can present it directly; the backup is never
/// silently produced with missing attachments.
class BackupPreflightException implements Exception {
  const BackupPreflightException(this.missingFiles, this.notBackedUpPaths);

  final List<String> missingFiles;
  final List<String> notBackedUpPaths;

  @override
  String toString() {
    final sb = StringBuffer(
      'Backup aborted: ${missingFiles.length} referenced attachment '
      'file(s) are missing:',
    );
    for (final path in missingFiles) {
      sb.write('\n- $path');
    }
    if (notBackedUpPaths.isNotEmpty) {
      sb.write(
        '\n${notBackedUpPaths.length} other referenced path(s) live outside '
        'the backup scope (upload/, images/, avatars/) and are not backed up '
        'by design.',
      );
    }
    return sb.toString();
  }
}

/// Pure classifier for the backup attachment preflight (plan §3 Phase 2).
/// Only references that resolve inside the app data attachment roots
/// (`upload/`, `images/`, `avatars/`) are enforced; workspace and other
/// external absolute paths are informational (`FileRecord.path` is absolute,
/// so workspace paths were never part of Backup v3).
class BackupFilePreflight {
  BackupFilePreflight._();

  static final RegExp _imageMarkerRe = RegExp(r'\[image:(.+?)\]');
  static final RegExp _fileMarkerRe = RegExp(r'\[file:([^|\]]+)\|');
  static final RegExp _markdownImageRe = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');

  /// Collects local file references embedded in a chat message content:
  /// `[image:path]`, `[file:path|name|mime]`, and markdown image targets.
  /// Remote (http/https), data URLs, and UNC targets are ignored.
  static void collectFromContent(String content, Set<String> out) {
    void add(String? raw) {
      final value = raw?.trim() ?? '';
      if (value.isEmpty) return;
      if (MarkdownMediaSanitizer.isLikelyLocalImagePath(value)) {
        out.add(value);
      }
    }

    for (final match in _imageMarkerRe.allMatches(content)) {
      add(match.group(1));
    }
    for (final match in _fileMarkerRe.allMatches(content)) {
      add(match.group(1));
    }
    for (final match in _markdownImageRe.allMatches(content)) {
      add(match.group(1));
    }
  }

  /// Classifies chat attachment [references] against the [manifest] of files
  /// that will be added to the backup zip and the app data attachment [roots]
  /// (`upload/`, `images/`, `avatars/`).
  static BackupPreflightResult classify({
    required Iterable<String> references,
    required Iterable<String> manifest,
    required Iterable<String> roots,
  }) {
    String canon(String path) {
      final normalized = p.normalize(path);
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final manifestSet = <String>{for (final path in manifest) canon(path)};
    final rootPaths = <String>[for (final root in roots) canon(root)];

    final missing = <String>{};
    final external = <String>{};
    for (final reference in references) {
      final value = reference.trim();
      if (value.isEmpty) continue;
      if (!MarkdownMediaSanitizer.isLikelyLocalImagePath(value)) continue;
      final canonical = canon(value);
      final enforced = rootPaths.any((root) => p.isWithin(root, canonical));
      if (!enforced) {
        external.add(value);
        continue;
      }
      if (!manifestSet.contains(canonical)) {
        missing.add(value);
      }
    }
    return BackupPreflightResult(
      missingFiles: missing.toList()..sort(),
      notBackedUpPaths: external.toList()..sort(),
    );
  }
}
