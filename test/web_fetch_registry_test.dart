import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/mcp/mcp_tool_service.dart';
import 'package:OmniChat/core/services/tools/tool_result_caps.dart';
import 'package:OmniChat/features/home/services/tool_handler_service.dart';

class _TestMcpProvider extends ChangeNotifier implements McpProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestAssistantProvider extends ChangeNotifier
    implements AssistantProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestChatService extends ChangeNotifier implements ChatService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyMcpToolService extends McpToolService {
  @override
  List<McpToolConfig> listAvailableToolsForAssistant(
    McpProvider mcpProvider,
    AssistantProvider assistants,
    String? assistantId,
  ) => const <McpToolConfig>[];
}

class _WebFetchSettings extends ChangeNotifier implements SettingsProvider {
  @override
  bool get searchEnabled => false;

  @override
  bool get webFetchEnabled => true;

  @override
  bool get webFetchAllowPost => false;

  @override
  bool get webFetchAllowPrivateHosts => false;

  @override
  String get webFetchSource => 'local';

  @override
  bool get skillsPreloadEnabled => false;

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
        value: _TestMcpProvider(),
        child: ChangeNotifierProvider<AssistantProvider>.value(
          value: _TestAssistantProvider(),
          child: ChangeNotifierProvider<McpToolService>.value(
            value: _EmptyMcpToolService(),
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
    chatService: _TestChatService(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('buildToolDefinitions advertises a single web_fetch tool',
      (tester) async {
    final service = await _buildService(tester);
    final defs = service.buildToolDefinitions(
      _WebFetchSettings(),
      null,
      'provider',
      'model',
      false,
      workspaceEnabled: false,
      isToolModel: (_, _) => true,
    );

    final names = <String>[
      for (final def in defs) ((def['function'] as Map)['name']).toString(),
    ];
    expect(names.where((name) => name == 'web_fetch'), hasLength(1));
    expect(
      names.where(
        (name) =>
            name == 'read_page' ||
            name == 'fetch_url' ||
            name.startsWith('fetch_'),
      ),
      isEmpty,
    );
  });

  testWidgets('legacy fetch_markdown calls route to web_fetch', (tester) async {
    final service = await _buildService(tester);
    final handler = service.buildToolCallHandler(_WebFetchSettings(), null);

    final result = await handler!('fetch_markdown', {'url': 'not-a-url'});
    expect(result, contains('"tool":"web_fetch"'));
    expect(result, contains('invalid_url'));
  });

  test('ToolResultCaps adds web_fetch guidance and caps exactly once', () {
    final original = 'x' * 40000;
    final capped = ToolResultCaps.cap(
      toolName: 'web_fetch',
      result: original,
    );
    expect(capped.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
    expect(capped, contains('next_start_index'));

    final again = ToolResultCaps.cap(
      toolName: 'web_fetch',
      result: capped,
    );
    expect(again, same(capped));
  });
}
