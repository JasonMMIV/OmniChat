import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/mcp/mcp_tool_service.dart';
import 'package:OmniChat/core/services/shell/shell_run_service.dart';
import 'package:OmniChat/features/home/services/tool_handler_service.dart';

class _McpProvider extends ChangeNotifier implements McpProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AssistantProvider extends ChangeNotifier implements AssistantProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PermissionSettings extends ChangeNotifier implements SettingsProvider {
  _PermissionSettings({
    this.fileOutsideWorkspaceAllowAllV1 = false,
    this.shellAllowAllV1 = false,
  });

  @override
  final bool fileOutsideWorkspaceAllowAllV1;

  @override
  final bool shellAllowAllV1;

  @override
  bool isWorkspaceToolEnabled(String toolName) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ToolHandlerService> _buildService(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<McpProvider>.value(
        value: _McpProvider(),
        child: ChangeNotifierProvider<AssistantProvider>.value(
          value: _AssistantProvider(),
          child: ChangeNotifierProvider<McpToolService>.value(
            value: McpToolService(),
            child: Builder(
              builder: (context) {
                captured = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    ),
  );
  return ToolHandlerService(
    contextProvider: captured,
    chatService: _ChatService(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('outside workspace asks by default, then allow-all writes', (
    tester,
  ) async {
    final service = await _buildService(tester);
    await tester.runAsync(() async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_handler_permissions_',
      );
      final outside = await Directory.systemTemp.createTemp(
        'omnichat_handler_outside_',
      );
      try {
        final target = '${outside.path}/out.txt';

        final askHandler = service.buildToolCallHandler(
          _PermissionSettings(),
          null,
          workspacePath: workspace.path,
        )!;
        final ask = await askHandler('file_write', {
          'path': target,
          'content': 'hello',
        });
        expect(ask, contains('approval_required'));
        expect(File(target).existsSync(), isFalse);

        final allowAllHandler = service.buildToolCallHandler(
          _PermissionSettings(fileOutsideWorkspaceAllowAllV1: true),
          null,
          workspacePath: workspace.path,
        )!;
        final run = await allowAllHandler('file_write', {
          'path': target,
          'content': 'hello',
        });
        expect(run, contains('Wrote'));
        expect(File(target).readAsStringSync(), 'hello');
      } finally {
        if (await workspace.exists()) {
          await workspace.delete(recursive: true);
        }
        if (await outside.exists()) {
          await outside.delete(recursive: true);
        }
      }
    });
  });

  testWidgets('writes larger than the old 512 KB floor succeed', (
    tester,
  ) async {
    final service = await _buildService(tester);
    await tester.runAsync(() async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_handler_large_write_',
      );
      try {
        final content = 'x' * (3 * 1024 * 1024);
        final handler = service.buildToolCallHandler(
          _PermissionSettings(),
          null,
          workspacePath: workspace.path,
        )!;
        final result = await handler('file_write', {
          'path': 'large.txt',
          'content': content,
        });
        expect(result, contains('Wrote'));
        expect(
          await File('${workspace.path}/large.txt').length(),
          content.length,
        );
      } finally {
        if (await workspace.exists()) {
          await workspace.delete(recursive: true);
        }
      }
    });
  });

  testWidgets('shell asks by default and runs with allow-all', (tester) async {
    if (!ShellRunService.isPlatformSupported) return;
    final service = await _buildService(tester);
    await tester.runAsync(() async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_handler_shell_',
      );
      try {
        final askHandler = service.buildToolCallHandler(
          _PermissionSettings(),
          null,
          workspacePath: workspace.path,
        )!;
        final ask = await askHandler('shell_run', {'command': 'echo hello'});
        expect(ask, contains('approval_required'));

        final allowHandler = service.buildToolCallHandler(
          _PermissionSettings(shellAllowAllV1: true),
          null,
          workspacePath: workspace.path,
        )!;
        final raw = await allowHandler('shell_run', {'command': 'echo hello'});
        final payload = jsonDecode(raw) as Map<String, dynamic>;
        expect(payload['exit_code'], 0);
        expect(payload['stdout'].toString(), contains('hello'));
      } finally {
        if (await workspace.exists()) {
          await workspace.delete(recursive: true);
        }
      }
    });
  });

  testWidgets('rejects a move when both paths are outside', (tester) async {
    final service = await _buildService(tester);
    await tester.runAsync(() async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_handler_dual_outside_',
      );
      final sourceDir = await Directory.systemTemp.createTemp(
        'omnichat_handler_source_',
      );
      final destinationDir = await Directory.systemTemp.createTemp(
        'omnichat_handler_destination_',
      );
      try {
        final source = File('${sourceDir.path}/file.txt');
        await source.writeAsString('move me');
        final destination = '${destinationDir.path}/file.txt';
        final handler = service.buildToolCallHandler(
          _PermissionSettings(fileOutsideWorkspaceAllowAllV1: true),
          null,
          workspacePath: workspace.path,
        )!;
        final result = await handler('file_move', {
          'source': source.path,
          'destination': destination,
        });
        expect(result, contains('dual_outside_paths'));
        expect(await source.exists(), isTrue);
        expect(await File(destination).exists(), isFalse);
      } finally {
        if (await workspace.exists()) {
          await workspace.delete(recursive: true);
        }
        if (await sourceDir.exists()) {
          await sourceDir.delete(recursive: true);
        }
        if (await destinationDir.exists()) {
          await destinationDir.delete(recursive: true);
        }
      }
    });
  });
}
