// P1-6 external process governance (CLI v4 §五/§六, internalized).
//
// Rules enforced here:
// - `Process.start()` only — never `Process.run().timeout()` (an unread pipe
//   deadlocks a large-output child; a Future timeout does not kill it).
// - stdout/stderr listeners are attached BEFORE waiting for exit and keep
//   draining after the byte cap (`truncated` is reported, the pipe never
//   blocks).
// - timeout / cancel terminates the whole process tree: Windows Job Object
//   first, `taskkill /T` as fallback (Process.kill() only reaches the direct
//   child); POSIX gets a best-effort child sweep.
// - UTF-8 decoding with `allowMalformed: true` (cp950 console output must
//   never throw or produce mojibake silently).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'windows_job_object.dart';

enum CliShellDialect { cmd, powershell, posix }

/// Cooperative cancellation for one foreground process tree.
class CliCancellationToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

class CliRunSpec {
  const CliRunSpec({
    required this.command,
    required this.workingDirectory,
    this.dialect,
    this.timeout = const Duration(seconds: 900),
    this.environment = const <String, String>{},
    this.includeParentEnvironment = false,
    this.stdoutCapBytes = 24 * 1024,
    this.stderrCapBytes = 6 * 1024,
    this.onStdout,
    this.onStderr,
  });

  final String command;
  final String workingDirectory;
  final CliShellDialect? dialect;
  final Duration timeout;
  final Map<String, String> environment;
  final bool includeParentEnvironment;
  final int stdoutCapBytes;
  final int stderrCapBytes;

  /// Live taps (raw bytes, BEFORE the cap) used by the ToolRun tail.
  final void Function(List<int> chunk)? onStdout;
  final void Function(List<int> chunk)? onStderr;
}

class CliRunResult {
  const CliRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
    this.timedOut = false,
    this.cancelled = false,
    this.interrupted = false,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
  });

  final int? exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;
  final bool timedOut;
  final bool cancelled;
  final bool interrupted;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  bool get truncated => stdoutTruncated || stderrTruncated;
}

class CliProcessSupervisor {
  CliProcessSupervisor._();

