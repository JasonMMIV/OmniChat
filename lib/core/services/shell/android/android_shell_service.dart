// P2-5: Android `shell_exec` (foreground PRoot command).
//
// Android deliberately exposes a different tool from the desktop `shell_run`:
// one foreground command, fixed guest `/bin/sh`, 30 s default / 120 s hard
// timeout, 24 KB stdout + 6 KB stderr (then the shared 68 KB tool cap). The
// command is passed to PRoot as an independent argv entry, never spliced into
// a host command line.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../file/session_outputs.dart';
import '../../tools/tool_result_caps.dart';
import '../changed_files.dart';
import '../cli_process_supervisor.dart';
import '../shell_run_service.dart';
import '../tool_run_registry.dart';
import 'android_sandbox_service.dart';
import 'workspace_mount_table.dart';
import 'workspace_path_probe.dart';

class AndroidShellService {
  AndroidShellService._();

  static const String toolName = AndroidSandboxService.toolName;
  static const int defaultTimeoutSeconds =
      AndroidSandboxService.defaultTimeoutSeconds;
  static const int maxTimeoutSeconds = AndroidSandboxService.maxTimeoutSeconds;
  static const int maxStdoutBytes = 24 * 1024;
  static const int maxStderrBytes = 6 * 1024;

  /// Test seam: lets pure payload/approval tests exercise the Android branch
  /// without a MethodChannel.
  @visibleForTesting
  static bool? debugPlatformSupported;

  static bool get isPlatformSupported =>
      debugPlatformSupported ?? AndroidSandboxService.isPlatformSupported;

  /// True only after `probe` reports native PRoot + an installed rootfs.
  /// The tool is not advertised before that (plan §2.8 item 8).
  static bool get isToolAvailable =>
      isPlatformSupported && AndroidSandboxService.instance.isReady;

  static int parseTimeoutSeconds(Object? raw) =>
      AndroidSandboxService.parseTimeoutSeconds(raw);

