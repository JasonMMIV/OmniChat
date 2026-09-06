// Single-round expose-mode tests (IMPORT_PLAN_COWORK.md P0-3).
//
// With `exposeToolCallsOnly: true`, `ChatApiService.sendMessageStream` must
// behave as exactly one transport request per call:
//   - collected tool calls are surfaced as a `toolCalls` chunk,
//   - the tool is NOT executed (`onToolCall` never fires),
//   - no follow-up request is issued,
// and with the flag left at its default `false`, the legacy multi-round loop
// must remain untouched (covered by `agent_loop_followup_parity_test.dart`).

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderConfig _config(String baseUrl) => ProviderConfig(
  id: 'test',
  enabled: true,
  name: 'test',
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  models: const ['gpt-test'],
);

class _Server {
  final List<Map<String, dynamic>> bodies = [];
  bool sse = false;
  // 'normal' = finish_reason tool_calls + [DONE];
  // 'no-done' = finish_reason stop + tool_calls, stream closes without
  // [DONE] (vendor fallback path exercised by the expose-mode short-circuit).
  // 'responses' = OpenAI /responses SSE events (function_call item + args
  // deltas + completed), exercising the Responses tool surfacing block.
  String scenario = 'normal';

  late HttpServer server;
  late String baseUrl;

  Future<void> start({required bool sse, String scenario = 'normal'}) async {
    this.sse = sse;
    this.scenario = scenario;
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

    if (sse) {
      req.response.headers.contentType = ContentType.parse('text/event-stream');
      if (scenario == 'responses') {
        // OpenAI /responses stream: output_item.added (function_call),
        // function_call_arguments.delta fragments, output_item.done with the
        // complete arguments, then response.completed (usage). The tool-call
        // surfacing happens while processing `response.completed`, so expose
        // mode must return right there without any follow-up request.
        req.response.write(
          [
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
                'usage': {'input_tokens': 5, 'output_tokens': 5, 'total_tokens': 10},
              },
            })}',
            '',
          ].join('\n'),
        );
        await req.response.close();
        return;
      }
      if (scenario == 'no-done') {
        // finish_reason='stop' with pending tool calls and no [DONE] marker:
        // the vendor-fallback block must surface the calls and stop.
        req.response.write(
          [
            'data: ${jsonEncode({
              'id': '1',
              'object': 'chat.completion.chunk',
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_nd1',
                        'type': 'function',
                        'function': {'name': 'file_read', 'arguments': '{"path": "nd.txt"}'},
                      },
                    ],
                  },
                  'finish_reason': 'stop',
                },
              ],
            })}',
            '',
          ].join('\n'),
        );
        await req.response.close();
        return;
      }
      req.response.write(
        [
          'data: ${jsonEncode({
            'id': '1',
            'object': 'chat.completion.chunk',
            'choices': [
              {
                'index': 0,
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_s1',
                      'type': 'function',
                      'function': {'name': 'file_read', 'arguments': '{"path": "b.txt"}'},
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          })}',
          'data: ${jsonEncode({
            'id': '1',
            'object': 'chat.completion.chunk',
            'choices': [
              {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'},
            ],
          })}',
          'data: ${jsonEncode({
            'id': '1',
            'object': 'chat.completion.chunk',
            'choices': <dynamic>[],
            'usage': {'prompt_tokens': 5, 'completion_tokens': 5, 'total_tokens': 10},
          })}',
          'data: [DONE]',
          '',
        ].join('\n'),
      );
    } else {
      req.response.headers.contentType = ContentType.parse('application/json');
      req.response.write(
        jsonEncode({
          'id': '1',
          'object': 'chat.completion',
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'call_n1',
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
          'usage': {
            'prompt_tokens': 5,
            'completion_tokens': 5,
            'total_tokens': 10,
          },
        }),
      );
    }
    await req.response.close();
  }
}

