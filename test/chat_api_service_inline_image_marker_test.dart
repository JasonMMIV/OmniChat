import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/api/chat_api_service.dart';

void main() {
  group('ChatApiService inline image markers', () {
    test('keeps the literal placeholder as plain text', () async {
      final result = await ChatApiService.parseTextAndImagesForTest(
        'Result: [image:<absolute-path>]',
        allowRemoteImages: false,
        allowLocalImages: true,
      );

      expect(result['text'], 'Result: [image:<absolute-path>]');
      expect(result['images'], isEmpty);
    });

    test('keeps a missing local path as plain text', () async {
      final missing =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'omnichat_missing_${DateTime.now().microsecondsSinceEpoch}.png';
      final result = await ChatApiService.parseTextAndImagesForTest(
        'Preview: [image:$missing]',
        allowRemoteImages: false,
        allowLocalImages: true,
      );

      expect(result['text'], 'Preview: [image:$missing]');
      expect(result['images'], isEmpty);
    });

    test('keeps a local path when local images are disabled', () async {
      final dir = await Directory.systemTemp.createTemp('omnichat_parser_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}preview.png')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      final result = await ChatApiService.parseTextAndImagesForTest(
        'Preview: [image:${file.path}]',
        allowRemoteImages: false,
        allowLocalImages: false,
      );

      expect(result['text'], 'Preview: [image:${file.path}]');
      expect(result['images'], isEmpty);
    });

    test('attaches an existing local image path', () async {
      final dir = await Directory.systemTemp.createTemp('omnichat_parser_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}preview.png')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      final result = await ChatApiService.parseTextAndImagesForTest(
        'Preview: [image:${file.path}]',
        allowRemoteImages: false,
        allowLocalImages: true,
      );

      final images = (result['images'] as List).cast<Map<String, String>>();
      expect(result['text'], 'Preview:');
      expect(images, hasLength(1));
      expect(images.single['kind'], 'path');
      expect(images.single['src'], file.path);
    });

    test('keeps a remote marker when remote images are disabled', () async {
      final result = await ChatApiService.parseTextAndImagesForTest(
        'Preview: [image:https://example.com/a.png]',
        allowRemoteImages: false,
        allowLocalImages: true,
      );

      expect(result['text'], 'Preview: [image:https://example.com/a.png]');
      expect(result['images'], isEmpty);
    });

    test('keeps protocol-relative markers as plain text', () async {
      const raw = 'Preview: [image://host/share/a.png]';
      final result = await ChatApiService.parseTextAndImagesForTest(
        raw,
        allowRemoteImages: true,
        allowLocalImages: true,
      );

      expect(result['text'], raw);
      expect(result['images'], isEmpty);
    });

    test('keeps UNC markers as plain text', () async {
      const raw = r'Preview: [image:\\host\share\a.png]';
      final result = await ChatApiService.parseTextAndImagesForTest(
        raw,
        allowRemoteImages: true,
        allowLocalImages: true,
      );

      expect(result['text'], raw);
      expect(result['images'], isEmpty);
    });

    test('keeps remote file-uri markers as plain text', () async {
      const raw = 'Preview: [image:file://host/share/a.png]';
      final result = await ChatApiService.parseTextAndImagesForTest(
        raw,
        allowRemoteImages: true,
        allowLocalImages: true,
      );

      expect(result['text'], raw);
      expect(result['images'], isEmpty);
    });

    test('keeps protocol-relative markdown images as plain text', () async {
      const raw = 'Preview: ![x](//host/share/a.png)';
      final result = await ChatApiService.parseTextAndImagesForTest(
        raw,
        allowRemoteImages: true,
        allowLocalImages: true,
      );

      expect(result['text'], raw);
      expect(result['images'], isEmpty);
    });

    test('keeps remote file-uri markdown images as plain text', () async {
      const raw = 'Preview: ![x](file://host/share/a.png)';
      final result = await ChatApiService.parseTextAndImagesForTest(
        raw,
        allowRemoteImages: true,
        allowLocalImages: true,
      );

      expect(result['text'], raw);
      expect(result['images'], isEmpty);
    });

    test('attaches a remote marker when remote images are enabled', () async {
      final result = await ChatApiService.parseTextAndImagesForTest(
        'Preview: [image:https://example.com/a.png]',
        allowRemoteImages: true,
        allowLocalImages: true,
      );

      final images = (result['images'] as List).cast<Map<String, String>>();
      expect(result['text'], 'Preview:');
      expect(images, hasLength(1));
      expect(images.single['kind'], 'url');
      expect(images.single['src'], 'https://example.com/a.png');
    });

    test('keeps a whitespace-only marker as plain text', () async {
      final result = await ChatApiService.parseTextAndImagesForTest(
        'Preview: [image:   ]',
        allowRemoteImages: false,
        allowLocalImages: true,
      );

      expect(result['text'], 'Preview: [image:   ]');
      expect(result['images'], isEmpty);
    });

    test('parses data-url markers without touching the filesystem', () async {
      final result = await ChatApiService.parseTextAndImagesForTest(
        'Preview: [image:data:image/png;base64,AAAA]',
        allowRemoteImages: false,
        allowLocalImages: true,
      );

      final images = (result['images'] as List).cast<Map<String, String>>();
      expect(result['text'], 'Preview:');
      expect(images, hasLength(1));
      expect(images.single['kind'], 'data');
      expect(images.single['src'], 'data:image/png;base64,AAAA');
    });
  });
}
