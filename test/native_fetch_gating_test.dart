import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/builtin_tools.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/mcp/mcp_tool_service.dart';
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

class _TestSettings extends ChangeNotifier implements SettingsProvider {
  _TestSettings({required this.cfg, this.searchEnabled = true});

  final ProviderConfig cfg;
  @override
  final bool searchEnabled;

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
  bool get planningEnabled => true;

  @override
  Set<String> get approvalAlwaysAllowed => const <String>{};

  @override
  ProviderConfig getProviderConfig(String key, {String? defaultName}) => cfg;

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

List<String> _names(List<Map<String, dynamic>> defs) => [
  for (final def in defs) ((def['function'] as Map)['name']).toString(),
];

ProviderConfig _config({
  String id = 'openrouter',
  String baseUrl = 'https://openrouter.ai/api/v1',
  ProviderKind kind = ProviderKind.openai,
  bool useResponseApi = false,
  Map<String, dynamic>? override,
}) => ProviderConfig(
  id: id,
  enabled: true,
  name: id,
  apiKey: 'k',
  baseUrl: baseUrl,
  providerType: kind,
  useResponseApi: useResponseApi,
  modelOverrides: <String, dynamic>{
    'model': <String, dynamic>{if (override != null) ...override},
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no native fetch keeps the client web_fetch tool', (
    tester,
  ) async {
    final service = await _buildService(tester);
    final defs = service.buildToolDefinitions(
      _TestSettings(cfg: _config(), searchEnabled: false),
      null,
      'openrouter',
      'model',
      false,
      workspaceEnabled: false,
      isToolModel: (_, _) => true,
    );
    expect(_names(defs), contains('web_fetch'));
  });

  testWidgets('OpenRouter native fetch hides the client web_fetch tool', (
    tester,
  ) async {
    final service = await _buildService(tester);
    final defs = service.buildToolDefinitions(
      _TestSettings(
        cfg: _config(
          override: {
            'builtInTools': [BuiltInToolNames.webFetch],
          },
        ),
        searchEnabled: false,
      ),
      null,
      'openrouter',
      'model',
      false,
      workspaceEnabled: false,
      isToolModel: (_, _) => true,
    );
    expect(_names(defs), isNot(contains('web_fetch')));
  });

  testWidgets('Claude official native fetch hides the client web_fetch tool', (
    tester,
  ) async {
    final service = await _buildService(tester);
    final defs = service.buildToolDefinitions(
      _TestSettings(
        cfg: _config(
          id: 'claude',
          baseUrl: 'https://api.anthropic.com',
          kind: ProviderKind.claude,
          override: {
            'builtInTools': [BuiltInToolNames.webFetch],
          },
        ),
        searchEnabled: false,
      ),
      null,
      'claude',
      'model',
      false,
      workspaceEnabled: false,
      isToolModel: (_, _) => true,
    );
    expect(_names(defs), isNot(contains('web_fetch')));
  });

  testWidgets('Gemini url_context hides both client search and fetch tools', (
    tester,
  ) async {
    final service = await _buildService(tester);
    final defs = service.buildToolDefinitions(
      _TestSettings(
        cfg: _config(
          id: 'gemini',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          kind: ProviderKind.google,
          override: {
            'builtInTools': [BuiltInToolNames.urlContext],
          },
        ),
      ),
      null,
      'gemini',
      'model',
      false, // message_builder reports any Gemini built-in as active
      workspaceEnabled: false,
      isToolModel: (_, _) => true,
    );
    expect(_names(defs), isNot(contains('search_web')));
    expect(_names(defs), isNot(contains('web_fetch')));
  });

  testWidgets('native search suppresses search_web but not web_fetch', (
    tester,
  ) async {
    final service = await _buildService(tester);
    final defs = service.buildToolDefinitions(
      _TestSettings(
        cfg: _config(
          override: {
            'builtInTools': [BuiltInToolNames.search],
          },
        ),
      ),
      null,
      'openrouter',
      'model',
      false,
      workspaceEnabled: false,
      isToolModel: (_, _) => true,
    );
    expect(_names(defs), isNot(contains('search_web')));
    expect(_names(defs), contains('web_fetch'));
  });
}
