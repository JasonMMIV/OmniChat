// P1-6: `shell_run` — desktop-only, developer-mode-gated command execution.
//
// Policy is classified by ShellPolicy before execution (handler layer); this
// service re-checks as defense in depth and owns the execution contract:
// - workspace-scoped cwd (`..` / absolute host paths rejected);
// - timeout 1–3600 s (default 900) enforced by the process supervisor, which
//   kills the whole process tree;
// - minimal environment allowlist + agent-friendly flags;
// - structured payload (exit_code / duration / timed_out / cancelled /
//   truncated / changed_files);
// - stdout+stderr > 32 KB externalized to the app-private read-only
//   `tool_outputs/` zone, with 4 KB previews and retention;
// - output capped at the 32,768-character tool-result budget.
//
// Android never advertises this tool (isPlatformSupported is false there).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../file/session_outputs.dart';
import '../tools/tool_result_caps.dart';
import 'changed_files.dart';
import 'cli_process_supervisor.dart';
import 'shell_policy.dart';
import 'tool_run_registry.dart';

class ShellRunService {
  ShellRunService._();

  static const String toolName = 'shell_run';
  static const int defaultTimeoutSeconds = 900;
  static const int maxTimeoutSeconds = 3600;
  // Capture caps must stay above [SessionOutputs.externalizeThresholdBytes],
  // otherwise a >32 KB output can never reach the externalization branch.
  // The serialized tool result is still capped by `ToolResultCaps` (32,768
  // chars), so a larger capture does not inflate the model-facing payload.
  static const int maxStdoutBytes = 1024 * 1024;
  static const int maxStderrBytes = 256 * 1024;

  /// Test seam for PATH probing (null = real filesystem probe).
  @visibleForTesting
  static Map<String, bool>? debugAvailabilityOverride;

  static Map<String, bool>? _probeCache;
  static String? _probeKey;
  static DateTime? _probeAt;

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
            'sandbox: the command runs with your user permissions. Commands '
            'outside the allowlist require user approval. Prefer non-interactive '
            'commands; interactive prompts will hang until the timeout. '
            'Android does not support this tool.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description':
                  'The command line to run. Compound commands are allowed; '
                  'every segment must be on the allowlist or the whole command '
                  'is sent for approval.',
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
                  'Optional timeout in seconds (default $defaultTimeoutSeconds, '
                  'clamped to 1–$maxTimeoutSeconds).',
            },
          },
          'required': ['command'],
        },
      },
    };
  }

  /// True when the tool should be offered to the model. PATH availability is
  /// part of the readiness gate (an empty allowlist is still allowed: every
  /// command then asks).
  static bool isReady({
    required bool developerMode,
    required List<String> allowlist,
  }) {
    if (!developerMode || !isPlatformSupported) return false;
    if (allowlist.isEmpty) return true;
    return hasAvailableProgram(allowlist);
  }

  static Map<String, bool> probeAllowlist(
    Iterable<String> programs, {
    bool refresh = false,
  }) {
    if (debugAvailabilityOverride != null) {
      return Map<String, bool>.unmodifiable(<String, bool>{
        for (final program in programs)
          program: debugAvailabilityOverride![program] ?? false,
      });
    }
    final names =
        programs
            .map((program) => program.trim().toLowerCase())
            .where((program) => program.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final key = names.join('|');
    final now = DateTime.now();
    if (!refresh &&
        _probeCache != null &&
        _probeKey == key &&
        _probeAt != null &&
        now.difference(_probeAt!) < const Duration(minutes: 1)) {
      return Map<String, bool>.unmodifiable(_probeCache!);
    }
    final result = <String, bool>{
      for (final name in names) name: _existsOnPath(name),
    };
    _probeCache = result;
    _probeKey = key;
    _probeAt = now;
    return Map<String, bool>.unmodifiable(result);
  }

  static bool hasAvailableProgram(Iterable<String> programs) =>
      probeAllowlist(programs).values.any((available) => available);

  /// Execute one command. Returns the structured JSON string handed to the
  /// model. [approvedCommand] carries the exact command the user approved on
  /// the resume path; any different command is re-classified.
  static Future<String> execute(
    Map<String, dynamic> args, {
    required String workspacePath,
    required bool developerMode,
    required List<String> allowlist,
    bool strictMode = false,
    String? conversationId,
    String? toolCallId,
    String? approvedCommand,
    CliCancellationToken? cancellation,
  }) async {
    if (!developerMode) {
      return _error(
        'developer_mode_disabled',
        'Developer mode is off. Enable it in Settings → Developer mode before '
            'running shell commands.',
      );
    }
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

    final policy = ShellPolicy.decide(
      command: command,
      allowlist: allowlist,
      strictMode: strictMode,
    );
    final approved =
        approvedCommand != null && approvedCommand.trim() == command.trim();
    if (!approved && !policy.allowed) {
      if (policy.decision == ShellPolicyDecision.deny) {
        return _error(
          'approval_denied',
          'This command is not allowed by the current shell policy.',
          extra: <String, dynamic>{
            'command': command,
            'programs': policy.programs,
            'blocked_programs': policy.blockedPrograms,
            'reason': policy.reason,
          },
        );
      }
      return _error(
        'approval_required',
        'This command is outside the developer-mode allowlist. Ask the user '
            'to approve it before running it again.',
        extra: <String, dynamic>{
          'command': command,
          'programs': policy.programs,
          'blocked_programs': policy.blockedPrograms,
          'reason': policy.reason,
        },
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
          timeout: Duration(seconds: timeoutSeconds),
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

    final stdout = _redactSecrets(_stripAnsi(result.stdout));
    final stderr = _redactSecrets(_stripAnsi(result.stderr));
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
            'Command: ${_redactSecrets(command)}\n'
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
      if (result.timedOut)
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
    final value = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString().trim() ?? '');
    if (value == null) return defaultTimeoutSeconds;
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

  static String _stripAnsi(String text) {
    var out = text.replaceAll(_osc, '');
    out = out.replaceAll(_csi, '');
    return out;
  }

  static String _redactSecrets(String text) {
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

  static bool _existsOnPath(String program) {
    if (program.contains('/') || program.contains('\\')) {
      return File(program).existsSync();
    }
    final pathValue = Platform.environment['PATH'] ?? '';
    if (pathValue.isEmpty) return false;
    final directories = pathValue.split(Platform.isWindows ? ';' : ':');
    final extensions = Platform.isWindows
        ? (Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
              .split(';')
              .where((extension) => extension.isNotEmpty)
              .toList()
        : const <String>[''];
    for (final directory in directories) {
      if (directory.trim().isEmpty) continue;
      for (final extension in extensions) {
        try {
          if (File(p.join(directory, '$program$extension')).existsSync()) {
            return true;
          }
        } catch (_) {}
      }
    }
    return false;
  }
}
