/// Tolerant text matching for `file_edit` (Cowork P1-8).
///
/// The model copies `old_text` out of a `file_read` result, but a single
/// leading space, a tab-vs-spaces difference, or a line-ending change used to
/// fail the whole edit. Matching now degrades through three strategies and
/// stops at the first one that finds at least one match:
///
///  1. [EditMatchStrategy.exact] - plain substring scan, the historical
///     behaviour. When it succeeds nothing about the result changes.
///  2. [EditMatchStrategy.lineTrimmed] - equal-length line windows compared
///     after `trim()`. Requires at least one line and rejects an `old_text`
///     that is entirely whitespace.
///  3. [EditMatchStrategy.blockAnchor] - windows of three or more lines whose
///     first and last line match; the middle of the window is *not* compared
///     and is replaced wholesale. Requires non-empty first/last lines.
///
/// Only the two line-based strategies re-indent `new_text` to the indentation
/// of the matched window (blank lines are left alone, and only lines that start
/// with the indentation of `old_text` are shifted). `exact` replacements stay
/// byte-for-byte what the model asked for.
///
/// This file is pure Dart on purpose: the strategy ladder is unit-testable
/// without a workspace or the Flutter test binding.
library;

/// Strategy names are surfaced in tool output; keep them stable.
enum EditMatchStrategy {
  exact('exact'),
  lineTrimmed('line_trimmed'),
  blockAnchor('block_anchor');

  const EditMatchStrategy(this.wireName);

  /// Identifier shown to the model (e.g. `matcher: line_trimmed`).
  final String wireName;
}

/// One replacement range. Offsets are code-unit indices into the source.
class EditMatch {
  const EditMatch({
    required this.start,
    required this.end,
    required this.replacement,
    required this.strategy,
  });

  final int start;
  final int end;
  final String replacement;
  final EditMatchStrategy strategy;
}

class EditMatchResult {
  const EditMatchResult({this.strategy, this.matches = const <EditMatch>[]});

  /// Strategy that produced [matches]; null when nothing matched.
  final EditMatchStrategy? strategy;

  /// Non-overlapping matches in source order.
  final List<EditMatch> matches;

  bool get isEmpty => matches.isEmpty;
  bool get isNotEmpty => matches.isNotEmpty;
  int get count => matches.length;
}

/// Runs the strategy ladder and returns every non-overlapping match produced by
/// the first strategy that finds any.
EditMatchResult findEditMatches(String source, String oldText, String newText) {
  if (oldText.isEmpty) return const EditMatchResult();

  final exact = _findExact(source, oldText, newText);
  if (exact.isNotEmpty) return exact;

  final lineTrimmed = _findLineTrimmed(source, oldText, newText);
  if (lineTrimmed.isNotEmpty) return lineTrimmed;

  return _findBlockAnchor(source, oldText, newText);
}

