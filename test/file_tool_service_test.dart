import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('omnichat_file_tools_');
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('rejects traversal and absolute paths', () {
    expect(
      () => FileToolService.resolveSafePath('../outside.txt', workspace.path),
      throwsA(isA<FileToolSecurityException>()),
    );
    expect(
      () => FileToolService.resolveSafePath(
        Directory.systemTemp.path,
        workspace.path,
      ),
      throwsA(isA<FileToolSecurityException>()),
    );
  });

  test('writes, reads, appends, and enforces byte limits', () async {
    final write = await FileToolService.execute('file_write', {
      'path': 'notes/hello.txt',
      'content': 'hello',
    }, workspace.path);
    expect(write.createdOrModifiedFilePath, isNotNull);
    expect(
      await File('${workspace.path}/notes/hello.txt').readAsString(),
      'hello',
    );

    final missingContent = await FileToolService.execute('file_write', {
      'path': 'notes/hello.txt',
    }, workspace.path);
    expect(missingContent.text, contains('content argument'));
    expect(
      await File('${workspace.path}/notes/hello.txt').readAsString(),
      'hello',
    );

    final append = await FileToolService.execute('file_append', {
      'path': 'notes/hello.txt',
      'content': ' world',
    }, workspace.path);
    expect(append.text, contains('Appended'));
    expect(
      await File('${workspace.path}/notes/hello.txt').readAsString(),
      'hello world',
    );

    final oversized = await FileToolService.execute('file_write', {
      'path': 'too-large.txt',
      'content': 'x' * (FileToolService.maxWriteBytes + 1),
    }, workspace.path);
    expect(oversized.text, contains('512 KB'));
    expect(File('${workspace.path}/too-large.txt').existsSync(), isFalse);
  });

  test('truncates reads at one megabyte', () async {
    final file = File('${workspace.path}/large.txt');
    await file.writeAsBytes(
      utf8.encode('x' * (FileToolService.maxReadBytes + 10)),
    );

    final result = await FileToolService.execute('file_read', {
      'path': 'large.txt',
    }, workspace.path);
    expect(result.text, contains('output truncated'));
    expect(
      utf8.encode(result.text).length,
      lessThan(FileToolService.maxReadBytes + 100),
    );
  });

  test('bounds directory listings without loading every entry', () async {
    for (var i = 0; i <= FileToolService.maxListedEntries; i++) {
      await File('${workspace.path}/entry_$i.txt').writeAsString('$i');
    }

    final result = await FileToolService.execute('file_list', {
      'path': '',
    }, workspace.path);
    expect(result.text, contains('listing truncated'));
  });

  test(
    'supports directory, copy, move, search, info, and delete operations',
    () async {
      await FileToolService.execute('file_mkdir', {
        'path': 'src',
      }, workspace.path);
      await FileToolService.execute('file_write', {
        'path': 'src/app.py',
        'content': 'print(1)',
      }, workspace.path);
      final listed = await FileToolService.execute('file_list', {
        'path': '',
      }, workspace.path);
      expect(listed.text, contains('src'));

      final info = await FileToolService.execute('file_info', {
        'path': 'src/app.py',
      }, workspace.path);
      expect(info.text, contains('app.py'));

      await FileToolService.execute('file_copy', {
        'source': 'src/app.py',
        'destination': 'copy.py',
      }, workspace.path);
      await FileToolService.execute('file_move', {
        'source': 'copy.py',
        'destination': 'moved.py',
      }, workspace.path);
      final search = await FileToolService.execute('file_search', {
        'pattern': '*.py',
      }, workspace.path);
      expect(search.text, contains('src${Platform.pathSeparator}app.py'));
      expect(search.text, contains('moved.py'));

      await FileToolService.execute('file_delete', {
        'path': 'moved.py',
      }, workspace.path);
      expect(File('${workspace.path}/moved.py').existsSync(), isFalse);
    },
  );

  test('blocks executable extensions', () async {
    final result = await FileToolService.execute('file_write', {
      'path': 'unsafe.exe',
      'content': 'not executable',
    }, workspace.path);
    expect(result.text, contains('blocked'));
  });

  test('rejects a symlink that resolves outside the workspace', () async {
    final outside = await Directory.systemTemp.createTemp(
      'omnichat_file_tools_outside_',
    );
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await File('${outside.path}/secret.txt').writeAsString('secret');
    try {
      await Link('${workspace.path}/link').create(outside.path);
    } catch (_) {
      return; // Symlink creation may require elevated privileges on Windows.
    }

    expect(
      () => FileToolService.resolveSafePath('link/secret.txt', workspace.path),
      throwsA(isA<FileToolSecurityException>()),
    );
  });
}
