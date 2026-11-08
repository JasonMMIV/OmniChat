import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'omnichat_file_limits_',
    );
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('default mode keeps the 512 KB write hard floor', () async {
    final result = await FileToolService.execute('file_write', {
      'path': 'too-large.txt',
      'content': 'x' * (FileToolService.maxWriteBytes + 1),
    }, workspace.path);

    expect(result.text, contains('512 KB'));
    expect(File('${workspace.path}/too-large.txt').existsSync(), isFalse);
  });

  test('developer mode allows a 600 KB write', () async {
    final content = 'x' * (600 * 1024);
    final result = await FileToolService.execute('file_write', {
      'path': 'large.txt',
      'content': content,
    }, workspace.path, developerMode: true);

    expect(result.text, contains('Wrote'));
    final file = File('${workspace.path}/large.txt');
    expect(await file.length(), utf8.encode(content).length);
  });

  test('developer mode still enforces the 2 MB ceiling', () async {
    final result = await FileToolService.execute('file_write', {
      'path': 'too-large.txt',
      'content': 'x' * (FileToolService.developerMaxWriteBytes + 1),
    }, workspace.path, developerMode: true);

    expect(result.text, contains('2 MB'));
    expect(File('${workspace.path}/too-large.txt').existsSync(), isFalse);
  });

  test('developer mode raises the append ceiling without bypassing it', () async {
    final file = File('${workspace.path}/append.txt');
    await file.writeAsString('x' * (600 * 1024));

    final allowed = await FileToolService.execute('file_append', {
      'path': 'append.txt',
      'content': 'y' * (600 * 1024),
    }, workspace.path, developerMode: true);
    expect(allowed.text, contains('Appended'));
    expect(await file.length(), 1200 * 1024);

    final rejected = await FileToolService.execute('file_append', {
      'path': 'append.txt',
      'content': 'z' * (FileToolService.developerMaxWriteBytes),
    }, workspace.path, developerMode: true);
    expect(rejected.text, contains('2 MB'));
    expect(await file.length(), 1200 * 1024);
  });
}
