// P2-6 L3 (docs/Cowork剩餘項目實作計畫.md §2.9): the workspace file map —
// a deterministic, budget-capped listing of the workspace tree injected at
// assembly time so the model knows what the workspace contains without
// spending `file_list` round-trips (and without guessing paths).
//
// Cache-prefix contract (plan §2.9.4): the block is rendered ONLY from
// stable tree facts — the relative path set and file sizes. Nothing volatile
// (wall-clock times, mtimes, scan counters) is rendered, so re-assembling
// against an unchanged tree yields a byte-identical block and the system
// prefix stays warm. An mtime-only `touch` therefore does NOT churn the
// cache; a size-changing rewrite does (accepted — the map is a navigation
// aid, `file_read` remains the source of truth).
//
// The walk reuses the P1-6 `WorkspaceSnapshot.capture` scanner (async, capped,
// link-free) and adds a stricter filter on top: ANY dot segment is dropped,
// so dotfiles (e.g. `.env`) and app-owned dirs (`.omnichat`) never leak into
// the prompt — same spirit as the dev server's dotfile 404s.
library;

import 'package:path/path.dart' as p;

import '../agent/compaction/context_trim.dart';
import '../shell/changed_files.dart';

class WorkspaceFileMap {
  /// Estimated-token budget (chars/3, same estimator as the compaction
  /// knowledge block). Plan §2.9.3 suggests ~1–2k tokens.
  static const int tokenCap = 1600;

  /// Rendered entry cap; anything beyond is summarized as `(+N more)`.
  static const int maxEntries = 200;

  /// Label for files recorded as tool-written in this conversation
  /// (FileRecord persistence, `tool_handler_service.dart`).
  static const String toolWrittenLabel = 'agent-written';

  /// Builds the map block, or '' when there is nothing to show.
  ///
  /// [toolWrittenAbsolutePaths] are absolute paths (FileRecord data) the
  /// agent created/modified during this conversation; entries outside
  /// [workspacePath] (e.g. the session-outputs zone) are ignored.
  ///
  /// Budget degradation (plan §2.9.3), in order:
  /// 1. full render (path · size · agent-written);
  /// 2. over cap → bare paths only;
  /// 3. still over cap → trailing entries dropped, `(+N more)` appended.
  static Future<String> build({
    required String workspacePath,
    Iterable<String> toolWrittenAbsolutePaths = const [],
  }) async {
    final WorkspaceSnapshot snapshot;
    try {
      snapshot = await WorkspaceSnapshot.capture(workspacePath);
    } catch (_) {
      return '';
    }
    final toolWritten = <String>{};
    for (final absolute in toolWrittenAbsolutePaths) {
      // Per-path guard: one malformed FileRecord path must not drop the
      // whole map.
      try {
        if (p.isWithin(workspacePath, absolute)) {
          // Lowercase both sides: FileRecord paths recorded from user
          // arguments can differ in casing from the on-disk snapshot keys
          // (Windows).
          toolWritten.add(
            p
                .relative(absolute, from: workspacePath)
                .replaceAll('\\', '/')
                .toLowerCase(),
          );
        }
      } catch (_) {}
    }

    final files = <_MappedFile>[
      for (final entry in snapshot.files.entries)
        if (!_hasDotSegment(entry.key))
          _MappedFile(path: entry.key, sizeBytes: entry.value.size),
    ]..sort(_byPath);
    if (files.isEmpty) return '';
    final header =
        'Workspace file map (${files.length} files, paths relative to the '
        'workspace root):';
    // Hard render cap, enforced in every stage (docs contract).
    final entryCap = files.length > maxEntries ? maxEntries : files.length;

    String render({required bool annotate, int? limit}) {
      final effectiveLimit = limit ?? entryCap;
      final shown = files.sublist(0, effectiveLimit);
      final lines = <String>[
        header,
        for (final file in shown)
          annotate
              ? '- ${file.path} · ${_formatSize(file.sizeBytes)}'
                    '${toolWritten.contains(file.path.toLowerCase()) ? ' · $toolWrittenLabel' : ''}'
              : '- ${file.path}',
      ];
      if (files.length > effectiveLimit) {
        lines.add('(+${files.length - effectiveLimit} more files not shown)');
      }
      if (snapshot.truncated) {
        lines.add('(listing may be incomplete)');
      }
      return lines.join('\n');
    }

    final annotated = render(annotate: true);
    if (estimateTextTokens(annotated) <= tokenCap) return annotated;

    final bare = render(annotate: false);
    if (estimateTextTokens(bare) <= tokenCap) return bare;

    // Stage 3: binary-search the longest bare prefix that fits, then the
    // overflow marker. Deterministic for a given tree state.
    var low = 0;
    var high = entryCap;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (estimateTextTokens(render(annotate: false, limit: mid)) <= tokenCap) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    // Always show at least one entry plus the overflow marker.
    return render(annotate: false, limit: low < 1 ? 1 : low);
  }

  /// True when any path segment is dot-prefixed (`.git`, `.omnichat`, `.env`,
  /// `.well-known`, …). Keys from [WorkspaceSnapshot] always use `/`.
  static bool _hasDotSegment(String relativePath) {
    for (final segment in relativePath.split('/')) {
      if (segment.startsWith('.')) return true;
    }
    return false;
  }

  static int _byPath(_MappedFile a, _MappedFile b) {
    final byLower = a.path.toLowerCase().compareTo(b.path.toLowerCase());
    if (byLower != 0) return byLower;
    return a.path.compareTo(b.path);
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _MappedFile {
  const _MappedFile({required this.path, required this.sizeBytes});

  final String path;
  final int sizeBytes;
}
