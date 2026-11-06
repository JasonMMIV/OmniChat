import 'package:OmniChat/core/services/file/edit_matchers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('exact strategy', () {
    test('replaces verbatim and reports exact', () {
      const source = 'one\ntwo\nthree\n';
      final result = findEditMatches(source, 'two', 'TWO');

      expect(result.strategy, EditMatchStrategy.exact);
      expect(result.count, 1);
      expect(applyEditMatches(source, result.matches), 'one\nTWO\nthree\n');
    });

    test('collects every non-overlapping occurrence', () {
      const source = 'aaaa';
      final result = findEditMatches(source, 'aa', 'b');

      expect(result.strategy, EditMatchStrategy.exact);
      expect(result.count, 2);
      expect(applyEditMatches(source, result.matches), 'bb');
    });

    test('stops the ladder when the exact text exists', () {
      // A tolerant strategy would also match the surrounding block; the exact
      // hit must win so indentation is never rewritten on a normal edit.
      const source = '  keep me\n  value\n  keep me\n';
      final result = findEditMatches(source, '  value', 'changed');

      expect(result.strategy, EditMatchStrategy.exact);
      expect(result.count, 1);
      expect(
        applyEditMatches(source, result.matches),
        '  keep me\nchanged\n  keep me\n',
      );
    });

    test('is byte-for-byte, never re-indented', () {
      const source = 'if (x) {\n    run();\n}\n';
      final result = findEditMatches(source, '    run();', 'run();');

      expect(result.strategy, EditMatchStrategy.exact);
      expect(applyEditMatches(source, result.matches), 'if (x) {\nrun();\n}\n');
    });
  });

  group('line_trimmed strategy', () {
    test('matches a single line with deeper indentation in the needle', () {
      // Six spaces in old_text against four in the file: the exact scan misses,
      // the trimmed window matches, and new_text is pulled back to two levels.
      const source = 'def f():\n    return 1\n\nnext\n';
      final result = findEditMatches(
        source,
        '      return 1',
        '      return 2',
      );

      expect(result.strategy, EditMatchStrategy.lineTrimmed);
      expect(
        applyEditMatches(source, result.matches),
        'def f():\n    return 2\n\nnext\n',
      );
    });

    test('re-indents multi-line replacements against the matched window', () {
      const source = '  if (x) {\n    run();\n  }\n';
      final result = findEditMatches(
        source,
        'if (x) {\n  run();\n}',
        'if (y) {\n  stop();\n}',
      );

      expect(result.strategy, EditMatchStrategy.lineTrimmed);
      expect(
        applyEditMatches(source, result.matches),
        '  if (y) {\n    stop();\n  }\n',
      );
    });

    test('leaves blank lines untouched while re-indenting', () {
      const source = '\tblock\n\n\tend\n';
      final result = findEditMatches(source, 'block\n\nend', 'first\n\nlast');

      expect(result.strategy, EditMatchStrategy.lineTrimmed);
      expect(applyEditMatches(source, result.matches), '\tfirst\n\n\tlast\n');
    });

    test('rejects an all-whitespace needle', () {
      const source = 'a\n\n\nb\n';
      final result = findEditMatches(source, '   ', 'x');

      expect(result.isEmpty, isTrue);
      expect(result.strategy, isNull);
    });

    test('scans non-overlapping windows only', () {
      const source = 'x\n  y\nx\n  y\nx\n  y\n';
      final result = findEditMatches(source, 'x\n y', 'Z');

      expect(result.strategy, EditMatchStrategy.lineTrimmed);
      expect(result.count, 3);
      expect(applyEditMatches(source, result.matches), 'Z\nZ\nZ\n');
    });

    test('keeps the CRLF line ending of the file', () {
      const source = 'one\r\ntwo\r\nthree\r\n';
      final result = findEditMatches(
        source,
        'one\ntwo\nthree',
        'uno\ndos\ntres',
      );

      expect(result.strategy, EditMatchStrategy.lineTrimmed);
      expect(
        applyEditMatches(source, result.matches),
        'uno\r\ndos\r\ntres\r\n',
      );
    });

    test('drops one trailing line break from the needle', () {
      const source = 'alpha\nbeta\ngamma\n';
      final result = findEditMatches(source, '  beta\n', '  BETA');

      expect(result.strategy, EditMatchStrategy.lineTrimmed);
      expect(applyEditMatches(source, result.matches), 'alpha\nBETA\ngamma\n');
    });

    test('keeps multi-byte text and indentation intact', () {
      const source = 'prefix\n  A😀B\n  tail\n';
      final result = findEditMatches(source, 'A😀B\ntail', 'X😀Y\ntail2');

      expect(result.strategy, EditMatchStrategy.lineTrimmed);
      expect(
        applyEditMatches(source, result.matches),
        'prefix\n  X😀Y\n  tail2\n',
      );
    });
  });

  group('block_anchor strategy', () {
    test('replaces the whole window when the middle drifted', () {
      const source = 'function f() {\n  old body\n}\nafter\n';
      final result = findEditMatches(
        source,
        'function f() {\n  drifted body\n}',
        'function g() {\n  new body\n}',
      );

      expect(result.strategy, EditMatchStrategy.blockAnchor);
      expect(
        applyEditMatches(source, result.matches),
        'function g() {\n  new body\n}\nafter\n',
      );
    });

    test('needs at least three lines', () {
      const source = 'a\nx\n';
      final result = findEditMatches(source, 'a\ny', 'z');

      expect(result.isEmpty, isTrue);
    });

    test('rejects a blank anchor line', () {
      const source = 'zzz\n  mid\nend\n';
      final result = findEditMatches(source, '\nmid\nend', 'x');

      expect(result.isEmpty, isTrue);
    });
  });

  group('ladder', () {
    test('reports nothing when no strategy matches', () {
      const source = 'alpha\nbeta\n';
      final result = findEditMatches(source, 'gamma', 'x');

      expect(result.isEmpty, isTrue);
      expect(result.strategy, isNull);
    });

    test('applies replace_all matches from the end of the file', () {
      const source = 'x\n  y\npadding\nx\n  y\n';
      final result = findEditMatches(source, 'x\n y', 'Z');
      final updated = applyEditMatches(source, result.matches);

      expect(updated, 'Z\npadding\nZ\n');
      expect(source, 'x\n  y\npadding\nx\n  y\n');
    });
  });
}
