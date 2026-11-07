import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:OmniChat/core/services/file/session_outputs.dart';
import 'package:OmniChat/core/services/shell/cli_process_supervisor.dart';
import 'package:OmniChat/core/services/shell/shell_run_service.dart';

void main() {
  late Directory workspace;
  late Directory outputs;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('omnichat_shell_ws_');
    outputs = await Directory.systemTemp.createTemp('omnichat_shell_out_');
    SessionOutputs.debugRootOverride = outputs;
  });

  tearDown(() async {
    SessionOutputs.debugRootOverride = null;
    if (await workspace.exists()) await workspace.delete(recursive: true);
    if (await outputs.exists()) await outputs.delete(recursive: true);
  });

  Future<Map<String, dynamic>> run(
    String command, {
    List<String> allowlist = const <String>['echo'],
    String? cwd,
    int? timeoutSeconds,
    bool strictMode = false,
    String? approvedCommand,
    bool developerMode = true,
    String? conversationId,
    String? toolCallId,
    String? workspacePath,
    CliCancellationToken? cancellation,
  }) async {
    final raw = await ShellRunService.execute(
      <String, dynamic>{
        'command': command,
        if (cwd != null) 'cwd': cwd,
        if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
      },
      workspacePath: workspacePath ?? workspace.path,
      developerMode: developerMode,
      allowlist: allowlist,
      strictMode: strictMode,
      approvedCommand: approvedCommand,
      conversationId: conversationId,
      toolCallId: toolCallId,
      cancellation: cancellation,
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  test('developer mode off refuses execution', () async {
    final payload = await run('echo hello', developerMode: false);
    expect(payload['type'], 'tool_error');
    expect(payload['error'], 'developer_mode_disabled');
  });

  test('non-allowlisted commands require approval', () async {
    final payload = await run('curl https://example.com');
    expect(payload['type'], 'tool_error');
    expect(payload['error'], 'approval_required');
    expect(payload['blocked_programs'], contains('curl'));
  });

  test('strict mode denies instead of asking', () async {
    final payload = await run('curl https://example.com', strictMode: true);
    expect(payload['error'], 'approval_denied');
  });

  test('runs an allowlisted command and returns structured fields', () async {
    final payload = await run('echo hello');
    expect(payload['exit_code'], 0);
    expect(payload['stdout'].toString(), contains('hello'));
    expect(payload['timed_out'], isFalse);
    expect(payload['changed_files'], isA<List<dynamic>>());
    expect(payload['cwd'], '.');
  });

  test('reports changed files after a command', () async {
    final payload = await run(
      Platform.isWindows
          ? 'echo hello> created.txt'
          : 'echo hello > created.txt',
    );
    expect(payload['exit_code'], 0);
    expect(payload['changed_files'], contains('created.txt'));
  });

  test('rejects cwd escapes', () async {
    expect((await run('echo hello', cwd: '..'))['error'], 'invalid_cwd');
    expect(
      (await run('echo hello', cwd: Directory.current.path))['error'],
      'invalid_cwd',
    );
    expect(ShellRunService.resolveCwd('..', workspace.path), isNull);
  });

  test('rejects a cwd symlink that resolves outside the workspace', () async {
    final outside = await Directory.systemTemp.createTemp(
      'omnichat_shell_outside_',
    );
    final link = Link(p.join(workspace.path, 'outside-link'));
    try {
      await link.create(outside.path);
    } catch (_) {
      // Windows may disallow symlink creation without Developer Mode; the
      // lexical check is still covered by the preceding test.
      await outside.delete(recursive: true);
      return;
    }
    addTearDown(() async {
      if (await link.exists()) await link.delete();
      if (await outside.exists()) await outside.delete(recursive: true);
    });

    expect(ShellRunService.resolveCwd('outside-link', workspace.path), isNull);
  });

  test('externalizes output over 32 KB and keeps 4 KB previews', () async {
    final command = Platform.isWindows
        ? 'for /L %i in (1,1,1000) do @echo '
              '0123456789012345678901234567890123456789'
        : 'yes 0123456789012345678901234567890123456789 | head -n 1000';
    final allowlist = Platform.isWindows
        ? const <String>['for']
        : const <String>['yes', 'head'];
    final payload = await run(
      command,
      allowlist: allowlist,
      conversationId: 'conv',
      toolCallId: 'call',
    );
    expect(payload['truncated'], isTrue);
    expect(payload['output_file'], startsWith('tool_outputs/'));
    expect(payload['stdout_preview'], isNotNull);
    expect(payload.containsKey('stdout'), isFalse);
    final resolved = await SessionOutputs.resolveReadPath(
      payload['output_file'].toString(),
    );
    expect(resolved, isNotNull);
    expect(
      await File(resolved!.absolutePath).length(),
      greaterThan(SessionOutputs.externalizeThresholdBytes),
    );
  });

  test(
    'an approved command cannot be reused for a different command',
    () async {
      final payload = await run(
        'curl https://example.com',
        approvedCommand: 'echo hello',
      );
      expect(payload['type'], 'tool_error');
      expect(payload['error'], 'approval_required');
    },
  );

  test('redacts secret-shaped output', () async {
    final payload = await run('echo password=hunter2');
    final stdout = payload['stdout'].toString();
    expect(stdout, contains('password=***'));
    expect(stdout, isNot(contains('hunter2')));
  });

  test('readiness requires developer mode and a PATH-available program', () {
    ShellRunService.debugAvailabilityOverride = <String, bool>{
      'git': true,
      'curl': false,
    };
    addTearDown(() => ShellRunService.debugAvailabilityOverride = null);

    expect(
      ShellRunService.isReady(developerMode: true, allowlist: const ['git']),
      isTrue,
    );
    expect(
      ShellRunService.isReady(developerMode: true, allowlist: const ['curl']),
      isFalse,
    );
    expect(
      ShellRunService.isReady(developerMode: false, allowlist: const ['git']),
      isFalse,
    );
    expect(
      ShellRunService.isReady(developerMode: true, allowlist: const []),
      isTrue,
    );
  });

  test('cancellation terminates the command and is reported', () async {
    final command = Platform.isWindows
        ? 'ping -n 10 127.0.0.1 >nul'
        : 'sleep 10';
    final allowlist = Platform.isWindows
        ? const <String>['ping']
        : const <String>['sleep'];
    final token = CliCancellationToken();
    final future = run(
      command,
      allowlist: allowlist,
      timeoutSeconds: 30,
      cancellation: token,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    token.cancel();
    final payload = await future;
    expect(payload['cancelled'], isTrue);
    expect(payload['timed_out'], isFalse);
    expect(payload['hint'], contains('cancelled'));
  });

  test('timeout is reported and clamped', () async {
    final command = Platform.isWindows ? 'ping -n 6 127.0.0.1 >nul' : 'sleep 5';
    final allowlist = Platform.isWindows
        ? const <String>['ping']
        : const <String>['sleep'];
    final payload = await run(command, allowlist: allowlist, timeoutSeconds: 1);
    expect(payload['timed_out'], isTrue);
    expect(payload['hint'], isNotNull);

    expect(ShellRunService.parseTimeoutSeconds(null), 900);
    expect(ShellRunService.parseTimeoutSeconds(0), 1);
    expect(ShellRunService.parseTimeoutSeconds(99999), 3600);
  });
}
