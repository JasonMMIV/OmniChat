// Desktop-only `shell_run` command execution.
//
// The handler decides whether a command needs an approval card (the global
// "shell commands: allow all / ask" switch); this service re-checks the
// approved command and owns the execution contract:
// - workspace-scoped cwd (`..` / absolute host paths rejected);
// - timeout 1–600 s (default 30), or -1 for no timeout, enforced by the
//   process supervisor, which kills the whole process tree on timeout/cancel;
// - minimal environment allowlist + agent-friendly flags;
// - structured payload (exit_code / duration / timed_out / cancelled /
//   truncated / changed_files);
// - stdout+stderr > 64 KB externalized to the app-private read-only
//   `tool_outputs/` zone, with 8 KB previews and retention;
// - output capped at the shell tool-result budget (68 KB).
//
// Android does not advertise this tool; it has a separate foreground
// `shell_exec` backend in `shell/android/android_shell_service.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../file/session_outputs.dart';
import '../tools/tool_result_caps.dart';
import 'changed_files.dart';
import 'cli_process_supervisor.dart';
import 'tool_run_registry.dart';

class ShellRunService {
  ShellRunService._();

  static const String toolName = 'shell_run';
  static const int defaultTimeoutSeconds = 30;
  static const int maxTimeoutSeconds = 600;
  static const int noTimeoutSeconds = -1;
  // Capture caps must stay above [SessionOutputs.externalizeThresholdBytes],
  // otherwise a >64 KB output can never reach the externalization branch.
  // The serialized tool result is still capped by `ToolResultCaps` (68 KB),
  // so a larger capture does not inflate the model-facing payload.
  static const int maxStdoutBytes = 1024 * 1024;
  static const int maxStderrBytes = 256 * 1024;

