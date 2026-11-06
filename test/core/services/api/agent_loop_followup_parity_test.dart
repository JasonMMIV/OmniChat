// Follow-up body parity for the agent-loop kernel (IMPORT_PLAN_COWORK.md
// P0-4/P0-6.2, finalized by P0-3).
//
// The transport is single-round: the kernel executes the round's tool calls and
// composes the follow-up request from OpenAI-neutral messages
// (`assistant(tool_calls)` + `role:'tool'`) plus the transport's reasoning-echo
// fields (`assistantExtras`). This test drives the real kernel over an
// in-process HTTP server and asserts:
//
//   1. the executed tool call matches the round's script,
//   2. the follow-up `messages` equal the kernel's `AgentNeutralMessages`
//      output plus the DeepSeek `reasoning_content` echo (P0-4),
//   3. the following round's body is exactly the documented golden.
//
// Scenario: DeepSeek-style chat-completions (reasoning model, tool round →
// final text round).

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// DeepSeek reasoning-capable model, routed through chat completions.
ProviderConfig _deepSeekConfig(String baseUrl) => ProviderConfig(
  id: 'test',
  enabled: true,
  name: 'test',
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  models: const ['deepseek-r'],
  modelOverrides: const {
    'deepseek-r': {
      'apiModelId': 'deepseek-chat',
      'type': 'chat',
      'input': ['text'],
      'output': ['text'],
      'abilities': ['tool', 'reasoning'],
    },
  },
);

/// Responds to request 1 with a tool-call turn (with reasoning_content), and
/// to request 2 with a plain text turn. Captures every request body.
class _CaptureServer {
  final List<Map<String, dynamic>> bodies = [];

  late HttpServer server;
  late String baseUrl;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen(_handle);
  }

  Future<void> stop() async {
    await server.close(force: true);
  }

  Map<String, dynamic> _usage() => {
    'prompt_tokens': 5,
    'completion_tokens': 5,
    'total_tokens': 10,
  };

  void _handle(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    try {
      bodies.add(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      bodies.add(<String, dynamic>{'__raw': raw});
    }

    req.response.headers.contentType = ContentType.parse('application/json');
    // Alternate: odd-numbered requests (1st, 3rd, …) get the tool-call turn,
    // even-numbered get the final text turn — so both the legacy loop and a
    // subsequent kernel run see the same round sequence on one server.
    if (bodies.length.isOdd) {
      // Round 1: reasoning + a tool call.
      req.response.write(
        jsonEncode({
          'id': '1',
          'object': 'chat.completion',
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': '',
                'reasoning_content': 'let me think about reading the file',
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'file_read',
                      'arguments': '{"path": "a.txt"}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
          'usage': _usage(),
        }),
      );
    } else {
      // Round 2: final text answer (no tool calls).
      req.response.write(
        jsonEncode({
          'id': '2',
          'object': 'chat.completion',
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'done'},
              'finish_reason': 'stop',
            },
          ],
          'usage': _usage(),
        }),
      );
    }
    await req.response.close();
  }
}

