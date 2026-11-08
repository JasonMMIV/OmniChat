import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';
import 'package:OmniChat/core/services/mcp/mcp_tool_service.dart';
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

class _DevModeSettings extends ChangeNotifier implements SettingsProvider {
  _DevModeSettings({required this.developerModeV1});

  @override
  final bool developerModeV1;

  @override
  Set<String> get approvalAlwaysAllowed => const <String>{};

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

  testWidgets('forwards developer mode to the file-write ceiling', (
    tester,
  ) async {
    final service = await _buildService(tester);
    await tester.runAsync(() async {
      final workspace = await Directory.systemTemp.createTemp(
        'omnichat_handler_dev_mode_',
      );
      try {
        final content = 'x' * (600 * 1024);

        final developerHandler = service.buildToolCallHandler(
          _DevModeSettings(developerModeV1: true),
          null,
          workspacePath: workspace.path,
        )!;
        final developerResult = await developerHandler('file_write', {
          'path': 'developer.txt',
          'content': content,
        });
        expect(developerResult, contains('Wrote'));
        expect(
          await File('${workspace.path}/developer.txt').length(),
          content.length,
        );

        final normalHandler = service.buildToolCallHandler(
          _DevModeSettings(developerModeV1: false),
          null,
          workspacePath: workspace.path,
        )!;
        final normalResult = await normalHandler('file_write', {
          'path': 'normal.txt',
          'content': content,
        });
        expect(normalResult, contains('512 KB'));
        expect(File('${workspace.path}/normal.txt').existsSync(), isFalse);
        expect(FileToolService.maxWriteBytes, 512 * 1024);
      } finally {
        if (await workspace.exists()) {
          await workspace.delete(recursive: true);
        }
      }
    });
  });
}
