// P1-1 tail: Myers unified diff for the post-execution file viewer.
//
// `diffutil_dart` supplies the Myers core (the same algorithm Android's
// DiffUtil uses). The update stream is replayed here to recover line
// alignment, then grouped into standard hunks with 3 context lines.
//
// Truncation contract (docs/Cowork剩餘項目實作計畫.md §2.15):
// - hunks are dropped from the TAIL until the render fits [maxChars];
// - `addedLines` / `removedLines` are the FULL totals, never derived from the
//   displayed (possibly truncated) hunks;
// - the dropped body-line count is reported as `... (N more lines)`.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:diffutil_dart/diffutil.dart';

enum DiffLineKind { context, added, removed }

class UnifiedDiffLine {
  const UnifiedDiffLine(this.kind, this.text);

  final DiffLineKind kind;
  final String text;

  String get prefix => switch (kind) {
    DiffLineKind.context => ' ',
    DiffLineKind.added => '+',
    DiffLineKind.removed => '-',
  };
}

class UnifiedDiffHunk {
  const UnifiedDiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<UnifiedDiffLine> lines;

  String get header => '@@ -$oldStart,$oldCount +$newStart,$newCount @@';

  String render() =>
      [header, for (final line in lines) '${line.prefix}${line.text}'].join(
        '\n',
      );
}

class UnifiedDiff {
  const UnifiedDiff({
    required this.path,
    required this.hunks,
    required this.addedLines,
    required this.removedLines,
    required this.truncated,
    required this.omittedLines,
    required this.text,
  });

  final String? path;
  final List<UnifiedDiffHunk> hunks;

  /// Full pre-truncation totals.
  final int addedLines;
  final int removedLines;

  final bool truncated;

  /// Body lines in the hunks dropped by the size cap.
  final int omittedLines;

  /// Ready-to-render unified diff (headers + hunks + optional marker).
  final String text;

  bool get isEmpty => addedLines == 0 && removedLines == 0;

  String render() => text;
}

class _DiffNode {
  const _DiffNode(this.text, {this.oldIndex, this.newIndex});

  final String text;
  final int? oldIndex;
  final int? newIndex;
}

class _LineDiffDelegate implements IndexableItemDiffDelegate<_DiffNode> {
  _LineDiffDelegate(this.oldItems, this.newItems);

  final List<_DiffNode> oldItems;
  final List<_DiffNode> newItems;

  @override
  int getOldListSize() => oldItems.length;

  @override
  int getNewListSize() => newItems.length;

  @override
  bool areItemsTheSame(int oldItemPosition, int newItemPosition) =>
      oldItems[oldItemPosition].text == newItems[newItemPosition].text;

  @override
  bool areContentsTheSame(int oldItemPosition, int newItemPosition) => true;

  @override
  Object? getChangePayload(int oldItemPosition, int newItemPosition) => null;

  @override
  _DiffNode getOldItemAtIndex(int index) => oldItems[index];

  @override
  _DiffNode getNewItemAtIndex(int index) => newItems[index];
}