void main() {
  late _CaptureServer fix;

  setUp(() async {
    fix = _CaptureServer();
    await fix.start();
  });

  tearDown(() async {
    await fix.stop();
  });

  test(
    'follow-up body equals kernel neutral messages + reasoning echo',
    () async {
      final executed = <String>[];
      final chunks = await runAgentLoop(
        messages: const [
          {'role': 'user', 'content': 'read a.txt'},
        ],
        sendRound: (msgs) async => ChatApiService.sendMessageStream(
          config: _deepSeekConfig(fix.baseUrl),
          modelId: 'deepseek-r',
          messages: msgs,
          stream: false,
          requestId: 'req-echo',
        ),
        onToolCall: (call) async {
          executed.add('${call.name}:${call.arguments['path']}');
          return 'FILE_BODY_42';
        },
      ).toList();

      // 1. The tool call from round 1 was executed exactly once.
      expect(executed, <String>['file_read:a.txt']);

      // 2. A follow-up request was issued and completed.
      expect(fix.bodies, hasLength(2));
      expect(
        chunks.whereType<AgentStreamEvent>().any((e) => e.chunk.isDone),
        isTrue,
      );

      // 3. Kernel parity: reconstruct what the kernel would have appended.
      const call = AgentToolCall(
        toolCallId: 'call_1',
        name: 'file_read',
        arguments: <String, dynamic>{'path': 'a.txt'},
      );
      final kernelAssistant = AgentNeutralMessages.assistantMessage(
        calls: const <AgentToolCall>[call],
      );
      final kernelTool = AgentNeutralMessages.toolResultMessage(
        call: call,
        result: 'FILE_BODY_42',
      );

      final followUpMessages = fix.bodies[1]['messages'] as List<dynamic>;
      expect(followUpMessages, hasLength(3));

      // The assistant tool_calls message matches the kernel's neutral shape;
      // the DeepSeek reasoning_content echo is merged by the kernel from the
      // transport's `assistantExtras` (it is provider-owned, so the neutral
      // builder itself does not carry it).
      final followUpAssistant = followUpMessages[1] as Map<String, dynamic>;
      expect(followUpAssistant['role'], 'assistant');
      expect(followUpAssistant['content'], '\n\n');
      expect(followUpAssistant['tool_calls'], kernelAssistant['tool_calls']);
      expect(
        followUpAssistant['reasoning_content'],
        'let me think about reading the file',
      );
      expect(
        kernelAssistant.containsKey('reasoning_content'),
        isFalse,
        reason:
            'the neutral builder stays provider-agnostic; extras ride the chunk',
      );

      // The role:'tool' message matches the kernel's byte-for-byte.
      final followUpTool = followUpMessages[2] as Map<String, dynamic>;
      expect(followUpTool, kernelTool);

      // 4. The initial user message is preserved unchanged.
      expect(followUpMessages[0], <String, dynamic>{
        'role': 'user',
        'content': 'read a.txt',
      });
    },
  );

  test(
    'kernel run issues the expected follow-up request body',
    () async {
      // P0-2/P0-4 contract: the kernel's follow-up body is the parity
      // contract — including the reasoning echo, which rides the chunk's
      // `assistantExtras` channel.
      var kernelExecuted = 0;
      await runAgentLoop(
        messages: const [
          {'role': 'user', 'content': 'read a.txt'},
        ],
        sendRound: (msgs) async => ChatApiService.sendMessageStream(
          config: _deepSeekConfig(fix.baseUrl),
          modelId: 'deepseek-r',
          messages: msgs,
          stream: false,
          requestId: 'req-kernel',
        ),
        onToolCall: (call) async {
          kernelExecuted++;
          return 'FILE_BODY_42';
        },
      ).toList();
      expect(kernelExecuted, 1);

      // bodies: [0]=round 1, [1]=follow-up.
      expect(fix.bodies, hasLength(2));
      final kernelFollowUp = fix.bodies[1];
      const call = AgentToolCall(
        toolCallId: 'call_1',
        name: 'file_read',
        arguments: <String, dynamic>{'path': 'a.txt'},
      );
      expect(kernelFollowUp['messages'], <Map<String, dynamic>>[
        {'role': 'user', 'content': 'read a.txt'},
        {
          ...AgentNeutralMessages.assistantMessage(
            calls: const <AgentToolCall>[call],
          ),
          'reasoning_content': 'let me think about reading the file',
        },
        AgentNeutralMessages.toolResultMessage(
          call: call,
          result: 'FILE_BODY_42',
        ),
      ]);

      // 3. The reasoning echo arrived via assistantExtras (P0-4 closed).
      final kernelMsgs = kernelFollowUp['messages'] as List<dynamic>;
      final kernelAssistant = kernelMsgs[1] as Map<String, dynamic>;
      expect(
        kernelAssistant['reasoning_content'],
        'let me think about reading the file',
      );
    },
  );
}
