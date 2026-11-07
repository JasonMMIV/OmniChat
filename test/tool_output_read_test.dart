import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/file/file_tool_service.dart';
import 'package:OmniChat/core/services/file/session_outputs.dart';

void main() {
  late Directory root;
  late Directory workspace;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('omnichat_outputs_');
    workspace = await Directory.systemTemp.createTemp('omnichat_workspace_');
    SessionOutputs.debugRootOverride = root;
  });

  tearDown(() async {
    SessionOutputs.debugRootOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('file_read can read a session output', () async {
    final modelPath = await SessionOutputs.externalize(
      conversationId: 'conv',
      toolCallId: 'call',
      content: 'alpha\nbeta',
    );
    final result = await FileToolService.execute(
      'file_read',
      <String, dynamic>{'path': modelPath},
      workspace.path,
      sessionOutputsRoot: root.path,
    );
    expect(result.text, contains('alpha'));
    expect(result.text, contains('beta'));
  });

  test('mutating file tools reject the read-only zone', () async {
    final result = await FileToolService.execute(
      'file_write',
      <String, dynamic>{
        'path': 'tool_outputs/conv/call.txt',
        'content': 'nope',
      },
      workspace.path,
      sessionOutputsRoot: root.path,
    );
    expect(result.text.toLowerCase(), contains('read-only'));
    expect(await File('${root.path}/conv/call.txt').exists(), isFalse);
  });

  test('file_search reports model-facing paths for session outputs', () async {
    final modelPath = await SessionOutputs.externalize(
      conversationId: 'conv',
      toolCallId: 'call',
      content: 'match me',
    );
    final result = await FileToolService.execute(
      'file_search',
      <String, dynamic>{'path': 'tool_outputs/conv', 'pattern': 'call'},
      workspace.path,
      sessionOutputsRoot: root.path,
    );
    expect(result.text, contains(modelPath!));
  });

  test('invalid session path is rejected', () async {
    final result = await FileToolService.execute(
      'file_read',
      <String, dynamic>{'path': 'tool_outputs/../secret.txt'},
      workspace.path,
      sessionOutputsRoot: root.path,
    );
    expect(result.text.toLowerCase(), contains('invalid session-outputs'));
  });
}
