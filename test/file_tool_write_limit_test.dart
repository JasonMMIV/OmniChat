import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'omnichat_file_write_limit_',
    );
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('file_write no longer enforces the old 512 KB ceiling', () async {
    final content = 'x' * (3 * 1024 * 1024);
    final result = await FileToolService.execute('file_write', {
      'path': 'large.txt',
      'content': content,
    }, workspace.path);

    expect(result.text, contains('Wrote'));
    final file = File('${workspace.path}/large.txt');
    expect(await file.length(), utf8.encode(content).length);
  });

  test('file_append can grow past the old 2 MB ceiling', () async {
    final file = File('${workspace.path}/append.txt');
    await file.writeAsString('x' * (2 * 1024 * 1024));

    final result = await FileToolService.execute('file_append', {
      'path': 'append.txt',
      'content': 'y' * (2 * 1024 * 1024),
    }, workspace.path);

    expect(result.text, contains('Appended'));
    expect(await file.length(), 4 * 1024 * 1024);
  });
}
