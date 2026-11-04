import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

String _pre(String input, {bool streaming = false}) {
  return MarkdownWithCodeHighlight.preprocessFences(
    input,
    enableMath: true,
    enableDollarLatex: true,
    streaming: streaming,
  );
}

String _cached(String input, {required bool streaming}) {
  return MarkdownWithCodeHighlight.preprocessCached(
    input,
    enableMath: true,
    enableDollarLatex: true,
    streaming: streaming,
  );
}

void main() {
  group('streaming fast path', () {
    test('keeps inline dollar math conversion', () {
      expect(_pre(r'Price is $5 and total is $10', streaming: true),
          contains(r'$5'));
      expect(_pre(r'$x$', streaming: true), contains(r'\(x\)'));
    });

    test('does not corrupt display math', () {
      final out = _pre(r'$$x$$', streaming: true);
      expect(out, isNot(contains(r'\(\)')));
      expect(out, contains(r'$$x$$'));
    });

    test('still auto-closes an unclosed fence', () {
      final out = _pre('```dart\nvoid main() {', streaming: true);
      expect(out.trimRight().endsWith('```'), isTrue);
    });

    test('skips link-title normalization while streaming', () {
      const input = '[a](https://example.com "title")';
      expect(_pre(input, streaming: true), contains('"title"'));
      expect(_pre(input), isNot(contains('"title"')));
    });

    test('keeps block-boundary passes identical while streaming', () {
      const cases = <String>[
        '* ```dart\nvoid main() {}\n```',
        '## 1. Introduction',
        '**作者:** 张三\n---',
        r'$$ \frac{a}{b} + \frac{c}{d} $$',
        '[a](https://a.com)  \n[b](https://b.com)  ',
      ];
      for (final input in cases) {
        expect(_pre(input, streaming: true), _pre(input), reason: input);
      }
    });
  });

  group('preprocess memoization', () {
    setUp(MarkdownWithCodeHighlight.clearPreprocessCache);

    test('returns the cached instance for identical input/flags', () {
      final a = _cached('hello', streaming: false);
      final b = _cached('hello', streaming: false);

      expect(identical(a, b), isTrue);
      expect(MarkdownWithCodeHighlight.preprocessCacheLength, 1);
    });

    test('streaming results are not cached', () {
      const input = '[a](https://example.com "title")';
      final full = _cached(input, streaming: false);
      expect(MarkdownWithCodeHighlight.preprocessCacheLength, 1);

      final streaming = _cached(input, streaming: true);
      expect(full, isNot(equals(streaming)));
      expect(MarkdownWithCodeHighlight.preprocessCacheLength, 1);
    });

    test('LRU keeps at most four entries', () {
      for (var i = 0; i < 6; i++) {
        _cached('text $i', streaming: false);
      }
      expect(MarkdownWithCodeHighlight.preprocessCacheLength, 4);
    });
  });
}