void main() {
  late _Server fix;

  setUp(() async {
    fix = _Server();
  });

  tearDown(() async {
    await fix.stop();
  });

  test(
    'non-stream: one request, toolCalls surfaced, nothing executed',
    () async {
      await fix.start(sse: false);
      var executed = 0;

      final chunks = await ChatApiService.sendMessageStream(
        config: _config(fix.baseUrl),
        modelId: 'gpt-test',
        messages: const [
          {'role': 'user', 'content': 'read a.txt'},
        ],
        stream: false,
        requestId: 'expose-ns',
        exposeToolCallsOnly: true,
        onToolCall: (name, args) async {
          executed++;
          return 'BODY';
        },
      ).toList();

      expect(executed, 0, reason: 'expose mode must never execute tools');
      expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
      final callChunks = chunks
          .where((c) => (c.toolCalls ?? const []).isNotEmpty)
          .toList();
      expect(callChunks, hasLength(1));
      final call = callChunks.single.toolCalls!.single;
      expect(call.id, 'call_n1');
      expect(call.name, 'file_read');
      expect(call.arguments, <String, dynamic>{'path': 'a.txt'});
      expect(
        chunks.where((c) => (c.toolResults ?? const []).isNotEmpty),
        isEmpty,
      );
    },
  );

  test('stream: one request, toolCalls surfaced, nothing executed', () async {
    await fix.start(sse: true);
    var executed = 0;

    final chunks = await ChatApiService.sendMessageStream(
      config: _config(fix.baseUrl),
      modelId: 'gpt-test',
      messages: const [
        {'role': 'user', 'content': 'read b.txt'},
      ],
      stream: true,
      requestId: 'expose-st',
      exposeToolCallsOnly: true,
      onToolCall: (name, args) async {
        executed++;
        return 'BODY';
      },
    ).toList();

    expect(executed, 0, reason: 'expose mode must never execute tools');
    expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
    final callChunks = chunks
        .where((c) => (c.toolCalls ?? const []).isNotEmpty)
        .toList();
    expect(callChunks, hasLength(1));
    final call = callChunks.single.toolCalls!.single;
    expect(call.id, 'call_s1');
    expect(call.name, 'file_read');
    expect(call.arguments, <String, dynamic>{'path': 'b.txt'});
    expect(
      chunks.where((c) => (c.toolResults ?? const []).isNotEmpty),
      isEmpty,
    );
  });

  test('stream no-DONE vendor fallback: one request, toolCalls surfaced, '
      'nothing executed', () async {
    await fix.start(sse: true, scenario: 'no-done');
    var executed = 0;

    final chunks = await ChatApiService.sendMessageStream(
      config: _config(fix.baseUrl),
      modelId: 'gpt-test',
      messages: const [
        {'role': 'user', 'content': 'read nd.txt'},
      ],
      stream: true,
      requestId: 'expose-nd',
      exposeToolCallsOnly: true,
      onToolCall: (name, args) async {
        executed++;
        return 'BODY';
      },
    ).toList();

    expect(executed, 0, reason: 'expose mode must never execute tools');
    expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
    final callChunks = chunks
        .where((c) => (c.toolCalls ?? const []).isNotEmpty)
        .toList();
    expect(callChunks, hasLength(1));
    final call = callChunks.single.toolCalls!.single;
    expect(call.id, 'call_nd1');
    expect(call.name, 'file_read');
    expect(call.arguments, <String, dynamic>{'path': 'nd.txt'});
    expect(
      chunks.where((c) => (c.toolResults ?? const []).isNotEmpty),
      isEmpty,
    );
  });

  test(
    'Responses stream: one request, toolCalls surfaced, nothing executed',
    () async {
      await fix.start(sse: true, scenario: 'responses');
      var executed = 0;

      final chunks = await ChatApiService.sendMessageStream(
        config: _config(fix.baseUrl).copyWith(useResponseApi: true),
        modelId: 'gpt-test',
        messages: const [
          {'role': 'user', 'content': 'read r.txt'},
        ],
        stream: true,
        requestId: 'expose-resp',
        exposeToolCallsOnly: true,
        onToolCall: (name, args) async {
          executed++;
          return 'BODY';
        },
      ).toList();

      expect(executed, 0, reason: 'expose mode must never execute tools');
      expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
      final callChunks = chunks
          .where((c) => (c.toolCalls ?? const []).isNotEmpty)
          .toList();
      expect(callChunks, hasLength(1));
      final call = callChunks.single.toolCalls!.single;
      expect(call.id, 'call_r1');
      expect(call.name, 'file_read');
      expect(call.arguments, <String, dynamic>{'path': 'r.txt'});
      expect(
        chunks.where((c) => (c.toolResults ?? const []).isNotEmpty),
        isEmpty,
      );
    },
  );
}
