import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/utils/markdown_media_sanitizer.dart';

/// 1x1 transparent PNG.
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

Future<File> _writeTempPng(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  final file = File('${dir.path}${Platform.pathSeparator}pic.png');
  await file.writeAsBytes(base64Decode(_onePixelPng));
  return file;
}

void main() {
  group('MarkdownMediaSanitizer.isLikelyLocalImagePath', () {
    test('rejects web and network locations', () {
      const urls = <String>[
        'https://example.com/a.png',
        'http://example.com/a.png',
        // Protocol-relative: a Windows UNC path if treated as local.
        '//thumb.wikimedia.org/wikipedia/commons/a.png',
        r'\\server\share\a.png',
        'data:image/png;base64,AAAA',
        // Remote file URI (UNC share).
        'file://server/share/a.png',
      ];
      for (final url in urls) {
        expect(
          MarkdownMediaSanitizer.isLikelyLocalImagePath(url),
          isFalse,
          reason: url,
        );
      }
    });

    test('accepts local absolute paths', () {
      const urls = <String>[
        r'C:\Users\me\a.png',
        'C:/Users/me/a.png',
        'file:///C:/Users/me/a.png',
      ];
      for (final url in urls) {
        expect(
          MarkdownMediaSanitizer.isLikelyLocalImagePath(url),
          isTrue,
          reason: url,
        );
      }
      // A leading `/` is a local absolute path on POSIX, but on Windows it is
      // a root-relative web path (and would probe e.g. C:\front\...).
      expect(
        MarkdownMediaSanitizer.isLikelyLocalImagePath(
          '/data/user/0/app/images/a.png',
        ),
        !Platform.isWindows,
      );
      expect(
        MarkdownMediaSanitizer.isLikelyLocalImagePath(
          'file:///data/user/0/app/images/a.png',
        ),
        isTrue,
      );
    });
  });

  test('leaves protocol-relative images untouched without UNC I/O', () async {
    const markdown =
        'before ![x](//thumb.wikimedia.org/wikipedia/commons/a.png) after';
    final sw = Stopwatch()..start();
    final out = await MarkdownMediaSanitizer.inlineLocalImagesToBase64(markdown);
    sw.stop();

    expect(out, markdown);
    // A regression would hit the Windows UNC/SMB timeout (10-25s).
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('leaves root-relative and UNC images untouched', () async {
    const markdown = 'a ![x](/assets/logo.png) b '
        r'![y](\\server\share\a.png)';
    final out = await MarkdownMediaSanitizer.inlineLocalImagesToBase64(markdown);
    expect(out, markdown);
  });

  test('inlines a real local image', () async {
    final file = await _writeTempPng('omni_inline_');
    final out = await MarkdownMediaSanitizer.inlineLocalImagesToBase64(
      '![x](${file.path})',
    );

    expect(out, contains('data:image/png;base64,'));
    expect(out, isNot(contains(file.path)));
  });

  test('resolves a file URI to a local path', () async {
    final file = await _writeTempPng('omni_inline_uri_');
    final uri = Uri.file(file.path).toString();
    final out =
        await MarkdownMediaSanitizer.inlineLocalImagesToBase64('![x]($uri)');

    expect(out, contains('data:image/png;base64,'));
    expect(out, isNot(contains(uri)));
  });
}
