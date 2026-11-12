import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/shell/android/android_shell_service.dart';
import 'package:OmniChat/core/services/shell/android/workspace_mount_table.dart';
import 'package:OmniChat/core/services/tools/tool_result_caps.dart';

void main() {
  group('AndroidShellService', () {
    test('timeout defaults to 30s and clamps to 1..120', () {
      expect(AndroidShellService.parseTimeoutSeconds(null), 30);
      expect(AndroidShellService.parseTimeoutSeconds(''), 30);
      expect(AndroidShellService.parseTimeoutSeconds('15'), 15);
      expect(AndroidShellService.parseTimeoutSeconds(0), 1);
      expect(AndroidShellService.parseTimeoutSeconds(999), 120);
      expect(AndroidShellService.parseTimeoutSeconds(42.9), 42);
    });

    test('tool definition is shell_exec with a required command', () {
      final def = AndroidShellService.getToolDefinition();
      final function = def['function'] as Map;
      expect(function['name'], 'shell_exec');
      expect(function['parameters']['required'], <String>['command']);
      final properties = function['parameters']['properties'] as Map;
      expect(
        properties.keys,
        containsAll(<String>['command', 'cwd', 'timeout_seconds']),
      );
    });

    test('shell_exec uses the shell result budget', () {
      expect(
        ToolResultCaps.thresholdFor('shell_exec'),
        ToolResultCaps.shellCapChars,
      );
    });

    test(
      'execute rejects an empty command and an unapproved command',
      () async {
        AndroidShellService.debugPlatformSupported = true;
        addTearDown(() => AndroidShellService.debugPlatformSupported = null);

        final empty = await AndroidShellService.execute(<String, dynamic>{
          'command': '   ',
        }, workspacePath: '/tmp');
        expect(empty, contains('"error":"empty_command"'));

        final unapproved = await AndroidShellService.execute(<String, dynamic>{
          'command': 'echo hi',
        }, workspacePath: '/tmp');
        expect(unapproved, contains('"error":"approval_required"'));
      },
    );

    test(
      'resolveGuestCwd accepts relative and guest paths inside the workspace',
      () async {
        final temp = await Directory.systemTemp.createTemp('omnichat-mount-');
        try {
          final workspace = await temp.resolveSymbolicLinks();
          final child = Directory('$workspace/lib')..createSync();
          final table = WorkspaceMountTable.forWorkspace(
            workspaceHostPath: workspace.replaceAll('\\', '/'),
          );
          expect(
            await AndroidShellService.resolveGuestCwd(
              'lib',
              workspaceRoot: workspace,
              mounts: table,
            ),
            '/workspace/lib',
          );
          expect(
            await AndroidShellService.resolveGuestCwd(
              '/workspace/lib',
              workspaceRoot: workspace,
              mounts: table,
            ),
            '/workspace/lib',
          );
          expect(child.existsSync(), isTrue);
        } finally {
          await temp.delete(recursive: true);
        }
      },
      skip: Platform.isWindows
          ? 'Windows host paths are not POSIX; mount mapping is Android-only'
          : false,
    );

    test(
      'resolveGuestCwd rejects escapes and missing directories',
      () async {
        final temp = await Directory.systemTemp.createTemp('omnichat-mount-');
        try {
          final workspace = await temp.resolveSymbolicLinks();
          final table = WorkspaceMountTable.forWorkspace(
            workspaceHostPath: workspace.replaceAll('\\', '/'),
          );
          expect(
            await AndroidShellService.resolveGuestCwd(
              '..',
              workspaceRoot: workspace,
              mounts: table,
            ),
            isNull,
          );
          expect(
            await AndroidShellService.resolveGuestCwd(
              '/etc',
              workspaceRoot: workspace,
              mounts: table,
            ),
            isNull,
          );
          expect(
            await AndroidShellService.resolveGuestCwd(
              'missing',
              workspaceRoot: workspace,
              mounts: table,
            ),
            isNull,
          );
        } finally {
          await temp.delete(recursive: true);
        }
      },
      skip: Platform.isWindows
          ? 'Windows host paths are not POSIX; mount mapping is Android-only'
          : false,
    );
  });
}
