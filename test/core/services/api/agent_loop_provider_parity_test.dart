// Per-provider follow-up parity for the agent-loop kernel (IMPORT_PLAN_COWORK.md
// P0-3 後段).
//
// The legacy transport loop preserves provider continuation state on its
// follow-up request:
//   - Claude: thinking / redacted_thinking blocks (with signatures) must be
//     echoed when thinking is enabled, or Anthropic rejects the request;
//   - Gemini 3: the functionCall part must carry its thought signature.
//
// In expose mode the transport now attaches that state to the toolCalls chunk
// via `assistantExtras`, the kernel merges it onto the neutral assistant
// message, and the per-provider converters re-attach it. These tests run the
// legacy loop and the kernel on the same scenario and assert the follow-up
// request bodies are equal round-for-round.

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
      'kernel follow-up echoes the thinking block like the legacy loop',
      () async {
        // 1. Legacy loop as reference.
        await ChatApiService.sendMessageStream(
          config: claudeConfig(),
          modelId: 'claude-test',
          messages: const [
            {'role': 'user', 'content': 'read c.txt'},
          ],
          stream: false,
          requestId: 'legacy-claude',
          onToolCall: (name, args) async => 'FILE_BODY_42',
        ).toList();
        expect(fix.bodies, hasLength(2));
        final legacyFollowUp = fix.bodies[1];

        // The legacy follow-up must itself carry the thinking block — guard
        // against a fixture that accidentally drops it.
        final legacyAssistant =
            (legacyFollowUp['messages'] as List).lastWhere(
                  (m) => m is Map && m['role'] == 'assistant',
                )
                as Map<String, dynamic>;
        expect(
          legacyAssistant['content'],
          contains(
            predicate(
              (b) =>
                  b is Map &&
                  b['type'] == 'thinking' &&
                  b['signature'] == 'sig_abc123',
            ),
          ),
        );

        // 2. Kernel run on the same scenario.
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
            onToolCall: null,
            exposeToolCallsOnly: true,
          ),
          onToolCall: (call) async => 'FILE_BODY_42',
        ).toList();

        // bodies: [0]=legacy r1, [1]=legacy follow-up, [2]=kernel r1,
        // [3]=kernel follow-up.
        expect(fix.bodies, hasLength(4));
        expect(fix.bodies[2], fix.bodies[0]);
        expect(fix.bodies[3]['messages'], legacyFollowUp['messages']);
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
      'kernel follow-up carries the thought signature like the legacy loop',
      () async {
        // 1. Legacy loop as reference.
        await ChatApiService.sendMessageStream(
          config: googleConfig(),
          modelId: 'gemini-3-test',
          messages: const [
            {'role': 'user', 'content': 'read d.txt'},
          ],
          stream: false,
          requestId: 'legacy-gemini',
          onToolCall: (name, args) async => 'FILE_BODY_42',
        ).toList();
        expect(fix.bodies, hasLength(2));
        final legacyFollowUp = fix.bodies[1];

        // The legacy follow-up's model turn must carry the thought signature.
        final legacyModelTurns = (legacyFollowUp['contents'] as List).where(
          (m) => m is Map && m['role'] == 'model',
        );
        expect(legacyModelTurns, isNotEmpty);
        final parts = (legacyModelTurns.first as Map)['parts'] as List;
        expect(parts.first, containsPair('thoughtSignature', 'sig_xyz789'));

        // 2. Kernel run on the same scenario.
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
            onToolCall: null,
            exposeToolCallsOnly: true,
          ),
          onToolCall: (call) async => 'FILE_BODY_42',
        ).toList();

        expect(fix.bodies, hasLength(4));
        expect(fix.bodies[2], fix.bodies[0]);
        expect(fix.bodies[3]['contents'], legacyFollowUp['contents']);
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
      'kernel follow-up replays the raw output items like the legacy loop',
      () async {
        // 1. Legacy loop as reference.
        await ChatApiService.sendMessageStream(
          config: responsesConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'read r.txt'},
          ],
          stream: true,
          requestId: 'legacy-responses',
          onToolCall: (name, args) async => 'FILE_BODY_42',
        ).toList();
        expect(fix.bodies, hasLength(2));
        final legacyFollowUp = fix.bodies[1];

        // The legacy follow-up input must replay the assistant message item
        // verbatim — guard against a fixture that accidentally drops it.
        final legacyInput = legacyFollowUp['input'] as List;
        expect(
          legacyInput,
          contains(predicate((i) => i is Map && i['type'] == 'message')),
        );
        expect(
          legacyInput,
          contains(
            predicate((i) => i is Map && i['type'] == 'function_call_output'),
          ),
        );

        // 2. Kernel run on the same scenario.
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
            onToolCall: null,
            exposeToolCallsOnly: true,
          ),
          onToolCall: (call) async => 'FILE_BODY_42',
        ).toList();

        // bodies: [0]=legacy r1, [1]=legacy follow-up, [2]=kernel r1,
        // [3]=kernel follow-up.
        expect(fix.bodies, hasLength(4));
        expect(fix.bodies[2], fix.bodies[0]);
        expect(fix.bodies[3]['input'], legacyFollowUp['input']);
      },
    );
  });
}
