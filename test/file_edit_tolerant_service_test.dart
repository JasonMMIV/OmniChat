import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';

/// Service-level coverage for the tolerant `file_edit` ladder (Cowork P1-8).
/// The strategy ladder itself is covered in `edit_matchers_test.dart`; these
/// tests lock the tool contract: fallback, matcher label, ambiguity, guidance.
void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('omnichat_edit_match_');
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('falls back to line matching when indentation drifted', () async {
    final file = File('${workspace.path}/tolerant.dart');
    await file.writeAsString('class A {\n  void run() {\n    go();\n  }\n}\n');

    final result = await FileToolService.execute('file_edit', {
      'path': 'tolerant.dart',
      'old_text': 'void run() {\n  go();\n}',
      'new_text': 'void run() {\n  stop();\n}',
    }, workspace.path);

    expect(result.text, contains('Edited tolerant.dart'));
    expect(result.text, contains('matcher: line_trimmed'));
    expect(
      await file.readAsString(),
      'class A {\n  void run() {\n    stop();\n  }\n}\n',
    );
  });

  test('reports the exact matcher on a normal edit', () async {
    final file = File('${workspace.path}/exact.txt');
    await file.writeAsString('alpha\nbeta\n');

    final result = await FileToolService.execute('file_edit', {
      'path': 'exact.txt',
      'old_text': 'beta',
      'new_text': 'gamma',
    }, workspace.path);

    expect(result.text, contains('matcher: exact'));
    expect(await file.readAsString(), 'alpha\ngamma\n');
  });

  test('block_anchor replaces a drifted middle and says so', () async {
    final file = File('${workspace.path}/anchor.txt');
    await file.writeAsString('start\nactual middle\nend\ntail\n');

    final result = await FileToolService.execute('file_edit', {
      'path': 'anchor.txt',
      'old_text': 'start\ndrifted middle\nend',
      'new_text': 'start\nreplaced\nend',
    }, workspace.path);

    expect(result.text, contains('matcher: block_anchor'));
    expect(await file.readAsString(), 'start\nreplaced\nend\ntail\n');
  });

  test('ambiguous tolerant matches name the strategy and the count', () async {
    final file = File('${workspace.path}/amb.txt');
    await file.writeAsString('  dup\n  dup\n  dup\n  dup\n');

    final result = await FileToolService.execute('file_edit', {
      'path': 'amb.txt',
      'old_text': 'dup\ndup',
      'new_text': 'x',
    }, workspace.path);

    expect(result.text, contains('matched 2 times'));
    expect(result.text, contains('matcher: line_trimmed'));
    expect(await file.readAsString(), '  dup\n  dup\n  dup\n  dup\n');
  });

  test(
    'replace_all rewrites every tolerant window with re-indentation',
    () async {
      final file = File('${workspace.path}/all.txt');
      await file.writeAsString('  dup\n  dup\n  dup\n  dup\n');

      final result = await FileToolService.execute('file_edit', {
        'path': 'all.txt',
        'old_text': 'dup\ndup',
        'new_text': 'x\ny',
        'replace_all': true,
      }, workspace.path);

      expect(result.text, contains('matcher: line_trimmed'));
      expect(await file.readAsString(), '  x\n  y\n  x\n  y\n');
    },
  );

  test('a miss points the model back at file_read', () async {
    final file = File('${workspace.path}/miss.txt');
    await file.writeAsString('alpha\n');

    final result = await FileToolService.execute('file_edit', {
      'path': 'miss.txt',
      'old_text': 'never present',
      'new_text': 'x',
    }, workspace.path);

    expect(result.text, contains('was not found'));
    expect(result.text, contains('file_read'));
    expect(await file.readAsString(), 'alpha\n');
  });

  test('large tolerant edits are allowed', () async {
    final file = File('${workspace.path}/large-edit.txt');
    await file.writeAsString('alpha\nbeta\n');

    final result = await FileToolService.execute('file_edit', {
      'path': 'large-edit.txt',
      'old_text': 'beta',
      'new_text': 'x' * (600 * 1024),
    }, workspace.path);

    expect(result.text, contains('Edited'));
    expect(await file.length(), greaterThan(600 * 1024));
  });
}