/// Compute a standard unified diff between [oldText] and [newText].
///
/// Identical inputs return an empty diff (`addedLines == removedLines == 0`).
/// [maxBytes] caps the UTF-8 size of the rendered diff (64 KB by default).
UnifiedDiff computeUnifiedDiff(
  String oldText,
  String newText, {
  String? path,
  int contextLines = 3,
  int maxBytes = 64 * 1024,
}) {
  final oldLines = _splitLines(oldText);
  final newLines = _splitLines(newText);
  final oldNodes = <_DiffNode>[
    for (var i = 0; i < oldLines.length; i++)
      _DiffNode(oldLines[i], oldIndex: i),
  ];
  final newNodes = <_DiffNode>[
    for (var i = 0; i < newLines.length; i++)
      _DiffNode(newLines[i], newIndex: i),
  ];

  final updates = calculateDiff<_DiffNode>(
    _LineDiffDelegate(oldNodes, newNodes),
    detectMoves: false,
  ).getUpdatesWithData().toList();

  // Replay the updates to learn which old lines survived and where insertions
  // landed. `getUpdatesWithData()` reports removals/insertions in application
  // order (insertions at the same position arrive reversed), so applying them
  // sequentially to `working` reconstructs the new line order exactly.
  final working = List<_DiffNode>.of(oldNodes);
  for (final update in updates) {
    update.when<void>(
      insert: (position, data) {
        if (position >= 0 && position <= working.length) {
          working.insert(position, data);
        }
      },
      remove: (position, data) {
        if (position >= 0 && position < working.length) {
          working.removeAt(position);
        }
      },
      change: (position, oldData, newData) {},
      move: (from, to, data) {},
    );
  }

  // Next kept old-line index for every position; used to emit deletions
  // BEFORE the additions that replaced them at the same anchor.
  final nextKept = List<int>.filled(working.length, oldLines.length);
  var next = oldLines.length;
  for (var i = working.length - 1; i >= 0; i--) {
    final oldIndex = working[i].oldIndex;
    if (oldIndex != null) next = oldIndex;
    nextKept[i] = next;
  }

  final script = <UnifiedDiffLine>[];
  var oldCursor = 0;
  void flushRemovalsUntil(int end) {
    while (oldCursor < end) {
      script.add(UnifiedDiffLine(DiffLineKind.removed, oldLines[oldCursor]));
      oldCursor++;
    }
  }

  for (var i = 0; i < working.length; i++) {
    final node = working[i];
    if (node.oldIndex != null) {
      flushRemovalsUntil(node.oldIndex!);
      script.add(UnifiedDiffLine(DiffLineKind.context, node.text));
      oldCursor = node.oldIndex! + 1;
    } else {
      flushRemovalsUntil(nextKept[i]);
      script.add(UnifiedDiffLine(DiffLineKind.added, node.text));
    }
  }
  flushRemovalsUntil(oldLines.length);

  var added = 0;
  var removed = 0;
  final changeIndices = <int>[];
  for (var i = 0; i < script.length; i++) {
    switch (script[i].kind) {
      case DiffLineKind.added:
        added++;
        changeIndices.add(i);
      case DiffLineKind.removed:
        removed++;
        changeIndices.add(i);
      case DiffLineKind.context:
        break;
    }
  }

  final label = (path == null || path.trim().isEmpty) ? 'file' : path.trim();
  final header = '--- a/$label\n+++ b/$label';

  if (changeIndices.isEmpty) {
    return UnifiedDiff(
      path: path,
      hunks: const <UnifiedDiffHunk>[],
      addedLines: 0,
      removedLines: 0,
      truncated: false,
      omittedLines: 0,
      text: '',
    );
  }

  // Group changes whose gap is at most 2*context so their context windows
  // merge instead of producing overlapping hunks.
  final groups = <List<int>>[];
  var groupStart = changeIndices.first;
  var groupEnd = changeIndices.first;
  for (final index in changeIndices.skip(1)) {
    if (index - groupEnd - 1 <= contextLines * 2) {
      groupEnd = index;
    } else {
      groups.add(<int>[groupStart, groupEnd]);
      groupStart = index;
      groupEnd = index;
    }
  }
  groups.add(<int>[groupStart, groupEnd]);

  final hunks = <UnifiedDiffHunk>[];
  for (final group in groups) {
    final sliceStart = math.max(0, group[0] - contextLines);
    final sliceEnd = math.min(script.length, group[1] + contextLines + 1);
    final lines = script.sublist(sliceStart, sliceEnd);

    var oldCount = 0;
    var newCount = 0;
    for (final line in lines) {
      if (line.kind != DiffLineKind.added) oldCount++;
      if (line.kind != DiffLineKind.removed) newCount++;
    }
    var oldBefore = 0;
    var newBefore = 0;
    for (var i = 0; i < sliceStart; i++) {
      if (script[i].kind != DiffLineKind.added) oldBefore++;
      if (script[i].kind != DiffLineKind.removed) newBefore++;
    }
    hunks.add(
      UnifiedDiffHunk(
        oldStart: oldCount == 0 ? oldBefore : oldBefore + 1,
        oldCount: oldCount,
        newStart: newCount == 0 ? newBefore : newBefore + 1,
        newCount: newCount,
        lines: List<UnifiedDiffLine>.unmodifiable(lines),
      ),
    );
  }

  final blocks = <String>[for (final hunk in hunks) hunk.render()];
  var text = <String>[header, ...blocks].join('\n');
  var truncated = false;
  var omittedLines = 0;
  var visibleHunkCount = hunks.length;

  if (utf8.encode(text).length > maxBytes) {
    truncated = true;
    while (visibleHunkCount >= 0) {
      omittedLines = 0;
      for (var i = visibleHunkCount; i < hunks.length; i++) {
        omittedLines += hunks[i].lines.length;
      }
      final marker = '... ($omittedLines more lines)';
      text = <String>[
        header,
        ...blocks.take(visibleHunkCount),
        marker,
      ].join('\n');
      if (utf8.encode(text).length <= maxBytes) break;
      if (visibleHunkCount == 0) {
        // Extreme cap: keep the header only; counts stay authoritative.
        text = header;
        omittedLines = hunks.fold<int>(
          0,
          (sum, hunk) => sum + hunk.lines.length,
        );
        break;
      }
      visibleHunkCount--;
    }
  }

  return UnifiedDiff(
    path: path,
    hunks: List<UnifiedDiffHunk>.unmodifiable(
      hunks.take(visibleHunkCount),
    ),
    addedLines: added,
    removedLines: removed,
    truncated: truncated,
    omittedLines: omittedLines,
    text: text,
  );
}

List<String> _splitLines(String text) {
  if (text.isEmpty) return const <String>[];
  final normalized = text.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}
