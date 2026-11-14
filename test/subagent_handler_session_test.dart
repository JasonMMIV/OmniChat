import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/core/services/agent/subagent_request.dart';
import 'package:OmniChat/core/services/agent/subagent_session_store.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';
import 'package:OmniChat/core/services/api/tool_result_images.dart';
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

class _Settings extends ChangeNotifier implements SettingsProvider {
  @override
  bool isWorkspaceToolEnabled(String toolName) => true;

  @override
  List<SubagentProfile> get subagentProfiles => SubagentProfiles.builtIns;

  @override
  ProviderConfig getProviderConfig(String providerKey, {String? defaultName}) =>
      ProviderConfig(
        id: 'p',
        enabled: true,
        name: 'p',
        apiKey: 'k',
        baseUrl: 'http://127.0.0.1:1',
        providerType: ProviderKind.openai,
        models: const ['m'],
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Transport {
  final requests = <SubagentRoundRequest>[];
  final calls = <({bool stream, ToolImagePolicy? policy})>[];
  final hangStream = StreamController<ChatStreamChunk>();
  bool fail = false;
  bool hang = false;
  bool toolCall = false;
  int _round = 0;

  Future<Stream<ChatStreamChunk>> call(
    SubagentRoundRequest request,
    ProviderConfig config,
    String modelId, {
    required bool stream,
    required ToolImagePolicy? toolImagePolicy,
  }) async {
    requests.add(request);
    calls.add((stream: stream, policy: toolImagePolicy));
    if (fail) throw StateError('transport boom');
    if (hang) return hangStream.stream;
    if (!stream) {
      return Stream<ChatStreamChunk>.fromIterable([
        ChatStreamChunk(content: 'WRAP-UP', isDone: false, totalTokens: 0),
      ]);
    }
    if (toolCall) {
      return Stream<ChatStreamChunk>.fromIterable([
        ChatStreamChunk(
          content: '',
          isDone: false,
          totalTokens: 0,
          toolCalls: [
            ToolCallInfo(
              id: 't1',
              name: 'file_read',
              arguments: const {'path': 'a.txt'},
            ),
          ],
        ),
      ]);
    }
    _round++;
    return Stream<ChatStreamChunk>.fromIterable([
      ChatStreamChunk(
        content: _round == 1 ? 'FIRST ANSWER' : 'SECOND ANSWER',
        isDone: false,
        totalTokens: 0,
      ),
    ]);
  }
}

Future<ToolHandlerService> _buildService(
  WidgetTester tester,
  _Transport transport, {
  void Function(String requestId)? cancel,
}) async {
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
    subagentRoundTransport: transport.call,
    subagentCancelRequest: cancel,
  );
}

ToolCallHandler _handler(ToolHandlerService service, String conversationId) =>
    service.buildToolCallHandler(
      _Settings(),
      null,
      conversationId: conversationId,
      subagentContext: const SubagentLaunchConfig(
        providerKey: 'p',
        modelId: 'm',
        tools: <Map<String, dynamic>>[],
      ),
    )!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(SubagentSessionStore.shared.clear);
  tearDown(SubagentSessionStore.shared.clear);

  testWidgets('session id round-trips handler requests', (tester) async {
    final transport = _Transport();
    final service = await _buildService(tester, transport);
    final handler = _handler(service, 'c1');

    final first = await tester.runAsync(
      () => handler(spawnSubagentToolName, {
        'task': 'first task',
        'agent': 'general',
      }, toolCallId: 'call-1'),
    );
    final firstJson = jsonDecode(first!) as Map;
    expect(firstJson['status'], 'finished');
    expect(firstJson['summary'], contains('FIRST ANSWER'));
    final sessionId = firstJson['session_id'] as String?;
    expect(sessionId, isNotNull);
    expect(SubagentSessionStore.shared.get(sessionId!, 'c1'), isNotNull);

    final second = await tester.runAsync(
      () => handler(spawnSubagentToolName, {
        'task': 'second task',
        'agent': 'general',
        'session_id': sessionId,
      }, toolCallId: 'call-2'),
    );
    final secondJson = jsonDecode(second!) as Map;
    expect(secondJson['status'], 'finished');
    expect(secondJson['session_id'], sessionId);

    expect(transport.requests, hasLength(2));
    final secondMessages = transport.requests[1].messages;
    expect(jsonEncode(secondMessages), contains('FIRST ANSWER'));
    expect(
      secondMessages.last['content'],
      contains('Task (follow-up):\nsecond task'),
    );
    // P1-6: every run gets a fresh image policy, never the parent's or a
    // previous helper run's instance.
    expect(transport.calls[0].stream, isTrue);
    expect(transport.calls[0].policy, isNotNull);
    expect(transport.calls[1].policy, isNotNull);
    expect(
      identical(transport.calls[0].policy, transport.calls[1].policy),
      isFalse,
    );
  });

  testWidgets('the wrap-up round is text-only and has no image policy', (
    tester,
  ) async {
    final transport = _Transport()..toolCall = true;
    final service = await _buildService(tester, transport);
    final handler = _handler(service, 'c4');

    final result = await tester.runAsync(
      () => handler(spawnSubagentToolName, {
        'task': 'wrap up',
        'max_steps': 1,
      }, toolCallId: 'call-4'),
    );
    final json = jsonDecode(result!) as Map;
    expect(json['status'], 'max_steps');
    expect(json['summary'], contains('WRAP-UP'));
    expect(json['summary_source'], 'wrap_up');
    expect(transport.calls, hasLength(2));
    expect(transport.calls[0].stream, isTrue);
    expect(transport.calls[0].policy, isNotNull);
    expect(transport.calls[1].stream, isFalse);
    expect(transport.calls[1].policy, isNull);
  });

  testWidgets('a cancelled run returns no session id', (tester) async {
    final transport = _Transport()..hang = true;
    addTearDown(transport.hangStream.close);
    final service = await _buildService(
      tester,
      transport,
      cancel: (_) {
        if (!transport.hangStream.isClosed) transport.hangStream.close();
      },
    );
    final handler = _handler(service, 'c3');

    final result = await tester.runAsync(() async {
      final run = handler(spawnSubagentToolName, {
        'task': 'cancel me',
      }, toolCallId: 'call-3');
      while (transport.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      service.cancelActiveShellRuns();
      return run.timeout(const Duration(seconds: 5));
    });
    final json = jsonDecode(result!) as Map;
    expect(json['status'], 'stopped');
    expect(json.containsKey('session_id'), isFalse);
    expect(SubagentSessionStore.shared.length, 0);
  });

  testWidgets('a transport error returns no session id', (tester) async {
    final transport = _Transport()..fail = true;
    final service = await _buildService(tester, transport);
    final handler = _handler(service, 'c2');

    final result = await tester.runAsync(
      () => handler(spawnSubagentToolName, {
        'task': 'fail me',
      }, toolCallId: 'call-3'),
    );
    final json = jsonDecode(result!) as Map;
    expect(json['status'], 'error');
    expect(json.containsKey('session_id'), isFalse);
    expect(SubagentSessionStore.shared.length, 0);
  });
}
