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

/// Throws on every MCP tool call, simulating a crashed/disconnected MCP server
/// or a malformed response that would previously abort the whole chat flow.
class ThrowingMcpToolService extends McpToolService {
  @override
  Future<String> callToolTextForAssistant(
    McpProvider mcpProvider,
    AssistantProvider assistants, {
    required String? assistantId,
    required String toolName,
    Map<String, dynamic> arguments = const {},
  }) async {
    throw Exception('MCP server crashed for $toolName');
  }
}

class WorkingMcpToolService extends McpToolService {
  @override
  Future<String> callToolTextForAssistant(
    McpProvider mcpProvider,
    AssistantProvider assistants, {
    required String? assistantId,
    required String toolName,
    Map<String, dynamic> arguments = const {},
  }) async {
    return 'tool result ok';
  }
}

// Dummy providers (implements + noSuchMethod pattern): avoid touching real
// SharedPreferences / platform channels during tests.
class TestMcpProvider extends ChangeNotifier implements McpProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestAssistantProvider extends ChangeNotifier
    implements AssistantProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestSettingsProvider extends ChangeNotifier
    implements SettingsProvider {
  TestSettingsProvider({this.alwaysAllowed = const <String>{}});

  /// Persisted "always allow" keys surfaced by this double — the policy
  /// snapshot source read by ToolHandlerService.buildToolCallHandler.
  final Set<String> alwaysAllowed;

  @override
  bool get searchEnabled => false;

  @override
  Set<String> get approvalAlwaysAllowed => alwaysAllowed;

  /// Workspace tool toggles: this double keeps every tool enabled.
  @override
  bool isWorkspaceToolEnabled(String toolName) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ToolHandlerService> _buildService(
  WidgetTester tester,
  McpToolService toolService,
) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<McpProvider>.value(
        value: TestMcpProvider(),
        child: ChangeNotifierProvider<AssistantProvider>.value(
          value: TestAssistantProvider(),
          child: ChangeNotifierProvider<McpToolService>.value(
            value: toolService,
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
    chatService: TestChatService(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ToolHandlerService.buildToolCallHandler', () {
    testWidgets(
      'MCP tool failure returns error JSON instead of throwing',
      (tester) async {
        final service = await _buildService(tester, ThrowingMcpToolService());
        final handler = service.buildToolCallHandler(
          TestSettingsProvider(),
          null,
        );

        final result = await handler!('mcp_read_file', {'path': '/tmp/x'});

        expect(result, contains('tool_error'));
        expect(result, contains('execution_error'));
        expect(result, contains('mcp_read_file'));
        expect(result, contains('MCP server crashed for mcp_read_file'));
        expect(
          result,
          contains(
            'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
          ),
        );
      },
    );

    testWidgets('successful MCP tool call returns the text result untouched',
        (tester) async {
      final service = await _buildService(tester, WorkingMcpToolService());
      final handler = service.buildToolCallHandler(
        TestSettingsProvider(),
        null,
      );

      final result = await handler!('mcp_read_file', {'path': '/tmp/x'});
      expect(result, 'tool result ok');
    });

    testWidgets(
      'out-of-workspace write asks first, then runs with a persisted override',
      (tester) async {
        final service = await _buildService(tester, WorkingMcpToolService());
        // Real filesystem I/O must run outside the fake-async test zone —
        // file operations would otherwise deadlock the widget test.
        await tester.runAsync(() async {
          final workspace =
              await Directory.systemTemp.createTemp('omnichat_ws_');
          final outside =
              await Directory.systemTemp.createTemp('omnichat_out_');
          try {
            final probe = FileToolService.probePathSafety(
              '${outside.path}/out.txt',
              workspace.path,
            );
            expect(probe.inside, isFalse);
            expect(probe.resolvedPath, isNotNull);

            // No override → the gate returns the pending payload and the
            // tool must NOT run (P1-1: the user approves before execution).
            final askHandler = service.buildToolCallHandler(
              TestSettingsProvider(),
              null,
              workspacePath: workspace.path,
            )!;
            final ask = await askHandler('file_write', {
              'path': '${outside.path}/out.txt',
              'content': 'hello',
            });
            expect(ask, contains('approval_required'));
            expect(File('${outside.path}/out.txt').existsSync(), isFalse);

            // Persisted override → the policy snapshot allows the call and
            // the executor runs against the concrete approved absolute path.
            final runHandler = service.buildToolCallHandler(
              TestSettingsProvider(
                alwaysAllowed: {'workspace-out:${probe.resolvedPath}'},
              ),
              null,
              workspacePath: workspace.path,
            )!;
            final run = await runHandler('file_write', {
              'path': '${outside.path}/out.txt',
              'content': 'hello',
            });
            expect(run, contains('Wrote'));
            expect(
              File('${outside.path}/out.txt').readAsStringSync(),
              'hello',
            );
          } finally {
            if (await workspace.exists()) {
              await workspace.delete(recursive: true);
            }
            if (await outside.exists()) {
              await outside.delete(recursive: true);
            }
          }
        });
      },
    );
  });
}