  /// Run one command to completion (or timeout/cancel), returning capped
  /// stdout/stderr and structured lifecycle flags. Never throws for a
  /// non-zero exit code; process-start failures propagate to the caller.
  static Future<CliRunResult> run(
    CliRunSpec spec, {
    CliCancellationToken? cancellation,
  }) async {
    final stopwatch = Stopwatch()..start();
    final launched = _resolveLaunch(spec);
    final process = await Process.start(
      launched.executable,
      launched.arguments,
      workingDirectory: spec.workingDirectory,
      environment: spec.environment,
      includeParentEnvironment: spec.includeParentEnvironment,
      runInShell: false,
    );

    final stdoutCollector = _StreamCollector(
      capBytes: spec.stdoutCapBytes,
      onChunk: spec.onStdout,
    );
    final stderrCollector = _StreamCollector(
      capBytes: spec.stderrCapBytes,
      onChunk: spec.onStderr,
    );
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    final stdoutSub = process.stdout.listen(
      stdoutCollector.add,
      onDone: () {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      onError: (Object _) {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      cancelOnError: false,
    );
    final stderrSub = process.stderr.listen(
      stderrCollector.add,
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      onError: (Object _) {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      cancelOnError: false,
    );

    final token = cancellation ?? CliCancellationToken();
    final timeoutCompleter = Completer<void>();
    final timeoutTimer = Timer(spec.timeout, () {
      if (!timeoutCompleter.isCompleted) timeoutCompleter.complete();
    });
    WindowsJobObject? job;
    try {
      if (Platform.isWindows) {
        job = WindowsJobObject.createForProcess(process.pid);
      }

      final outcome = await Future.any<Object>([
        process.exitCode.then<Object>((code) => _ExitOutcome(code)),
        timeoutCompleter.future.then<Object>((_) => const _TimeoutOutcome()),
        token.whenCancelled.then<Object>((_) => const _CancelOutcome()),
      ]);

      var exitCode = outcome is _ExitOutcome ? outcome.exitCode : null;
      final timedOut = outcome is _TimeoutOutcome;
      final cancelled = outcome is _CancelOutcome;
      if (timedOut || cancelled) {
        await _terminateTree(process, job);
        try {
          exitCode = await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          exitCode = null;
        }
      }

      timeoutTimer.cancel();
      // Wait for both pipe readers to observe EOF (bounded: a detached
      // grandchild could keep a pipe open after a failed tree kill).
      await Future.any<Object?>([
        Future.wait<void>([stdoutDone.future, stderrDone.future]),
        Future<void>.delayed(const Duration(seconds: 2)),
      ]);
      await stdoutSub.cancel();
      await stderrSub.cancel();
      stopwatch.stop();

      return CliRunResult(
        exitCode: exitCode,
        stdout: utf8.decode(stdoutCollector.takeBytes(), allowMalformed: true),
        stderr: utf8.decode(stderrCollector.takeBytes(), allowMalformed: true),
        durationMs: stopwatch.elapsedMilliseconds,
        timedOut: timedOut,
        cancelled: cancelled,
        interrupted: exitCode == null && !timedOut && !cancelled,
        stdoutTruncated: stdoutCollector.truncated,
        stderrTruncated: stderrCollector.truncated,
      );
    } finally {
      timeoutTimer.cancel();
      job?.close();
    }
  }

  static Future<void> _terminateTree(
    Process process,
    WindowsJobObject? job,
  ) async {
    var jobTerminated = false;
    if (job != null) {
      try {
        jobTerminated = job.terminate();
      } catch (_) {
        jobTerminated = false;
      }
    }
    if (jobTerminated) return;

    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {}
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', <String>[
          '/F',
          '/T',
          '/PID',
          '${process.pid}',
        ], runInShell: false).timeout(const Duration(seconds: 3));
      } catch (_) {}
    } else {
      try {
        await Process.run('pkill', <String>[
          '-TERM',
          '-P',
          '${process.pid}',
        ]).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  /// Message the agent can act on when a command could not even start
  /// (bad cwd, missing interpreter). Kept as a pure helper for tests.
  static String describeStartFailure(Object error) =>
      'The command could not be started: $error';

  static ({String executable, List<String> arguments}) _resolveLaunch(
    CliRunSpec spec,
  ) {
    final dialect =
        spec.dialect ??
        (Platform.isWindows ? CliShellDialect.cmd : CliShellDialect.posix);
    switch (dialect) {
      case CliShellDialect.cmd:
        final comspec =
            spec.environment['ComSpec'] ??
            Platform.environment['ComSpec'] ??
            r'C:\Windows\System32\cmd.exe';
        return (
          executable: comspec,
          arguments: <String>[
            '/d',
            '/s',
            '/c',
            'chcp 65001 >nul & ${spec.command}',
          ],
        );
      case CliShellDialect.powershell:
        final root =
            spec.environment['SystemRoot'] ??
            Platform.environment['SystemRoot'];
        final executable = (root == null || root.trim().isEmpty)
            ? 'powershell.exe'
            : '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        return (
          executable: executable,
          arguments: <String>[
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
                '${spec.command}',
          ],
        );
      case CliShellDialect.posix:
        return (executable: '/bin/sh', arguments: <String>['-c', spec.command]);
    }
  }
}

class _StreamCollector {
  _StreamCollector({required this.capBytes, this.onChunk});

  final int capBytes;
  final void Function(List<int> chunk)? onChunk;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _kept = 0;
  bool truncated = false;

  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    onChunk?.call(chunk);
    final room = capBytes - _kept;
    if (room <= 0) {
      truncated = true;
      return;
    }
    if (chunk.length <= room) {
      _builder.add(chunk);
      _kept += chunk.length;
    } else {
      _builder.add(chunk.sublist(0, room));
      _kept += room;
      truncated = true;
    }
  }

  List<int> takeBytes() => _builder.takeBytes();
}

class _ExitOutcome {
  const _ExitOutcome(this.exitCode);

  final int exitCode;
}

class _TimeoutOutcome {
  const _TimeoutOutcome();
}

class _CancelOutcome {
  const _CancelOutcome();
}
