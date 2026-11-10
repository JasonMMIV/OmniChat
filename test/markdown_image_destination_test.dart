import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/utils/markdown_media_sanitizer.dart';

void main() {
  group('MarkdownMediaSanitizer.stripImageDestinationAngleBrackets', () {
    test('normalizes CommonMark angle-bracket image destinations', () {
      expect(
        MarkdownMediaSanitizer.stripImageDestinationAngleBrackets(
          '![Eiffel](<https://example.com/a.jpg>)',
        ),
        '![Eiffel](https://example.com/a.jpg)',
      );
    });

    test('handles whitespace and multiple images', () {
      expect(
        MarkdownMediaSanitizer.stripImageDestinationAngleBrackets(
          '![a]( <https://example.com/a.jpg> )\n'
          '![b](<https://example.com/b.jpg>)',
        ),
        '![a](https://example.com/a.jpg)\n'
        '![b](https://example.com/b.jpg)',
      );
    });

    test('leaves plain image destinations and normal links untouched', () {
      const input =
          '![x](https://example.com/a.jpg) [link](<https://example.com>)';
      expect(
        MarkdownMediaSanitizer.stripImageDestinationAngleBrackets(input),
        input,
      );
    });

    test('sanitizer entry points normalize persisted markdown', () async {
      const input = '![a](<https://example.com/a.jpg>)';
      const expected = '![a](https://example.com/a.jpg)';
      expect(
        await MarkdownMediaSanitizer.inlineLocalImagesToBase64(input),
        expected,
      );
      expect(
        await MarkdownMediaSanitizer.replaceInlineBase64Images(input),
        expected,
      );
    });
  });
}
