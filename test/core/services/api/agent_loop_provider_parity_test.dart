// Per-provider follow-up parity for the agent-loop kernel (IMPORT_PLAN_COWORK.md
// P0-3 後段).
//
// The kernel's follow-up request must preserve provider continuation state:
//   - Claude: thinking / redacted_thinking blocks (with signatures) must be
//     echoed when thinking is enabled, or Anthropic rejects the request;
//   - Gemini 3: the functionCall part must carry its thought signature.
//
// The transport is single-round: it attaches that state to the toolCalls chunk
// via `assistantExtras`, the kernel merges it onto the neutral assistant
// message, and the per-provider converters re-attach it. These tests drive
// `runAgentLoop` and assert the shapes of the follow-up request bodies.

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures request bodies; alternates responses: odd-numbered requests get
/// the tool round, even-numbered the final text round.
class _CaptureServer {
  _CaptureServer({
    required this.toolResponse,
    required this.textResponse,
    this.sse = false,
  });

  final String toolResponse;
  final String textResponse;
  // SSE mode for providers whose tool-call path is streaming-only
  // (OpenAI Responses API).
  final bool sse;
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

  void _handle(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    try {
      bodies.add(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      bodies.add(<String, dynamic>{'__raw': raw});
    }
    req.response.headers.contentType = ContentType.parse(
      sse ? 'text/event-stream' : 'application/json',
    );
    req.response.write(bodies.length.isOdd ? toolResponse : textResponse);
    await req.response.close();
  }
}

void main() {
  group('Claude thinking-block parity', () {
    late _CaptureServer fix;

    setUp(() async {
      fix = _CaptureServer(
        toolResponse: jsonEncode({
          'id': 'msg_1',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {
              'type': 'thinking',
              'thinking': 'let me think about the file',
              'signature': 'sig_abc123',
            },
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'file_read',
              'input': {'path': 'c.txt'},
            },
          ],
          'stop_reason': 'tool_use',
          'stop_sequence': null,
          'usage': {'input_tokens': 5, 'output_tokens': 5},
        }),
        textResponse: jsonEncode({
          'id': 'msg_2',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'done'},
          ],
          'stop_reason': 'end_turn',
          'stop_sequence': null,
          'usage': {'input_tokens': 5, 'output_tokens': 5},
        }),
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    ProviderConfig claudeConfig() => ProviderConfig(
      id: 'claude-test',
      enabled: true,
      name: 'claude-test',
      apiKey: 'test-key',
      baseUrl: fix.baseUrl,
      providerType: ProviderKind.claude,
      models: const ['claude-test'],
      modelOverrides: const {
        'claude-test': {
          'type': 'chat',
          'input': ['text'],
          'output': ['text'],
          'abilities': ['tool', 'reasoning'],
        },
      },
    );

    test(
      'kernel follow-up echoes the thinking block',
      () async {
        // P0-3: transport is single-round; the kernel echoes the thinking
        // block on its follow-up assistant message.
        await runAgentLoop(
          messages: const [
            {'role': 'user', 'content': 'read c.txt'},
          ],
          sendRound: (msgs) async => ChatApiService.sendMessageStream(
            config: claudeConfig(),
            modelId: 'claude-test',
            messages: msgs,
            stream: false,
            requestId: 'kernel-claude',
          ),
          onToolCall: (call) async => 'FILE_BODY_42',
        ).toList();

        expect(fix.bodies, hasLength(2));
        final followUp = fix.bodies[1];
        final messages = (followUp['messages'] as List)
            .cast<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();

        // Full golden shape: user turn, assistant (thinking + tool_use),
        // user tool_result. Any converter drift fails here.
        expect(messages, hasLength(3));
        expect(messages[0]['role'], 'user');
        expect(messages[1]['role'], 'assistant');
        expect(
          (messages[1]['content'] as List)
              .map((b) => (b as Map).cast<String, dynamic>())
              .toList(),
          <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'thinking',
              'thinking': 'let me think about the file',
              'signature': 'sig_abc123',
            },
            <String, dynamic>{
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'file_read',
              'input': <String, dynamic>{'path': 'c.txt'},
            },
          ],
        );
        expect(messages[2]['role'], 'user');
        expect(
          (messages[2]['content'] as List).single,
          <String, dynamic>{
            'type': 'tool_result',
            'tool_use_id': 'toolu_1',
            'content': 'FILE_BODY_42',
          },
        );
      },
    );
  });

  group('Gemini thought-signature parity', () {
    late _CaptureServer fix;

    setUp(() async {
      fix = _CaptureServer(
        toolResponse: jsonEncode({
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {
                    'functionCall': {
                      'id': 'fc_1',
                      'name': 'file_read',
                      'args': {'path': 'd.txt'},
                    },
                    'thoughtSignature': 'sig_xyz789',
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 5,
            'candidatesTokenCount': 5,
            'totalTokenCount': 10,
          },
        }),
        textResponse: jsonEncode({
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {'text': 'done'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 5,
            'candidatesTokenCount': 5,
            'totalTokenCount': 10,
          },
        }),
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    ProviderConfig googleConfig() => ProviderConfig(
      id: 'google-test',
      enabled: true,
      name: 'google-test',
      apiKey: 'test-key',
      baseUrl: fix.baseUrl,
      providerType: ProviderKind.google,
      models: const ['gemini-3-test'],
    );

    test(
      'kernel follow-up carries the thought signature',
      () async {
        // P0-3: the transport is single-round; the kernel owns the follow-up
        // and must re-attach the thought signature to the functionCall part.
        await runAgentLoop(
          messages: const [
            {'role': 'user', 'content': 'read d.txt'},
          ],
          sendRound: (msgs) async => ChatApiService.sendMessageStream(
            config: googleConfig(),
            modelId: 'gemini-3-test',
            messages: msgs,
            stream: false,
            requestId: 'kernel-gemini',
          ),
          onToolCall: (call) async => 'FILE_BODY_42',
        ).toList();

        expect(fix.bodies, hasLength(2));
        final followUp = fix.bodies[1];
        final contents = (followUp['contents'] as List)
            .cast<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
        final modelIndex = contents.indexWhere((m) => m['role'] == 'model');
        expect(modelIndex, isNonNegative);
        // Exact golden: functionCall (with its vendor id) + thought signature.
        expect(
          (contents[modelIndex]['parts'] as List).first,
          <String, dynamic>{
            'functionCall': <String, dynamic>{
              'name': 'file_read',
              'args': <String, dynamic>{'path': 'd.txt'},
              'id': 'fc_1',
            },
            'thoughtSignature': 'sig_xyz789',
          },
        );
        // The tool result is replayed as a functionResponse turn.
        final functionResponse = contents.lastWhere(
          (m) => (m['parts'] as List).any(
            (p) => p is Map && p['functionResponse'] is Map,
          ),
        );
        expect(
          (functionResponse['parts'] as List).first,
          <String, dynamic>{
            'functionResponse': <String, dynamic>{
              'name': 'file_read',
              'response': <String, dynamic>{'result': 'FILE_BODY_42'},
            },
          },
        );
      },
    );
  });

  group('Responses output-item continuation parity', () {
    late _CaptureServer fix;

    setUp(() async {
      // The Responses tool-call path is streaming-only, so both rounds are
      // SSE. The tool round's `response.completed` carries `response.output`
      // (assistant message item + function_call item) — the raw output items
      // the legacy loop replays verbatim into the follow-up `input`.
      fix = _CaptureServer(
        sse: true,
        toolResponse: [
          'data: ${jsonEncode({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {'type': 'function_call', 'call_id': 'call_r1', 'name': 'file_read', 'arguments': ''},
          })}',
          'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'output_index': 0, 'delta': '{"path": '})}',
          'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'output_index': 0, 'delta': '"r.txt"}'})}',
          'data: ${jsonEncode({
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': {'type': 'function_call', 'call_id': 'call_r1', 'name': 'file_read', 'arguments': '{"path": "r.txt"}'},
          })}',
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'output_text', 'text': 'let me read r.txt'},
                  ],
                },
                {'type': 'function_call', 'call_id': 'call_r1', 'name': 'file_read', 'arguments': '{"path": "r.txt"}'},
              ],
              'usage': {'input_tokens': 5, 'output_tokens': 5},
            },
          })}',
          '',
        ].join('\n'),
        textResponse: [
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': 'done'})}',
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'usage': {'input_tokens': 5, 'output_tokens': 5},
            },
          })}',
          '',
        ].join('\n'),
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    ProviderConfig responsesConfig() => ProviderConfig(
      id: 'responses-test',
      enabled: true,
      name: 'responses-test',
      apiKey: 'test-key',
      baseUrl: fix.baseUrl,
      providerType: ProviderKind.openai,
      useResponseApi: true,
      models: const ['gpt-test'],
    );

    test(
      'kernel follow-up replays the raw output items',
      () async {
        // P0-3: the transport is single-round; the kernel owns the follow-up.
        await runAgentLoop(
          messages: const [
            {'role': 'user', 'content': 'read r.txt'},
          ],
          sendRound: (msgs) async => ChatApiService.sendMessageStream(
            config: responsesConfig(),
            modelId: 'gpt-test',
            messages: msgs,
            stream: true,
            requestId: 'kernel-responses',
          ),
          onToolCall: (call) async => 'FILE_BODY_42',
        ).toList();

        expect(fix.bodies, hasLength(2));
        final followUpInput = (fix.bodies[1]['input'] as List)
            .cast<Map>()
            .map((i) => i.cast<String, dynamic>())
            .toList();

        // Golden ordering: user turn → raw assistant `message` item →
        // replayed `function_call` → tool `function_call_output`.
        final messageIndex = followUpInput.indexWhere(
          (i) => i['type'] == 'message',
        );
        final callIndex = followUpInput.indexWhere(
          (i) => i['type'] == 'function_call' && i['call_id'] == 'call_r1',
        );
        final outputIndex = followUpInput.indexWhere(
          (i) => i['type'] == 'function_call_output' && i['call_id'] == 'call_r1',
        );
        expect(messageIndex, isNonNegative);
        expect(callIndex, greaterThan(messageIndex));
        expect(outputIndex, greaterThan(callIndex));

        // The raw assistant message item is replayed verbatim.
        final assistantItem = followUpInput[messageIndex];
        expect(assistantItem['role'], 'assistant');
        expect(
          (assistantItem['content'] as List).first,
          <String, dynamic>{
            'type': 'output_text',
            'text': 'let me read r.txt',
          },
        );
        // The tool output carries the kernel's executed result.
        expect(
          followUpInput[outputIndex]['output'],
          'FILE_BODY_42',
        );
      },
    );
  });
}
