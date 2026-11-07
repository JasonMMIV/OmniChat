import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/core/services/file/session_outputs.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('omnichat_session_outputs_');
    SessionOutputs.debugRootOverride = root;
  });

  tearDown(() async {
    SessionOutputs.debugRootOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('externalizes and resolves a model path', () async {
    final modelPath = await SessionOutputs.externalize(
      conversationId: 'conv 1',
      toolCallId: 'call/1',
      content: 'line one\nline two',
    );
    expect(modelPath, 'tool_outputs/conv_1/call_1.txt');
    final resolved = await SessionOutputs.resolveReadPath(modelPath!);
    expect(resolved, isNotNull);
    expect(
      await File(resolved!.absolutePath).readAsString(),
      contains('line one'),
    );
  });

  test('rejects traversal and absolute paths', () {
    expect(
      SessionOutputs.resolveFromRoot('tool_outputs/../secret.txt', root.path),
      isNull,
    );
    expect(
      SessionOutputs.resolveFromRoot(
        'tool_outputs/a/../../secret.txt',
        root.path,
      ),
      isNull,
    );
    expect(SessionOutputs.resolveFromRoot(r'C:\secret.txt', root.path), isNull);
    expect(SessionOutputs.resolveFromRoot('tool_outputs', root.path), isNull);
  });

  test('preview never splits a UTF-8 code point', () {
    final text = '中' * 500;
    final preview = SessionOutputs.preview(text, maxBytes: 31);
    final marker = preview.indexOf('\n[');
    expect(marker, greaterThan(0));
    final kept = preview.substring(0, marker);
    expect(utf8.encode(kept).length, lessThanOrEqualTo(31));
    expect(kept.contains('\uFFFD'), isFalse);
  });

  test('sweep drops expired files and keeps the newest 20', () async {
    final directory = Directory(p.join(root.path, 'conv'));
    await directory.create(recursive: true);
    final now = DateTime.now();
    for (var i = 0; i < 25; i++) {
      final file = File(p.join(directory.path, 'f$i.txt'));
      await file.writeAsString('$i');
      await file.setLastModified(now.subtract(Duration(hours: i)));
    }
    final expired = File(p.join(directory.path, 'expired.txt'));
    await expired.writeAsString('old');
    await expired.setLastModified(now.subtract(const Duration(days: 8)));

    await SessionOutputs.sweep('conv');

    final files = await directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    expect(files.length, SessionOutputs.maxFilesPerConversation);
    expect(await expired.exists(), isFalse);
    expect(await File(p.join(directory.path, 'f0.txt')).exists(), isTrue);
  });

  test('clearAll removes the whole output zone', () async {
    await SessionOutputs.externalize(
      conversationId: 'conv',
      toolCallId: 'call',
      content: 'x',
    );
    await SessionOutputs.clearAll();
    expect(await root.exists(), isFalse);
  });

  test('deleteConversation removes the whole output directory', () async {
    await SessionOutputs.externalize(
      conversationId: 'conv',
      toolCallId: 'call',
      content: 'x',
    );
    await SessionOutputs.deleteConversation('conv');
    expect(await Directory(p.join(root.path, 'conv')).exists(), isFalse);
  });
}
