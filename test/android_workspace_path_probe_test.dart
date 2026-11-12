import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/shell/android/workspace_path_probe.dart';

void main() {
  group('WorkspacePathProbe', () {
    test(
      'accepts an existing writable directory and returns its canonical path',
      () async {
        final temp = await Directory.systemTemp.createTemp('omnichat-probe-');
        try {
          final result = await WorkspacePathProbe.probe(temp.path);
          expect(result.ok, isTrue);
          expect(result.reason, isNull);
          expect(result.canonicalPath, isNotNull);
          expect(result.writable, isTrue);
          expect(result.readable, isTrue);
          expect(result.isDirectory, isTrue);
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );

    test('rejects missing, relative, empty, and content URIs', () async {
      expect((await WorkspacePathProbe.probe('')).reason, 'empty_path');
      expect(
        (await WorkspacePathProbe.probe('content://com.example/doc')).reason,
        'content_uri',
      );
      expect(
        (await WorkspacePathProbe.probe('relative/path')).reason,
        'not_absolute',
      );
      final missing = await Directory.systemTemp.createTemp('omnichat-probe-');
      final missingPath = missing.path;
      await missing.delete(recursive: true);
      final result = await WorkspacePathProbe.probe(missingPath);
      expect(result.ok, isFalse);
      expect(result.reason, 'not_found');
    });
  });
}