  static Map<String, dynamic> getToolDefinition() {
    return <String, dynamic>{
      'type': 'function',
      'function': {
        'name': toolName,
        'description':
            'Run one foreground shell command inside the Android PRoot '
            'sandbox (Ubuntu base). Commands start in the guest directory '
            '/workspace, which maps to the selected workspace. This is NOT a '
            'security sandbox: commands run with the app permissions. Only '
            'one command runs at a time; background jobs are not supported. '
            'External shared-storage workspaces may not support executable '
            'bits or symlinks. Use relative paths for cwd.',
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
                  'Optional working directory under /workspace (default '
                  '/workspace). Absolute host paths and ".." are rejected.',
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

  /// Execute one command. Approval is checked again here as defense in depth;
  /// the tool handler normally asks before this method is reached.
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
        'shell_exec is only available on Android.',
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

    final status = AndroidSandboxService.instance.status;
    if (!status.ready) {
      return _error(
        'environment_not_installed',
        'The Android shell environment is not installed. Ask the user to open '
            'Settings → Android Shell and install it.',
        extra: <String, dynamic>{'reason': status.reason},
      );
    }

    final workspaceRoot = await _canonicalDirectory(workspacePath);
    if (workspaceRoot == null) {
      return _error(
        'workspace_unavailable',
        'The workspace directory does not exist or is unavailable.',
      );
    }
    final probe = await WorkspacePathProbe.probe(workspaceRoot);
    if (!probe.ok) {
      return _error(
        'workspace_unavailable',
        'The workspace cannot be used for Android shell commands '
            '(${probe.reason ?? 'probe_failed'}).',
        extra: <String, dynamic>{'reason': probe.reason},
      );
    }
    final canonicalRoot = probe.canonicalPath ?? workspaceRoot;

    final mounts = WorkspaceMountTable.forWorkspace(
      workspaceHostPath: canonicalRoot,
    );
    final guestCwd = await resolveGuestCwd(
      args['cwd'],
      workspaceRoot: canonicalRoot,
      mounts: mounts,
    );
    if (guestCwd == null) {
      return _error(
        'invalid_cwd',
        'The cwd must be a directory inside the workspace (absolute host '
            'paths and ".." are rejected).',
      );
    }

    final timeoutSeconds = parseTimeoutSeconds(args['timeout_seconds']);
    final runId = (toolCallId != null && toolCallId.trim().isNotEmpty)
        ? toolCallId
        : 'shell-${const Uuid().v4()}';
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

    var cancelled = false;
    if (cancellation != null) {
      cancellation.whenCancelled.then((_) {
        cancelled = true;
        AndroidSandboxService.instance.cancel(runId);
      });
    }

    // Cancellation can arrive before the native run registers its id; without
    // this check the token's cancel would be lost and the command would run
    // to completion.
    if (cancellation?.isCancelled == true) {
      run?.finish();
      return _error(
        'cancelled',
        'The command was cancelled before it started.',
        extra: <String, dynamic>{'command': command},
      );
    }

    WorkspaceSnapshot? before;
    try {
      before = await WorkspaceSnapshot.capture(canonicalRoot);
    } catch (_) {}

    AndroidSandboxRunResult result;
    try {
      result = await AndroidSandboxService.instance.run(
        command: command,
        cwd: guestCwd,
        binds: mounts.channelBinds,
        timeoutSeconds: timeoutSeconds,
        runId: runId,
        onOutput: (output) {
          if (output.stdout.isNotEmpty) run?.addStdout(output.stdout);
          if (output.stderr.isNotEmpty) run?.addStderr(output.stderr);
        },
      );
    } on AndroidSandboxException catch (error) {
      run?.finish();
      return _error(
        error.code,
        error.message,
        extra: <String, dynamic>{'command': command},
      );
    } catch (error) {
      run?.finish();
      return _error(
        'execution_error',
        'The command could not be started: $error',
        extra: <String, dynamic>{'command': command},
      );
    } finally {
      run?.finish();
    }

    WorkspaceSnapshot? after;
    try {
      after = await WorkspaceSnapshot.capture(canonicalRoot);
    } catch (_) {}
    final changed = (before != null && after != null)
        ? diffWorkspaceSnapshots(before, after)
        : const ChangedFilesResult.empty();

    final stdout = ShellRunService.stripAnsiAndRedact(result.stdout);
    final stderr = ShellRunService.stripAnsiAndRedact(result.stderr);
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
            'Command: ${ShellRunService.redactSecrets(command)}\n'
            'Exit code: ${result.exitCode}\n\n'
            '--- stdout ---\n$stdout\n\n'
            '--- stderr ---\n$stderr\n',
      );
    }

    final displayCwd = p
        .relative(
          mounts.hostCwdForGuest(guestCwd) ?? canonicalRoot,
          from: canonicalRoot,
        )
        .replaceAll(r'\', '/');

    final wasCancelled = result.cancelled || cancelled;
    final payload = <String, dynamic>{
      'command': command,
      'cwd': displayCwd,
      'shell': 'android-proot',
      'exit_code': result.exitCode,
      'duration_ms': result.durationMs,
      'timed_out': result.timedOut,
      'cancelled': wasCancelled,
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
      if (wasCancelled)
        'hint':
            'The command was cancelled by the user and its process tree was '
            'terminated.'
      else if (result.timedOut)
        'hint':
            'The command exceeded ${timeoutSeconds}s and its process tree was '
            'terminated. Re-run with a larger timeout_seconds or a more focused command.',
    };

    return ToolResultCaps.cap(toolName: toolName, result: jsonEncode(payload));
  }

  /// Resolve `cwd` (relative to the workspace root, or a guest
  /// `/workspace/...` path) to a canonical guest path. Returns null for any
  /// escape, missing directory, or symlink leaving the workspace.
  static Future<String?> resolveGuestCwd(
    Object? raw, {
    required String workspaceRoot,
    required WorkspaceMountTable mounts,
  }) async {
    final text = (raw ?? '').toString().trim();
    if (text.contains('\u0000')) return null;

    String? hostCandidate;
    if (text.isEmpty) {
      hostCandidate = workspaceRoot;
    } else if (text.startsWith('/')) {
      // Only the guest workspace path is accepted; arbitrary guest paths and
      // host absolute paths are rejected.
      final host = mounts.hostCwdForGuest(text);
      if (host == null) return null;
      hostCandidate = host;
    } else {
      if (text.split('/').any((segment) => segment == '..')) return null;
      final joined = p.normalize(p.join(workspaceRoot, text));
      if (!_isWithin(joined, workspaceRoot)) return null;
      hostCandidate = joined;
    }

    final canonicalWorkspace = await _canonicalDirectory(workspaceRoot);
    final canonicalCandidate = await _canonicalDirectory(hostCandidate);
    if (canonicalWorkspace == null || canonicalCandidate == null) return null;
    if (!_isWithin(canonicalCandidate, canonicalWorkspace)) return null;
    return mounts.guestCwdForHost(canonicalCandidate);
  }

  static Future<String?> _canonicalDirectory(String path) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) return null;
      return await directory.resolveSymbolicLinks();
    } catch (_) {
      return null;
    }
  }

  static bool _isWithin(String candidate, String root) {
    String comparable(String value) {
      final normalized = p.normalize(value).replaceAll(r'\', '/');
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final child = comparable(candidate);
    final parent = comparable(root).replaceFirst(RegExp(r'/+$'), '');
    return child == parent || child.startsWith('$parent/');
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
}
