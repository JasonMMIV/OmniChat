import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/shell/cli_process_supervisor.dart';
import 'package:OmniChat/core/services/shell/shell_run_service.dart';

void main() {
  final dialect = Platform.isWindows
      ? CliShellDialect.cmd
      : CliShellDialect.posix;

  CliRunSpec spec(
    String command, {
    Duration? timeout = const Duration(seconds: 20),
    int stdoutCapBytes = 24 * 1024,
    Map<String, String>? environment,
  }) {
    return CliRunSpec(
      command: command,
      workingDirectory: Directory.current.path,
      dialect: dialect,
      timeout: timeout,
      environment: environment ?? ShellRunService.buildEnvironment(),
      includeParentEnvironment: false,
      stdoutCapBytes: stdoutCapBytes,
    );
  }

  test('captures stdout, stderr and the exit code', () async {
    final result = await CliProcessSupervisor.run(
      spec('echo hello && echo oops 1>&2'),
    );
    expect(result.exitCode, 0);
    expect(result.stdout, contains('hello'));
    expect(result.stderr, contains('oops'));
    expect(result.timedOut, isFalse);
    expect(result.cancelled, isFalse);
  });

  test('reports a non-zero exit code without throwing', () async {
    final result = await CliProcessSupervisor.run(
      spec(Platform.isWindows ? 'exit /b 7' : 'exit 7'),
    );
    expect(result.exitCode, 7);
  });

  test('caps stdout but keeps draining a large pipe', () async {
    final command = Platform.isWindows
        ? 'for /L %i in (1,1,2000) do @echo '
              '0123456789012345678901234567890123456789'
        : 'yes 0123456789012345678901234567890123456789 | head -n 2000';
    final result = await CliProcessSupervisor.run(
      spec(command, stdoutCapBytes: 1024),
    );
    expect(result.stdoutTruncated, isTrue);
    expect(utf8.encode(result.stdout).length, lessThanOrEqualTo(1024));
  });

  test('timeout terminates the whole process tree', () async {
    final command = Platform.isWindows ? 'ping -n 6 127.0.0.1 >nul' : 'sleep 5';
    final stopwatch = Stopwatch()..start();
    final result = await CliProcessSupervisor.run(
      spec(command, timeout: const Duration(milliseconds: 300)),
    );
    stopwatch.stop();
    expect(result.timedOut, isTrue);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
  });

  test('a null timeout has no wall-clock deadline', () async {
    final command = Platform.isWindows
        ? 'ping -n 10 127.0.0.1 >nul'
        : 'sleep 10';
    final token = CliCancellationToken();
    final future = CliProcessSupervisor.run(
      spec(command, timeout: null),
      cancellation: token,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    token.cancel();
    final result = await future;
    expect(result.cancelled, isTrue);
    expect(result.timedOut, isFalse);
  });

  test('cancellation terminates the run and reports it', () async {
    final command = Platform.isWindows
        ? 'ping -n 10 127.0.0.1 >nul'
        : 'sleep 10';
    final token = CliCancellationToken();
    final future = CliProcessSupervisor.run(
      spec(command, timeout: const Duration(seconds: 30)),
      cancellation: token,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    token.cancel();
    final result = await future;
    expect(result.cancelled, isTrue);
    expect(result.timedOut, isFalse);
  });

  test('uses only the supplied environment', () async {
    final environment = Map<String, String>.of(
      ShellRunService.buildEnvironment(),
    )..['OMNICHAT_TEST_FLAG'] = 'abc';
    final command = Platform.isWindows
        ? 'echo %OMNICHAT_TEST_FLAG%'
        : 'echo "\$OMNICHAT_TEST_FLAG"';
    final result = await CliProcessSupervisor.run(
      spec(command, environment: environment),
    );
    expect(result.stdout, contains('abc'));
  });
}
