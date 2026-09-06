// Long-output externalization (IMPORT_PLAN_COWORK.md P1-4).
//
// Tool outputs above the API tool-result budget (32,768 chars, see
// `ChatApiService._truncateToolResultText`) are written to
// `{workspace}/.omnichat/tool_outputs/` and the model receives a small
// preview plus explicit retrieval guidance (`file_read` supports offset /
// limit paging; `file_search` for keyword lookup in large logs).
//
// "Single truncation path" principle: externalization is the *primary*
// truncation mechanism; the transport-level 32KB head/tail truncator remains
// only as an extreme-value backstop (e.g. when the workspace is disabled and
// there is nowhere to externalize to, or when the write itself fails).
//
// Pure Dart (no Flutter imports) so it can be unit-tested without bindings.

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

class ToolOutputExternalizer {
  ToolOutputExternalizer._();

  /// Outputs longer than this are externalized. Matches the API tool-result
  /// budget so externalized results never hit the transport truncator.
  static const int externalizeThresholdChars = 32768;

  /// Head preview kept in the returned result.
  static const int previewChars = 4096;

  /// Relative directory (under the workspace root) holding externalized
  /// outputs. Kept dot-prefixed so it stays out of typical user flows.
  static const String toolOutputsDirRelative = '.omnichat/tool_outputs';

  /// Retention: max files kept per workspace (oldest-first eviction).
  static const int retentionMaxFiles = 20;

  /// Retention: files older than this are removed on sweep.
  static const int retentionMaxAgeDays = 7;

  /// If [result] exceeds the threshold, persist it under the workspace and
  /// return a preview + retrieval guidance. Otherwise return it unchanged.
  ///
  /// Never throws: any failure (no workspace, IO error, etc.) returns the
  /// original result untouched — externalization must never break a tool
  /// call whose result we already hold.
  static Future<String> maybeExternalize({
    required String toolName,
    required String result,
    String? workspacePath,
    String? toolCallId,
  }) async {
    if (result.length <= externalizeThresholdChars) return result;

    final root = workspacePath?.trim();
    if (root == null || root.isEmpty) return result;

    try {
      final file = await _writeOutputFile(
        workspaceRoot: root,
        toolName: toolName,
        content: result,
        toolCallId: toolCallId,
      );
      // Best-effort retention sweep; never blocks or fails the call.
      try {
        await sweepToolOutputs(root);
      } catch (_) {}
      return _buildPreviewResult(
        result: result,
        relativePath: '$toolOutputsDirRelative/${p.basename(file.path)}',
      );
    } catch (e) {
      // Swallowed by design (see doc comment): fall back to the original
      // oversized result; the transport-level 32KB truncator is the backstop.
      assert(() {
        // ignore: avoid_print
        print('[tool-externalize] failed to externalize "$toolName": $e');
        return true;
      }());
      return result;
    }
  }

  /// Retention sweep: keep at most [maxFiles] files and drop anything older
  /// than [maxAgeDays]. Errors on individual files are ignored.
  static Future<void> sweepToolOutputs(
    String workspaceRoot, {
    int maxFiles = retentionMaxFiles,
    int maxAgeDays = retentionMaxAgeDays,
  }) async {
    final dir = Directory(
      p.join(workspaceRoot, toolOutputsDirRelative),
    );
    if (!await dir.exists()) return;
    final entities = await dir.list(followLinks: false).toList();
    final files = <File>[];
    for (final e in entities) {
      if (e is File) files.add(e);
    }
    final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays));
    final survivors = <File>[];
    for (final f in files) {
      try {
        final stat = await f.stat();
        if (stat.modified.isBefore(cutoff)) {
          await f.delete().catchError((_) => f);
        } else {
          survivors.add(f);
        }
      } catch (_) {}
    }
    if (survivors.length <= maxFiles) return;
    // Evict oldest first until within the cap.
    final sorted = survivors.toList()
      ..sort((a, b) {
        // Stat already succeeded above; on failure treat as oldest.
        return a.statSync().modified.compareTo(b.statSync().modified);
      });
    for (var i = 0; i < sorted.length - maxFiles; i++) {
      try {
        await sorted[i].delete();
      } catch (_) {}
    }
  }

  static Future<File> _writeOutputFile({
    required String workspaceRoot,
    required String toolName,
    required String content,
    String? toolCallId,
  }) async {
    final dir = Directory(p.join(workspaceRoot, toolOutputsDirRelative));
    await dir.create(recursive: true);

    final base = _buildFileBaseName(
      toolName: toolName,
      toolCallId: toolCallId,
    );
    var file = File(p.join(dir.path, '$base.txt'));
    if (!await file.exists()) {
      return file.writeAsString(content, flush: true);
    }
    // Id-bearing (or id-less unique) collision fallback: disambiguate.
    for (var i = 2;; i++) {
      file = File(p.join(dir.path, '$base-$i.txt'));
      if (!await file.exists()) {
        return file.writeAsString(content, flush: true);
      }
    }
  }

  /// `{tool}-{callId}` when an id is provided, otherwise a unique
  /// `{tool}-{timestamp}{token}` name. Both sides are sanitized to a safe
  /// filename charset — a hostile/odd id must never escape the directory.
  static String _buildFileBaseName({
    required String toolName,
    String? toolCallId,
  }) {
    String sanitize(String raw) {
      final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final trimmed =
          cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
      return trimmed.isEmpty ? 'output' : trimmed;
    }

    final tool = sanitize(toolName);
    final id = (toolCallId == null || toolCallId.trim().isEmpty)
        ? null
        : sanitize(toolCallId.trim());
    if (id != null) return '$tool-$id';
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rnd = Random();
    final token = List.generate(
      6,
      (_) => _alphabet[rnd.nextInt(_alphabet.length)],
    ).join();
    return '$tool-$stamp$token';
  }

  static const String _alphabet =
      'abcdefghijklmnopqrstuvwxyz0123456789';

  static String _buildPreviewResult({
    required String result,
    required String relativePath,
  }) {
    final preview = result.length > previewChars
        ? result.substring(0, previewChars)
        : result;
    final originalKB = (result.length / 1024).round();
    return '$preview\n\n'
        '[... tool output truncated — $originalKB KB total ...]\n\n'
        'Full output saved to: $relativePath\n'
        'Retrieve it with file_read(path: "$relativePath") — supports '
        'offset/limit paging for long outputs. For large logs, prefer '
        'file_search to locate specific keywords instead of reading '
        'everything.';
  }
}
