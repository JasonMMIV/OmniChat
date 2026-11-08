import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/unified_diff.dart';

UnifiedDiff _diff(String oldText, String newText, {int? maxBytes}) =>
    computeUnifiedDiff(
      oldText,
      newText,
      path: 'dir/file.txt',
      maxBytes: maxBytes ?? 64 * 1024,
    );

String _lines(List<String> lines) => '${lines.join('\n')}\n';

void main() {
  test('identical text produces an empty diff', () {
    final diff = _diff('a\nb\n', 'a\nb\n');
    expect(diff.isEmpty, isTrue);
    expect(diff.addedLines, 0);
    expect(diff.removedLines, 0);
    expect(diff.hunks, isEmpty);
    expect(diff.text, isEmpty);
    expect(diff.truncated, isFalse);
  });

  test('insertion keeps 3 context lines and counts additions', () {
    final diff = _diff('a\nb\nc\n', 'a\nx\nb\nc\n');
    expect(diff.addedLines, 1);
    expect(diff.removedLines, 0);
    expect(diff.truncated, isFalse);
    expect(diff.hunks, hasLength(1));
    expect(diff.hunks.single.header, '@@ -1,3 +1,4 @@');
    expect(
      diff.text,
      '--- a/dir/file.txt\n'
      '+++ b/dir/file.txt\n'
      '@@ -1,3 +1,4 @@\n'
      ' a\n'
      '+x\n'
      ' b\n'
      ' c',
    );
  });

  test('deletion emits removed lines before later context', () {
    final diff = _diff('a\nb\nc\n', 'a\nc\n');
    expect(diff.addedLines, 0);
    expect(diff.removedLines, 1);
    expect(diff.hunks.single.header, '@@ -1,3 +1,2 @@');
    expect(diff.text, contains('\n a\n-b\n c'));
  });

  test('replacement renders as removal then addition', () {
    final diff = _diff('a\nb\n', 'a\nB\n');
    expect(diff.addedLines, 1);
    expect(diff.removedLines, 1);
    expect(diff.hunks.single.header, '@@ -1,2 +1,2 @@');
    expect(diff.text, contains('\n a\n-b\n+B'));
  });

  test('empty old file is a pure addition hunk', () {
    final diff = _diff('', 'x\n');
    expect(diff.addedLines, 1);
    expect(diff.removedLines, 0);
    expect(diff.hunks.single.header, '@@ -0,0 +1,1 @@');
    expect(diff.text, contains('\n+x'));
  });

  test('empty new file is a pure deletion hunk', () {
    final diff = _diff('x\n', '');
    expect(diff.addedLines, 0);
    expect(diff.removedLines, 1);
    expect(diff.hunks.single.header, '@@ -1,1 +0,0 @@');
    expect(diff.text, contains('\n-x'));
  });

  test('CRLF and LF are compared line-wise', () {
    final diff = _diff('a\r\nb\r\n', 'a\r\nB\r\n');
    expect(diff.addedLines, 1);
    expect(diff.removedLines, 1);
    expect(diff.text, isNot(contains('\r')));
    expect(diff.text, contains('-b'));
    expect(diff.text, contains('+B'));
  });

  test('nearby changes merge and distant changes split hunks', () {
    final oldLines = List<String>.generate(20, (i) => 'line$i');

    final close = List<String>.of(oldLines)..[2] = 'changed2';
    expect(_diff(_lines(oldLines), _lines(close)).hunks, hasLength(1));

    final far = List<String>.of(oldLines)
      ..[2] = 'changed2'
      ..[14] = 'changed14';
    expect(_diff(_lines(oldLines), _lines(far)).hunks, hasLength(2));
  });

  test('truncation drops tail hunks but keeps full totals', () {
    final oldLines = List<String>.generate(30, (i) => 'line $i');
    final newLines = List<String>.of(oldLines);
    for (var i = 1; i < newLines.length; i += 10) {
      newLines[i] = 'changed $i';
    }

    final full = _diff(_lines(oldLines), _lines(newLines));
    final capped = _diff(_lines(oldLines), _lines(newLines), maxBytes: 160);

    expect(capped.truncated, isTrue);
    expect(capped.hunks.length, lessThan(full.hunks.length));
    expect(capped.addedLines, full.addedLines);
    expect(capped.removedLines, full.removedLines);
    expect(utf8.encode(capped.text).length, lessThanOrEqualTo(160));
    expect(capped.text, contains(RegExp(r'\.\.\. \(\d+ more lines\)')));

    final dropped = full.hunks
        .skip(capped.hunks.length)
        .fold<int>(0, (sum, hunk) => sum + hunk.lines.length);
    expect(capped.omittedLines, dropped);
    expect(capped.omittedLines, greaterThan(0));
  });

  test('truncation counts UTF-8 bytes for CJK text', () {
    final oldLines = List<String>.generate(30, (i) => '第 $i 行');
    final newLines = List<String>.of(oldLines);
    for (var i = 1; i < newLines.length; i += 10) {
      newLines[i] = '改 $i 行';
    }

    final full = _diff(_lines(oldLines), _lines(newLines));
    final capped = _diff(_lines(oldLines), _lines(newLines), maxBytes: 250);

    expect(capped.truncated, isTrue);
    expect(utf8.encode(capped.text).length, lessThanOrEqualTo(250));
    expect(capped.text, contains(RegExp(r'\.\.\. \(\d+ more lines\)')));
    expect(capped.addedLines, full.addedLines);
    expect(capped.removedLines, full.removedLines);
  });

  group('update replay ordering', () {
    List<String> addedTexts(UnifiedDiff diff) => [
      for (final hunk in diff.hunks)
        for (final line in hunk.lines)
          if (line.kind == DiffLineKind.added) line.text,
    ];

    List<String> removedTexts(UnifiedDiff diff) => [
      for (final hunk in diff.hunks)
        for (final line in hunk.lines)
          if (line.kind == DiffLineKind.removed) line.text,
    ];

    test('multiple inserted lines keep textual order', () {
      final diff = _diff('a\nb\n', 'x\ny\na\nb\n');
      expect(addedTexts(diff), ['x', 'y']);
      expect(removedTexts(diff), isEmpty);
    });

    test('replacing one line with several keeps order', () {
      final diff = _diff('a\nb\n', 'a\nX\nY\nZ\n');
      expect(addedTexts(diff), ['X', 'Y', 'Z']);
      expect(removedTexts(diff), ['b']);
    });

    test('interleaved replacements keep textual order', () {
      final diff = _diff('a\nb\nc\nd\ne\n', 'a\nX\nc\nY\ne\nZ\n');
      expect(addedTexts(diff), ['X', 'Y', 'Z']);
      expect(removedTexts(diff), ['b', 'd']);
    });

    test('replacing the whole file keeps order', () {
      final diff = _diff('a\n', 'x\ny\nz\n');
      expect(addedTexts(diff), ['x', 'y', 'z']);
      expect(removedTexts(diff), ['a']);
    });

    test('duplicate lines still reconstruct the new file', () {
      final newLines = ['b', 'a', 'b', 'a'];
      final diff = _diff(_lines(['a', 'b', 'a', 'b']), _lines(newLines));
      final renderedNew = [
        for (final hunk in diff.hunks)
          for (final line in hunk.lines)
            if (line.kind != DiffLineKind.removed) line.text,
      ];
      expect(renderedNew, newLines);
    });
  });
}
