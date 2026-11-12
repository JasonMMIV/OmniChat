import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
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

class _SubagentSettings extends ChangeNotifier implements SettingsProvider {
  _SubagentSettings({this.subagentEnabled = true});

  final bool subagentEnabled;

  @override
  bool isWorkspaceToolEnabled(String toolName) =>
      toolName != spawnSubagentToolName || subagentEnabled;

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

  group('spawn_subagent registration', () {
    test('is advertised by default and hidden by the per-tool switch', () {
      final enabled = ToolHandlerService.buildSubagentToolDefinitions(
        _SubagentSettings(),
      );
      expect(enabled, hasLength(1));
      final fn = enabled.single['function'] as Map;
      expect(fn['name'], spawnSubagentToolName);
      expect((fn['parameters'] as Map)['required'], ['task']);

      final disabled = ToolHandlerService.buildSubagentToolDefinitions(
        _SubagentSettings(subagentEnabled: false),
      );
      expect(disabled, isEmpty);
    });
  });

  group('spawn_subagent handler guards', () {
    testWidgets('refuses nested spawns', (tester) async {
      final service = await _buildService(tester);
      final handler = service.buildToolCallHandler(
        _SubagentSettings(),
        null,
        subagentContext: const SubagentLaunchConfig(
          providerKey: 'p',
          modelId: 'm',
          tools: <Map<String, dynamic>>[],
          depth: 1,
        ),
      )!;

      final result = await handler(spawnSubagentToolName, {
        'task': 'do something',
      });
      final json = jsonDecode(result) as Map;
      expect(json['error'], 'nested_subagent');
    });

    testWidgets('rejects an empty task', (tester) async {
      final service = await _buildService(tester);
      final handler = service.buildToolCallHandler(
        _SubagentSettings(),
        null,
        subagentContext: const SubagentLaunchConfig(
          providerKey: 'p',
          modelId: 'm',
          tools: <Map<String, dynamic>>[],
        ),
      )!;

      final result = await handler(spawnSubagentToolName, {'task': '   '});
      expect((jsonDecode(result) as Map)['error'], 'invalid_task');
    });

    testWidgets('reports a missing provider/model instead of throwing', (
      tester,
    ) async {
      final service = await _buildService(tester);
      final handler = service.buildToolCallHandler(
        _SubagentSettings(),
        null,
      )!;

      final result = await handler(spawnSubagentToolName, {'task': 'run'});
      final json = jsonDecode(result) as Map;
      expect(json['error'], 'subagent_unavailable');
      expect(json['type'], 'tool_error');
    });
  });
}
