// P1-6: read-only session-outputs zone.
//
// Long shell output is externalized outside the workspace, under
// `{appSupport}/tool_outputs/{conversationId}/{toolCallId}.txt`. The model
// reads it back through `file_read` with the returned `output_file` path
// (`tool_outputs/...`), which this store resolves. Writes into the zone are
// rejected by FileToolService — the workspace zero-residue rule stays intact.
//
// Retention: 20 files per conversation / 7 days, swept opportunistically on
// write and synchronously on conversation delete.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';

/// A resolved model path inside the read-only session-outputs zone.
class SessionOutputPath {
  const SessionOutputPath({
    required this.absolutePath,
    required this.rootPath,
    required this.modelPath,
  });

  final String absolutePath;
  final String rootPath;
  final String modelPath;
}

class SessionOutputs {
  SessionOutputs._();

  static const String modelPrefix = 'tool_outputs/';

  /// stdout + stderr above this size is externalized (kelivo offloader spec).
  static const int externalizeThresholdBytes = 32 * 1024;

  /// Per-stream preview size embedded in the tool result when externalized.
  static const int previewBytes = 4 * 1024;

  static const int maxFilesPerConversation = 20;
  static const Duration retention = Duration(days: 7);

  /// Test seam: redirect the app-support root to a temp directory.
  @visibleForTesting
  static Directory? debugRootOverride;

  static Future<Directory> _root({required bool create}) async {
    final root =
        debugRootOverride ??
        Directory(
          p.join(
            (await AppDirectories.getAppDataDirectory()).path,
            'tool_outputs',
          ),
        );
    if (create && !await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  static Future<Directory> rootDirectory() => _root(create: true);

  /// Whether [raw] is the model-facing form of a session-output path.
  static bool isSessionPath(String raw) {
    final normalized = raw.trim().replaceAll('\\', '/');
    return normalized == 'tool_outputs' || normalized.startsWith(modelPrefix);
  }

  /// Resolve a model path against an explicitly supplied root.
  ///
  /// Returns null for malformed paths (`..`, NUL, absolute path, traversal or
  /// symlink escape). The caller turns null into a structured error.
  static SessionOutputPath? resolveFromRoot(String raw, String rootPath) {
    final normalized = raw.trim().replaceAll('\\', '/');
    if (!isSessionPath(normalized) || normalized.contains('\u0000')) {
      return null;
    }
    if (normalized == 'tool_outputs') return null;
    final relative = normalized.substring(modelPrefix.length);
    if (relative.isEmpty || relative.startsWith('/')) return null;
    final segments = relative.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      return null;
    }
    final root = _canonical(rootPath);
    final candidate = p.normalize(p.join(root, relative));
    if (!_isWithin(candidate, root)) return null;

    // Follow symlinks only for files that already exist; a symlinked file
    // pointing outside the zone must not be readable.
    final type = FileSystemEntity.typeSync(candidate, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      try {
        final resolved = type == FileSystemEntityType.directory
            ? Directory(candidate).resolveSymbolicLinksSync()
            : File(candidate).resolveSymbolicLinksSync();
        if (!_isWithin(resolved, root)) return null;
        return SessionOutputPath(
          absolutePath: resolved,
          rootPath: root,
          modelPath: '$modelPrefix${segments.join('/')}',
        );
      } catch (_) {
        return null;
      }
    }
    return SessionOutputPath(
      absolutePath: candidate,
      rootPath: root,
      modelPath: '$modelPrefix${segments.join('/')}',
    );
  }

  /// Async variant used by FileToolService. Returns null for non-session
  /// paths and invalid escapes.
  static Future<SessionOutputPath?> resolveReadPath(String raw) async {
    if (!isSessionPath(raw)) return null;
    final root = await rootDirectory();
    return resolveFromRoot(raw, root.path);
  }

  /// Persist [content] and return its model path. Best-effort: returns null
  /// when the write fails (the caller keeps the previews).
  static Future<String?> externalize({
    required String conversationId,
    required String toolCallId,
    required String content,
  }) async {
    try {
      final root = await rootDirectory();
      final conversationDir = Directory(
        p.join(root.path, _safeComponent(conversationId)),
      );
      if (!await conversationDir.exists()) {
        await conversationDir.create(recursive: true);
      }
      final fileName = '${_safeComponent(toolCallId)}.txt';
      final file = File(p.join(conversationDir.path, fileName));
      await file.writeAsString(content, flush: true);
      await sweep(conversationId);
      return '$modelPrefix${_safeComponent(conversationId)}/$fileName';
    } catch (_) {
      return null;
    }
  }

  /// Delete files older than [retention] and keep only the newest
  /// [maxFilesPerConversation] files. Opportunistic — never throws.
  static Future<void> sweep(String conversationId) async {
    try {
      final root = await rootDirectory();
      final directory = Directory(
        p.join(root.path, _safeComponent(conversationId)),
      );
      if (!await directory.exists()) return;
      final files = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) files.add(entity);
      }
      final now = DateTime.now();
      final kept = <File>[];
      for (final file in files) {
        try {
          final stat = await file.stat();
          if (now.difference(stat.modified) > retention) {
            await file.delete();
            continue;
          }
          kept.add(file);
        } catch (_) {}
      }
      kept.sort((a, b) {
        try {
          return b.statSync().modified.compareTo(a.statSync().modified);
        } catch (_) {
          return 0;
        }
      });
      for (var i = maxFilesPerConversation; i < kept.length; i++) {
        try {
          await kept[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Remove the complete session-outputs zone (full reset / backup restore).
  /// Never creates the directory when it does not exist.
  static Future<void> clearAll() async {
    try {
      final root = await _root(create: false);
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {}
  }

  /// Remove every output file for a deleted conversation.
  static Future<void> deleteConversation(String conversationId) async {
    try {
      final root = await rootDirectory();
      final directory = Directory(
        p.join(root.path, _safeComponent(conversationId)),
      );
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// Truncate [text] to at most [maxBytes] UTF-8 bytes without splitting a
  /// code point, appending a short marker when anything was dropped.
  static String preview(String text, {int maxBytes = previewBytes}) {
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) return text;
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return '${utf8.decode(bytes.sublist(0, end), allowMalformed: true)}\n'
        '[… preview truncated; read output_file for the full log …]';
  }

  static String _safeComponent(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').trim();
    return safe.isEmpty ? 'unknown' : safe;
  }

  static String _canonical(String path) {
    final normalized = p.normalize(p.absolute(path));
    try {
      if (Directory(normalized).existsSync()) {
        return Directory(normalized).resolveSymbolicLinksSync();
      }
    } catch (_) {}
    return normalized;
  }

  static bool _isWithin(String candidate, String root) {
    String comparable(String value) {
      final normalized = p.normalize(value).replaceAll('\\', '/');
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final child = comparable(candidate);
    final parent = comparable(root).replaceFirst(RegExp(r'/+$'), '');
    return child == parent || child.startsWith('$parent/');
  }
}
