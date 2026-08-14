import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
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
  @override
  bool get searchEnabled => false;

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
  });
}
