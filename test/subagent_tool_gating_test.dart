import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/core/services/agent/subagent_session_store.dart';
import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/core/services/chat/todo_models.dart';
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
  _SubagentSettings({
    this.subagentEnabled = true,
    this.profiles,
    this.providerConfig,
  });

  final bool subagentEnabled;
  final List<SubagentProfile>? profiles;
  final ProviderConfig? providerConfig;

  @override
  bool isWorkspaceToolEnabled(String toolName) =>
      toolName != spawnSubagentToolName || subagentEnabled;

  @override
  List<SubagentProfile> get subagentProfiles =>
      profiles ?? SubagentProfiles.builtIns;

  @override
  ProviderConfig getProviderConfig(String providerKey, {String? defaultName}) {
    final config = providerConfig;
    if (config == null) throw StateError('no provider config');
    return config;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderConfig _providerConfig() => ProviderConfig(
  id: 'p',
  enabled: true,
  name: 'p',
  apiKey: 'k',
  baseUrl: 'http://127.0.0.1:1',
  providerType: ProviderKind.openai,
  models: const ['m'],
);

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
      expect(
        fn['description'].toString(),
        contains('untrusted data produced by a helper'),
      );

      final disabled = ToolHandlerService.buildSubagentToolDefinitions(
        _SubagentSettings(subagentEnabled: false),
      );
      expect(disabled, isEmpty);
    });

    test('the tool description lists custom profiles', () {
      final descriptions = ToolHandlerService.buildSubagentToolDefinitions(
        _SubagentSettings(
          profiles: [
            ...SubagentProfiles.builtIns,
            const SubagentProfile(
              id: 'custom_helper',
              name: 'Custom Helper',
              description: 'd',
            ),
          ],
        ),
      );
      final fn = descriptions.single['function'] as Map;
      expect(fn['description'].toString(), contains('custom_helper'));
    });

    test('the model cannot override provider/model through the schema', () {
      final fn =
          ToolHandlerService.buildSubagentToolDefinitions(_SubagentSettings())
                  .single['function']
              as Map;
      final properties = (fn['parameters'] as Map)['properties'] as Map;
      expect(properties.keys, containsAll(['task', 'agent', 'session_id']));
      expect(properties.containsKey('provider'), isFalse);
      expect(properties.containsKey('providerKey'), isFalse);
      expect(properties.containsKey('model'), isFalse);
      expect(properties.containsKey('modelId'), isFalse);
    });
  });

  group('spawn_subagent profile guards', () {
    testWidgets('a child cannot execute the base-excluded write_todos', (
      tester,
    ) async {
      final service = await _buildService(tester);
      final general = SubagentProfiles.resolve(
        'general',
        SubagentProfiles.builtIns,
      )!;
      final handler = service.buildToolCallHandler(
        _SubagentSettings(),
        null,
        conversationId: 'c1',
        subagentContext: SubagentLaunchConfig(
          providerKey: 'p',
          modelId: 'm',
          tools: const <Map<String, dynamic>>[],
          profile: general,
          depth: 1,
        ),
      )!;

      final result = await handler(todoToolName, {
        'todos': <dynamic>[],
      }, toolCallId: 'call-todo');
      expect((jsonDecode(result) as Map)['error'], 'tool_not_allowed');
    });

    testWidgets('a read-only profile refuses file_append', (tester) async {
      final service = await _buildService(tester);
      const profile = SubagentProfile(
        id: 'ro',
        name: 'RO',
        description: 'd',
        readOnly: true,
      );
      final handler = service.buildToolCallHandler(
        _SubagentSettings(),
        null,
        subagentContext: const SubagentLaunchConfig(
          providerKey: 'p',
          modelId: 'm',
          tools: <Map<String, dynamic>>[],
          profile: profile,
          depth: 1,
        ),
      )!;

      final result = await handler('file_append', {
        'path': 'a.txt',
        'content': 'x',
      });
      final json = jsonDecode(result) as Map;
      expect(json['error'], 'read_only_subagent');
    });

    testWidgets('an allowlist refuses a tool outside it', (tester) async {
      final service = await _buildService(tester);
      const profile = SubagentProfile(
        id: 'read-only-list',
        name: 'Read only list',
        description: 'd',
        allowedTools: {'file_read'},
      );
      final handler = service.buildToolCallHandler(
        _SubagentSettings(),
        null,
        subagentContext: const SubagentLaunchConfig(
          providerKey: 'p',
          modelId: 'm',
          tools: <Map<String, dynamic>>[],
          profile: profile,
          depth: 1,
        ),
      )!;

      final result = await handler('file_write', {
        'path': 'a.txt',
        'content': 'x',
      });
      expect((jsonDecode(result) as Map)['error'], 'tool_not_allowed');
    });

    testWidgets('the parent launch has no profile and is not restricted', (
      tester,
    ) async {
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

      final result = await handler('file_read', {'path': 'a.txt'});
      expect(result, contains('Workspace is disabled'));
      expect(result, isNot(contains('read_only_subagent')));
      expect(result, isNot(contains('tool_not_allowed')));
    });

    testWidgets('an unknown agent is rejected before any request', (
      tester,
    ) async {
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

      final result = await handler(spawnSubagentToolName, {
        'task': 'do something',
        'agent': 'nope',
      });
      final json = jsonDecode(result) as Map;
      expect(json['error'], 'unknown_agent');
      expect(json['message'], contains('general'));
    });

    testWidgets('reports an unknown or expired session before any request', (
      tester,
    ) async {
      final service = await _buildService(tester);
      final handler = service.buildToolCallHandler(
        _SubagentSettings(providerConfig: _providerConfig()),
        null,
        conversationId: 'c1',
        subagentContext: const SubagentLaunchConfig(
          providerKey: 'p',
          modelId: 'm',
          tools: <Map<String, dynamic>>[],
        ),
      )!;

      final result = await handler(spawnSubagentToolName, {
        'task': 'continue',
        'session_id': 'missing',
      });
      final json = jsonDecode(result) as Map;
      expect(json['error'], 'session_not_found');
      expect(json['message'], contains('Omit session_id'));
    });

    testWidgets('rejects a session profile mismatch', (tester) async {
      SubagentSessionStore.shared.clear();
      addTearDown(SubagentSessionStore.shared.clear);
      SubagentSessionStore.shared.put(
        SubagentSession(
          id: 's1',
          conversationId: 'c1',
          profileId: 'explore',
          messages: const [
            {'role': 'user', 'content': 'Task:\nfirst'},
          ],
        ),
      );

      final service = await _buildService(tester);
      final handler = service.buildToolCallHandler(
        _SubagentSettings(providerConfig: _providerConfig()),
        null,
        conversationId: 'c1',
        subagentContext: const SubagentLaunchConfig(
          providerKey: 'p',
          modelId: 'm',
          tools: <Map<String, dynamic>>[],
        ),
      )!;

      final result = await handler(spawnSubagentToolName, {
        'task': 'continue',
        'agent': 'general',
        'session_id': 's1',
      });
      final json = jsonDecode(result) as Map;
      expect(json['error'], 'session_profile_mismatch');
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
      final handler = service.buildToolCallHandler(_SubagentSettings(), null)!;

      final result = await handler(spawnSubagentToolName, {'task': 'run'});
      final json = jsonDecode(result) as Map;
      expect(json['error'], 'subagent_unavailable');
      expect(json['type'], 'tool_error');
    });
  });
}