  static bool get isPlatformSupported {
    try {
      return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> getToolDefinition() {
    return <String, dynamic>{
      'type': 'function',
      'function': {
        'name': toolName,
        'description':
            'Run one shell command on the desktop in the selected workspace. '
            'Use it for builds, tests, formatters, git and package managers. '
            'Commands start in the selected workspace. This is NOT a security '
            'sandbox: the command runs with your user permissions. The user may '
            'require approval for each command. Prefer non-interactive commands; '
            'interactive prompts will hang until the timeout (or indefinitely '
            'when timeout_seconds is -1). Android does not support this tool.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description':
                  'The command line to run. Compound commands are allowed.',
            },
            'cwd': {
              'type': 'string',
              'description':
                  'Optional working directory relative to the workspace root. '
                  'Defaults to the workspace root. Absolute paths and ".." are rejected.',
            },
            'timeout_seconds': {
              'type': 'integer',
              'description':
                  'Optional timeout in seconds (default $defaultTimeoutSeconds; '
                  'values above $maxTimeoutSeconds are clamped). '
                  'Set -1 to wait indefinitely.',
              'default': defaultTimeoutSeconds,
              'minimum': -1,
              'maximum': maxTimeoutSeconds,
            },
          },
          'required': ['command'],
        },
      },
    };
  }

  /// Execute one command. Returns the structured JSON string handed to the
  /// model. [approvedCommand] carries the exact command the user approved on
  /// the resume path; any different command is re-classified.
  static Future<String> execute(
    Map<String, dynamic> args, {
    required String workspacePath,
    bool allowAll = false,
    String? conversationId,
    String? toolCallId,
    String? approvedCommand,
    CliCancellationToken? cancellation,
  }) async {
    if (!isPlatformSupported) {
      return _error(
        'unsupported_platform',
        'shell_run is only available on desktop platforms.',
      );
    }

    final command = (args['command'] ?? '').toString().trim();
    if (command.isEmpty) {
      return _error(
        'empty_command',
        'The command argument is required and must not be empty.',
      );
    }

    final approved =
        approvedCommand != null && approvedCommand.trim() == command.trim();
    if (!allowAll && !approved) {
      return _error(
        'approval_required',
        'This command requires user approval. Ask the user to approve it '
            'before running it again.',
        extra: <String, dynamic>{'command': command},
      );
    }

    final workspaceRoot = _canonicalDirectory(workspacePath);
    if (workspaceRoot == null) {
      return _error(
        'workspace_unavailable',
        'The workspace directory does not exist or is unavailable.',
      );
    }
    final cwd = resolveCwd(args['cwd'], workspaceRoot);
    if (cwd == null) {
      return _error(
        'invalid_cwd',
        'The cwd must be a directory inside the workspace (absolute paths '
            'and ".." are rejected).',
      );
    }

    final timeoutSeconds = parseTimeoutSeconds(args['timeout_seconds']);
    final run =
        (conversationId != null &&
            conversationId.trim().isNotEmpty &&
            toolCallId != null &&
            toolCallId.trim().isNotEmpty)
        ? ToolRunRegistry.instance.start(
            conversationId: conversationId,
            toolCallId: toolCallId,
          )
        : null;

    // Approximate audit: snapshot before/after the command (memory-only).
    WorkspaceSnapshot? before;
    try {
      before = await WorkspaceSnapshot.capture(workspaceRoot);
    } catch (_) {}

    CliRunResult result;
    try {
      result = await CliProcessSupervisor.run(
        CliRunSpec(
          command: command,
          workingDirectory: cwd,
          dialect: Platform.isWindows
              ? CliShellDialect.cmd
              : CliShellDialect.posix,
          timeout: timeoutSeconds == noTimeoutSeconds
              ? null
              : Duration(seconds: timeoutSeconds),
          environment: buildEnvironment(),
          includeParentEnvironment: false,
          stdoutCapBytes: maxStdoutBytes,
          stderrCapBytes: maxStderrBytes,
          onStdout: run?.addStdout,
          onStderr: run?.addStderr,
        ),
        cancellation: cancellation,
      );
    } catch (error) {
      run?.finish();
      return _error(
        'execution_error',
        CliProcessSupervisor.describeStartFailure(error),
        extra: <String, dynamic>{'command': command},
      );
    } finally {
      run?.finish();
    }

    WorkspaceSnapshot? after;
    try {
      after = await WorkspaceSnapshot.capture(workspaceRoot);
    } catch (_) {}
    final changed = (before != null && after != null)
        ? diffWorkspaceSnapshots(before, after)
        : const ChangedFilesResult.empty();

    final stdout = redactSecrets(stripAnsi(result.stdout));
    final stderr = redactSecrets(stripAnsi(result.stderr));
    final totalBytes = utf8.encode(stdout).length + utf8.encode(stderr).length;
    final overBudget = totalBytes > SessionOutputs.externalizeThresholdBytes;

    String? outputFile;
    if (overBudget &&
        conversationId != null &&
        conversationId.trim().isNotEmpty &&
        toolCallId != null &&
        toolCallId.trim().isNotEmpty) {
      outputFile = await SessionOutputs.externalize(
        conversationId: conversationId,
        toolCallId: toolCallId,
        content:
            'Command: ${redactSecrets(command)}\n'
            'Exit code: ${result.exitCode}\n\n'
            '--- stdout ---\n$stdout\n\n'
            '--- stderr ---\n$stderr\n',
      );
    }

    final displayCwd = p
        .relative(cwd, from: workspaceRoot)
        .replaceAll('\\', '/');

    final payload = <String, dynamic>{
      'command': command,
      'cwd': displayCwd,
      'exit_code': result.exitCode,
      'duration_ms': result.durationMs,
      'timed_out': result.timedOut,
      'cancelled': result.cancelled,
      'interrupted': result.interrupted,
      'truncated': result.truncated || overBudget,
      'stdout_truncated': result.stdoutTruncated,
      'stderr_truncated': result.stderrTruncated,
      if (outputFile != null) 'output_file': outputFile,
      if (outputFile != null)
        'output_note':
            'Full output is stored outside the workspace in the read-only '
            'session-outputs file named above. Read it with file_read(path: '
            'output_file) or file_search(path: output_file); both are read-only '
            'there.',
      if (overBudget) ...<String, dynamic>{
        'stdout_preview': SessionOutputs.preview(stdout),
        'stderr_preview': SessionOutputs.preview(stderr),
      } else ...<String, dynamic>{'stdout': stdout, 'stderr': stderr},
      'changed_files': changed.paths,
      'deleted_files': changed.deleted,
      'changed_files_truncated': changed.truncated,
      if (result.timedOut && timeoutSeconds > 0)
        'hint':
            'The command exceeded ${timeoutSeconds}s and its process tree was '
            'terminated. Re-run with a larger timeout_seconds or a more focused command.',
      if (result.cancelled)
        'hint':
            'The command was cancelled by the user and its process tree was '
            'terminated.',
    };

    return ToolResultCaps.cap(toolName: toolName, result: jsonEncode(payload));
  }

  /// Working directory resolution: workspace-relative only, existing
  /// directory required. Returns null for any escape.
  static String? resolveCwd(Object? raw, String workspaceRoot) {
    final text = (raw ?? '').toString().trim();
    final root = _canonicalDirectory(workspaceRoot);
    if (root == null) return null;
    if (text.isEmpty) return root;
    if (p.isAbsolute(text) || p.rootPrefix(text).isNotEmpty) return null;
    final candidate = p.normalize(p.join(root, text));
    if (!_isWithin(candidate, root)) return null;
    if (FileSystemEntity.typeSync(candidate, followLinks: true) !=
        FileSystemEntityType.directory) {
      return null;
    }
    try {
      // Lexical containment is not enough: a directory symlink inside the
      // workspace may point outside it. Start the process at the canonical
      // target only after re-checking the real path.
      final resolved = Directory(candidate).resolveSymbolicLinksSync();
      if (!_isWithin(resolved, root)) return null;
      return resolved;
    } catch (_) {
      return null;
    }
  }

  static int parseTimeoutSeconds(Object? raw) {
    final value = raw is num ? raw : int.tryParse(raw?.toString().trim() ?? '');
    if (value == null || !value.isFinite) return defaultTimeoutSeconds;
    if (value == noTimeoutSeconds) return noTimeoutSeconds;
    if (value <= 0) return defaultTimeoutSeconds;
    return value.clamp(1, maxTimeoutSeconds).toInt();
  }

  /// Minimal environment: explicit allowlist, never the parent environment
  /// wholesale. Agent-friendly flags keep pager/colour/interactive prompts
  /// from corrupting captured output.
  static Map<String, String> buildEnvironment() {
    const keys = <String>[
      'SystemRoot',
      'ComSpec',
      'TEMP',
      'TMP',
      'PATH',
      'PATHEXT',
      'SystemDrive',
      'WINDIR',
      'USERPROFILE',
      'LOCALAPPDATA',
      'APPDATA',
      'HOME',
      'SHELL',
    ];
    final environment = <String, String>{};
    for (final key in keys) {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) environment[key] = value;
    }
    environment.addAll(<String, String>{
      'NO_COLOR': '1',
      'CI': 'true',
      'PAGER': 'cat',
      'TERM': 'dumb',
      'LANG': 'C.UTF-8',
    });
    return environment;
  }

  static String _error(
    String code,
    String message, {
    Map<String, dynamic>? extra,
  }) {
    return jsonEncode(<String, dynamic>{
      'type': 'tool_error',
      'error': code,
      'message': message,
      'tool': toolName,
      ...?extra,
    });
  }

  static final RegExp _csi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
  static final RegExp _osc = RegExp(r'\x1B\][^\x07\x1B]*(\x07|\x1B\\)');
  static final RegExp _assignmentSecret = RegExp(
    r'\b(api[_-]?key|access[_-]?token|auth[_-]?token|secret|password)'
    r'(\s*[:=]\s*)([^\s"'
    ']+)',
    caseSensitive: false,
  );
  static final RegExp _bearerSecret = RegExp(
    r'\bbearer\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final RegExp _prefixSecret = RegExp(
    r'\b(?:sk|ghp|gho|ghu|ghs|xox[baprs])[-_][A-Za-z0-9._-]{8,}',
  );

  /// Shared by desktop and Android shell backends: strip terminal control
  /// sequences first, then redact obvious credentials.
  static String stripAnsiAndRedact(String text) =>
      redactSecrets(stripAnsi(text));

  static String stripAnsi(String text) {
    var out = text.replaceAll(_osc, '');
    out = out.replaceAll(_csi, '');
    return out;
  }

  static String redactSecrets(String text) {
    var out = text.replaceAllMapped(
      _assignmentSecret,
      (match) => '${match.group(1)}${match.group(2)}***',
    );
    out = out.replaceAllMapped(_bearerSecret, (_) => 'Bearer ***');
    out = out.replaceAllMapped(_prefixSecret, (_) => '***');
    return out;
  }

  static String? _canonicalDirectory(String path) {
    try {
      final directory = Directory(path);
      if (!directory.existsSync()) return null;
      return directory.resolveSymbolicLinksSync();
    } catch (_) {
      return null;
    }
  }

  static bool _isWithin(String candidate, String root) {
    String comparable(String value) {
      final normalized = p.normalize(value).replaceAll('\\', '/');
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final child = comparable(candidate);
    final parent = comparable(root).replaceFirst(RegExp(r'/+$'), '');
    return child == parent || child.startsWith('$parent/');
  }
}
