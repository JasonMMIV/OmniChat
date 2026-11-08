import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('omnichat_file_diff_');
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('file_write on a new file reports additions', () async {
    final result = await FileToolService.execute('file_write', {
      'path': 'notes.txt',
      'content': 'alpha\nbeta\n',
    }, workspace.path);

    expect(result.diff, isNotNull);
    expect(result.diff!.addedLines, 2);
    expect(result.diff!.removedLines, 0);
    expect(result.diff!.text, contains('+++ b/notes.txt'));
    expect(result.diff!.text, contains('+alpha'));
  });

  test('file_write over existing text reports both counts', () async {
    await FileToolService.execute('file_write', {
      'path': 'notes.txt',
      'content': 'alpha\nbeta\n',
    }, workspace.path);

    final result = await FileToolService.execute('file_write', {
      'path': 'notes.txt',
      'content': 'alpha\nBETA\n',
    }, workspace.path);

    expect(result.diff!.addedLines, 1);
    expect(result.diff!.removedLines, 1);
    expect(result.diff!.text, contains('-beta'));
    expect(result.diff!.text, contains('+BETA'));
  });

  test('unchanged write has no diff', () async {
    await FileToolService.execute('file_write', {
      'path': 'notes.txt',
      'content': 'same\n',
    }, workspace.path);

    final result = await FileToolService.execute('file_write', {
      'path': 'notes.txt',
      'content': 'same\n',
    }, workspace.path);

    expect(result.diff, isNull);
  });

  test('file_append diffs only the appended lines', () async {
    await FileToolService.execute('file_write', {
      'path': 'log.txt',
      'content': 'one\ntwo\n',
    }, workspace.path);

    final result = await FileToolService.execute('file_append', {
      'path': 'log.txt',
      'content': 'three\n',
    }, workspace.path);

    expect(result.diff!.addedLines, 1);
    expect(result.diff!.removedLines, 0);
    expect(result.diff!.hunks.single.header, '@@ -1,2 +1,3 @@');
    expect(result.diff!.text, contains('+three'));
  });

  test('file_edit diffs the replaced line', () async {
    await FileToolService.execute('file_write', {
      'path': 'edit.txt',
      'content': 'one\ntwo\nthree\n',
    }, workspace.path);

    final result = await FileToolService.execute('file_edit', {
      'path': 'edit.txt',
      'old_text': 'two',
      'new_text': 'TWO',
    }, workspace.path);

    expect(result.diff!.addedLines, 1);
    expect(result.diff!.removedLines, 1);
    expect(result.diff!.text, contains('-two'));
    expect(result.diff!.text, contains('+TWO'));
  });

  test('file_patch diffs the patched line', () async {
    await FileToolService.execute('file_write', {
      'path': 'patch.txt',
      'content': 'one\ntwo\nthree\n',
    }, workspace.path);

    final result = await FileToolService.execute('file_patch', {
      'path': 'patch.txt',
      'patch': '--- a/patch.txt\n'
          '+++ b/patch.txt\n'
          '@@ -1,3 +1,3 @@\n'
          ' one\n'
          '-two\n'
          '+TWO\n'
          ' three\n',
    }, workspace.path);

    expect(result.diff!.addedLines, 1);
    expect(result.diff!.removedLines, 1);
    expect(result.diff!.text, contains('-two'));
    expect(result.diff!.text, contains('+TWO'));
  });

  test('file_delete reports every removed line', () async {
    await FileToolService.execute('file_write', {
      'path': 'gone.txt',
      'content': 'alpha\nbeta\n',
    }, workspace.path);

    final result = await FileToolService.execute('file_delete', {
      'path': 'gone.txt',
    }, workspace.path);

    expect(result.diff!.addedLines, 0);
    expect(result.diff!.removedLines, 2);
    expect(result.diff!.text, contains('-alpha'));
    expect(result.diff!.text, contains('-beta'));
  });

  test('binary files skip the diff instead of failing the tool', () async {
    final file = File('${workspace.path}/blob.bin');
    await file.writeAsBytes(<int>[0, 1, 2, 3]);

    final result = await FileToolService.execute('file_write', {
      'path': 'blob.bin',
      'content': 'now text\n',
    }, workspace.path);

    expect(result.text, contains('Wrote'));
    expect(result.diff, isNull);
  });

  test('writing NUL bytes skips the diff', () async {
    final result = await FileToolService.execute('file_write', {
      'path': 'new-binary.bin',
      'content': 'a\u0000b',
    }, workspace.path);

    expect(result.text, contains('Wrote'));
    expect(result.diff, isNull);
  });
}