/// Applies [matches] to [source]. Later ranges are applied first so earlier
/// offsets stay valid.
String applyEditMatches(String source, List<EditMatch> matches) {
  final ordered = matches.toList()
    ..sort((left, right) => right.start.compareTo(left.start));
  var result = source;
  for (final match in ordered) {
    result = result.replaceRange(match.start, match.end, match.replacement);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Strategies
// ---------------------------------------------------------------------------

EditMatchResult _findExact(String source, String oldText, String newText) {
  final matches = <EditMatch>[];
  var start = 0;
  while (true) {
    final index = source.indexOf(oldText, start);
    if (index < 0) break;
    matches.add(
      EditMatch(
        start: index,
        end: index + oldText.length,
        replacement: newText,
        strategy: EditMatchStrategy.exact,
      ),
    );
    start = index + oldText.length;
  }
  return EditMatchResult(
    strategy: matches.isEmpty ? null : EditMatchStrategy.exact,
    matches: matches,
  );
}

EditMatchResult _findLineTrimmed(
  String source,
  String oldText,
  String newText,
) {
  final oldLines = _logicalLines(oldText);
  if (oldLines.isEmpty) return const EditMatchResult();
  final wanted = oldLines.map((line) => line.trim()).toList(growable: false);
  // An all-whitespace needle would match every blank window in the file.
  if (wanted.every((line) => line.isEmpty)) return const EditMatchResult();

  final sourceLines = _splitLines(source);
  final window = wanted.length;
  final oldIndent = _leadingWhitespace(oldLines.first);
  final matches = <EditMatch>[];
  var index = 0;
  while (index + window <= sourceLines.length) {
    var matched = true;
    for (var offset = 0; offset < window; offset++) {
      if (sourceLines[index + offset].text.trim() != wanted[offset]) {
        matched = false;
        break;
      }
    }
    if (!matched) {
      index++;
      continue;
    }
    matches.add(
      _buildMatch(
        sourceLines: sourceLines,
        firstLine: index,
        lineCount: window,
        oldIndent: oldIndent,
        newText: newText,
        strategy: EditMatchStrategy.lineTrimmed,
      ),
    );
    index += window;
  }
  return EditMatchResult(
    strategy: matches.isEmpty ? null : EditMatchStrategy.lineTrimmed,
    matches: matches,
  );
}

EditMatchResult _findBlockAnchor(
  String source,
  String oldText,
  String newText,
) {
  final oldLines = _logicalLines(oldText);
  if (oldLines.length < 3) return const EditMatchResult();
  final firstAnchor = oldLines.first.trim();
  final lastAnchor = oldLines.last.trim();
  if (firstAnchor.isEmpty || lastAnchor.isEmpty) {
    return const EditMatchResult();
  }

  final sourceLines = _splitLines(source);
  final window = oldLines.length;
  final oldIndent = _leadingWhitespace(oldLines.first);
  final matches = <EditMatch>[];
  var index = 0;
  while (index + window <= sourceLines.length) {
    final lastIndex = index + window - 1;
    if (sourceLines[index].text.trim() != firstAnchor ||
        sourceLines[lastIndex].text.trim() != lastAnchor) {
      index++;
      continue;
    }
    matches.add(
      _buildMatch(
        sourceLines: sourceLines,
        firstLine: index,
        lineCount: window,
        oldIndent: oldIndent,
        newText: newText,
        strategy: EditMatchStrategy.blockAnchor,
      ),
    );
    index += window;
  }
  return EditMatchResult(
    strategy: matches.isEmpty ? null : EditMatchStrategy.blockAnchor,
    matches: matches,
  );
}

// ---------------------------------------------------------------------------
// Window -> replacement
// ---------------------------------------------------------------------------

EditMatch _buildMatch({
  required List<_SourceLine> sourceLines,
  required int firstLine,
  required int lineCount,
  required String oldIndent,
  required String newText,
  required EditMatchStrategy strategy,
}) {
  final first = sourceLines[firstLine];
  final last = sourceLines[firstLine + lineCount - 1];
  return EditMatch(
    start: first.start,
    end: last.end,
    replacement: _prepareReplacement(
      newText,
      oldIndent: oldIndent,
      actualIndent: _leadingWhitespace(first.text),
      eol: _preferredTerminator(sourceLines, firstLine, lineCount),
    ),
    strategy: strategy,
  );
}

String _prepareReplacement(
  String newText, {
  required String oldIndent,
  required String actualIndent,
  required String eol,
}) {
  final normalized = _normalizeNewlines(newText, eol);
  if (oldIndent == actualIndent) return normalized;

  final buffer = <String>[];
  for (final line in normalized.split(eol)) {
    // Blank lines are left untouched, and so is anything that does not start
    // with the indentation the model used in old_text.
    if (line.trim().isEmpty || !line.startsWith(oldIndent)) {
      buffer.add(line);
      continue;
    }
    buffer.add('$actualIndent${line.substring(oldIndent.length)}');
  }
  return buffer.join(eol);
}

/// The file's own line ending wins so a tolerant edit never mixes CRLF and LF.
String _preferredTerminator(
  List<_SourceLine> lines,
  int firstLine,
  int lineCount,
) {
  final last = lines[firstLine + lineCount - 1].terminator;
  if (last.isNotEmpty) return last;
  final first = lines[firstLine].terminator;
  if (first.isNotEmpty) return first;
  return '\n';
}

String _normalizeNewlines(String text, String eol) {
  final lf = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return eol == '\n' ? lf : lf.replaceAll('\n', eol);
}

// ---------------------------------------------------------------------------
// Line helpers
// ---------------------------------------------------------------------------

class _SourceLine {
  const _SourceLine({
    required this.text,
    required this.start,
    required this.end,
    required this.terminator,
  });

  /// Line content without its terminator.
  final String text;

  /// Offset of the first code unit of [text].
  final int start;

  /// Offset just past [text] (the terminator, if any, starts here).
  final int end;

  /// `\r\n`, `\n`, `\r`, or empty for a final line without a terminator.
  final String terminator;
}

final RegExp _lineBreak = RegExp(r'\r\n|\n|\r');

/// Splits [text] into logical lines, dropping exactly one trailing terminator
/// so `"a\nb\n"` is two lines but `"a\nb\n\n"` keeps its intentional blank line.
List<String> _logicalLines(String text) {
  final lines = text.split(_lineBreak);
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

List<_SourceLine> _splitLines(String source) {
  final lines = <_SourceLine>[];
  var start = 0;
  var index = 0;
  while (index < source.length) {
    final unit = source.codeUnitAt(index);
    if (unit != 0x0a && unit != 0x0d) {
      index++;
      continue;
    }
    final terminatorLength =
        unit == 0x0d &&
            index + 1 < source.length &&
            source.codeUnitAt(index + 1) == 0x0a
        ? 2
        : 1;
    lines.add(
      _SourceLine(
        text: source.substring(start, index),
        start: start,
        end: index,
        terminator: source.substring(index, index + terminatorLength),
      ),
    );
    index += terminatorLength;
    start = index;
  }
  lines.add(
    _SourceLine(
      text: source.substring(start),
      start: start,
      end: source.length,
      terminator: '',
    ),
  );
  return lines;
}

final RegExp _leadingWhitespacePattern = RegExp(r'^[ \t]*');

String _leadingWhitespace(String line) =>
    _leadingWhitespacePattern.stringMatch(line) ?? '';
