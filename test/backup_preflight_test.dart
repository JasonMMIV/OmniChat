import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/core/services/backup/backup_preflight.dart';

/// Pure tests for the backup attachment manifest preflight (plan §3 Phase 2).
/// Paths are built from [Directory.systemTemp.path] so they are absolute on
/// every host platform (the local-path classifier rejects POSIX-style paths
/// on Windows and vice versa).
void main() {
  final base = Directory.systemTemp.path;
  final uploadRoot = p.join(base, 'preflight-upload');
  final imagesRoot = p.join(base, 'preflight-images');

  group('BackupFilePreflight.collectFromContent', () {
    test('collects image, file, and markdown image references', () {
      final refs = <String>{};
      BackupFilePreflight.collectFromContent(
        'text [image:${p.join(base, 'upload', 'a.png')}] more '
        '[file:${p.join(base, 'upload', 'b.pdf')}|b.pdf|application/pdf] '
        '![img](${p.join(base, 'images', 'c.png')}) '
        '![remote](https://example.com/d.png) '
        '![data](data:image/png;base64,AAA)',
        refs,
      );
      expect(refs, <String>{
        p.join(base, 'upload', 'a.png'),
        p.join(base, 'upload', 'b.pdf'),
        p.join(base, 'images', 'c.png'),
      });
    });

    test('ignores remote and data targets', () {
      final refs = <String>{};
      BackupFilePreflight.collectFromContent(
        '[image:https://example.com/x.png] '
        '[image:data:image/png;base64,AAA] '
        '[file:https://example.com/x.pdf|x.pdf|application/pdf]',
        refs,
      );
      expect(refs, isEmpty);
    });
  });

  group('BackupFilePreflight.classify', () {
    test('passes when every enforced reference is in the manifest', () {
      final result = BackupFilePreflight.classify(
        references: <String>[p.join(uploadRoot, 'a.png')],
        manifest: <String>[p.join(uploadRoot, 'a.png')],
        roots: <String>[uploadRoot, imagesRoot],
      );
      expect(result.ok, isTrue);
      expect(result.missingFiles, isEmpty);
      expect(result.notBackedUpPaths, isEmpty);
    });

    test('fails with the missing path for an app data reference', () {
      final missing = p.join(uploadRoot, 'ghost.png');
      final result = BackupFilePreflight.classify(
        references: <String>[missing],
        manifest: <String>[p.join(uploadRoot, 'a.png')],
        roots: <String>[uploadRoot],
      );
      expect(result.ok, isFalse);
      expect(result.missingFiles, <String>[missing]);
    });

    test('treats references outside the roots as informational', () {
      final outside = p.normalize(p.join(base, '..', 'workspace-note.png'));
      final result = BackupFilePreflight.classify(
        references: <String>[outside],
        manifest: <String>[],
        roots: <String>[uploadRoot],
      );
      expect(result.ok, isTrue);
      expect(result.notBackedUpPaths, <String>[outside]);
    });

    test('ignores remote and data references entirely', () {
      final result = BackupFilePreflight.classify(
        references: <String>[
          'https://example.com/a.png',
          'data:image/png;base64,AAA',
        ],
        manifest: <String>[],
        roots: <String>[uploadRoot],
      );
      expect(result.ok, isTrue);
      expect(result.notBackedUpPaths, isEmpty);
    });

    test('does not enforce a reference equal to a root directory', () {
      final result = BackupFilePreflight.classify(
        references: <String>[uploadRoot],
        manifest: <String>[],
        roots: <String>[uploadRoot],
      );
      expect(result.ok, isTrue);
    });
  });
}
