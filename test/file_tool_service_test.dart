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

  test('reads bounded segments and supports continuation offsets', () async {
    final file = File('${workspace.path}/large.txt');
    await file.writeAsBytes(
      utf8.encode('x' * (FileToolService.maxReadBytes + 10)),
    );

    final result = await FileToolService.execute('file_read', {
      'path': 'large.txt',
    }, workspace.path);
    expect(result.text, contains('has_more=true'));
    expect(result.text, contains('next_offset='));
    expect(
      utf8.encode(result.text).length,
      lessThan(FileToolService.defaultReadBytes + 200),
    );

    final capped = await FileToolService.execute('file_read', {
      'path': 'large.txt',
      'limit': FileToolService.maxReadBytes + 1,
    }, workspace.path);
    expect(capped.text, contains('limit capped'));
    expect(capped.text, contains('has_more=true'));

    final first = await FileToolService.execute('file_read', {
      'path': 'large.txt',
      'limit': 10,
    }, workspace.path);
    expect(first.text, contains('next_offset=10'));
    final second = await FileToolService.execute('file_read', {
      'path': 'large.txt',
      'offset': 10,
      'limit': 10,
    }, workspace.path);
    expect(second.text, contains('Read bytes 10-20'));
  });

  test('does not split a UTF-8 code point at a segment boundary', () async {
    final file = File('${workspace.path}/unicode.txt');
    await file.writeAsString('A😀B');

    // The emoji occupies bytes 1..4. Offset 2 is in the middle of it, so the
    // reader advances to the next complete code point instead of returning a
    // replacement character.
    final result = await FileToolService.execute('file_read', {
      'path': 'unicode.txt',
      'offset': 2,
      'limit': 10,
    }, workspace.path);
    expect(result.text, contains('\nB'));
    expect(result.text, isNot(contains('\uFFFD')));

    final tinyLimit = await FileToolService.execute('file_read', {
      'path': 'unicode.txt',
      'offset': 1,
      'limit': 1,
    }, workspace.path);
    expect(tinyLimit.text, contains('\n😀'));
    expect(tinyLimit.text, contains('next_offset=5'));
  });

  test('exposes edit and patch tools in the definition list', () {
    final names = FileToolService.getToolDefinitions()
        .map((definition) => definition['function']['name'])
        .toSet();
    expect(names, containsAll(<String>['file_edit', 'file_patch']));
  });

  test('edits exact text and rejects ambiguous matches', () async {
    final file = File('${workspace.path}/edit.txt');
    await file.writeAsString('one\ntwo\ntwo\n');

    final ambiguous = await FileToolService.execute('file_edit', {
      'path': 'edit.txt',
      'old_text': 'two',
      'new_text': 'TWO',
    }, workspace.path);
    expect(ambiguous.text, contains('matched 2 times'));
    expect(await file.readAsString(), 'one\ntwo\ntwo\n');

    final unique = await FileToolService.execute('file_edit', {
      'path': 'edit.txt',
      'old_text': 'one',
      'new_text': 'ONE',
    }, workspace.path);
    expect(unique.createdOrModifiedFilePath, isNotNull);
    expect(await file.readAsString(), 'ONE\ntwo\ntwo\n');

    final all = await FileToolService.execute('file_edit', {
      'path': 'edit.txt',
      'old_text': 'two',
      'new_text': 'TWO',
      'replace_all': true,
    }, workspace.path);
    expect(all.text, contains('Edited'));
    expect(await file.readAsString(), 'ONE\nTWO\nTWO\n');
  });

  test(
    'rejects oversized edit arguments before building a replacement',
    () async {
      final file = File('${workspace.path}/bounded-edit.txt');
      await file.writeAsString('unchanged');

      final result = await FileToolService.execute('file_edit', {
        'path': 'bounded-edit.txt',
        'old_text': 'unchanged',
        'new_text': 'x' * (FileToolService.maxWriteBytes + 1),
      }, workspace.path);
      expect(result.text, contains('edit text arguments'));
      expect(await file.readAsString(), 'unchanged');
    },
  );

  test('applies a single-file unified patch and preserves CRLF', () async {
    final file = File('${workspace.path}/patch.txt');
    await file.writeAsBytes(utf8.encode('one\r\ntwo\r\nthree\r\n'));
    const patch =
        '--- a/patch.txt\n'
        '+++ b/patch.txt\n'
        '@@ -1,3 +1,3 @@\n'
        ' one\n'
        '-two\n'
        '+TWO\n'
        ' three\n';

    final result = await FileToolService.execute('file_patch', {
      'path': 'patch.txt',
      'patch': patch,
    }, workspace.path);
    expect(result.createdOrModifiedFilePath, isNotNull);
    expect(await file.readAsString(), 'one\r\nTWO\r\nthree\r\n');
  });

  test('does not modify a file when patch context does not match', () async {
    final file = File('${workspace.path}/stale.txt');
    await file.writeAsString('one\ntwo\n');
    const patch =
        '@@ -1,2 +1,2 @@\n'
        ' wrong\n'
        '-two\n'
        '+TWO\n';

    final result = await FileToolService.execute('file_patch', {
      'path': 'stale.txt',
      'patch': patch,
    }, workspace.path);
    expect(result.text, contains('context did not match'));
    expect(await file.readAsString(), 'one\ntwo\n');
  });

  test('preserves unified patch newline metadata in both directions', () async {
    final addNewline = File('${workspace.path}/add-newline.txt');
    await addNewline.writeAsString('old');
    const addNewlinePatch =
        '@@ -1 +1 @@\n'
        '-old\n'
        '\\ No newline at end of file\n'
        '+new\n';
    await FileToolService.execute('file_patch', {
      'path': 'add-newline.txt',
      'patch': addNewlinePatch,
    }, workspace.path);
    expect(await addNewline.readAsString(), 'new\n');

    final removeNewline = File('${workspace.path}/remove-newline.txt');
    await removeNewline.writeAsString('old\n');
    const removeNewlinePatch =
        '@@ -1 +1 @@\n'
        '-old\n'
        '+new\n'
        '\\ No newline at end of file\n';
    await FileToolService.execute('file_patch', {
      'path': 'remove-newline.txt',
      'patch': removeNewlinePatch,
    }, workspace.path);
    expect(await removeNewline.readAsString(), 'new');

    final deleteFinal = File('${workspace.path}/delete-final.txt');
    await deleteFinal.writeAsString('first\nlast');
    const deleteFinalPatch =
        '@@ -2 +1,0 @@\n'
        '-last\n'
        '\\ No newline at end of file\n';
    final deleteFinalResult = await FileToolService.execute('file_patch', {
      'path': 'delete-final.txt',
      'patch': deleteFinalPatch,
    }, workspace.path);
    expect(
      deleteFinalResult.createdOrModifiedFilePath,
      isNotNull,
      reason: deleteFinalResult.text,
    );
    expect(await deleteFinal.readAsString(), 'first\n');
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
