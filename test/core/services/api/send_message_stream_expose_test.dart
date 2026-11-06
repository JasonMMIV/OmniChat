// Single-round transport tests (IMPORT_PLAN_COWORK.md P0-3).
//
// `ChatApiService.sendMessageStream` performs exactly one transport request per
// call — it never executes tools and never issues a follow-up:
//   - collected tool calls are surfaced as a `toolCalls` chunk,
//   - no `toolResults` chunk is ever emitted,
//   - no follow-up request is issued,
//   - the L1 retry loop must NOT re-request the round when the server closes
//     the SSE body right after the calls are surfaced — surfacing the calls is
//     the round's completion (silent-interrupt false-positive regression,
//     standard voice mode answered 4×).
// Tool execution now lives in the kernel (`AgentOrchestrator`).

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
  // [DONE] (vendor fallback path exercised by the surfacing short-circuit).
  // 'bare' = tool_calls deltas with NO finish_reason and NO [DONE] — the
  // worst-case vendor stream; the flags sync must mark the surfaced round as
  // complete so the L1 loop does not re-request it.
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
        // surfacing happens while processing `response.completed`, so the
        // transport must return right there without any follow-up request.
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
      if (scenario == 'done-no-fr') {
        // Tool-call deltas with [DONE] but NO finish_reason anywhere —
        // the vendor class the [DONE] handler anticipates. The transport
        // must surface the calls and the L1 loop must not classify the
        // round as interrupted.
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
                        'id': 'call_b1',
                        'type': 'function',
                        'function': {'name': 'file_read', 'arguments': '{"path": "bare.txt"}'},
                      },
                    ],
                  },
                  'finish_reason': null,
                },
              ],
            })}',
            'data: [DONE]',
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

  test('non-stream: one request, toolCalls surfaced, no toolResults', () async {
    await fix.start(sse: false);

    final chunks = await ChatApiService.sendMessageStream(
      config: _config(fix.baseUrl),
      modelId: 'gpt-test',
      messages: const [
        {'role': 'user', 'content': 'read a.txt'},
      ],
      stream: false,
      requestId: 'expose-ns',
    ).toList();

    expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
    final callChunks = chunks
        .where((c) => (c.toolCalls ?? const []).isNotEmpty)
        .toList();
    expect(callChunks, hasLength(1));
    final call = callChunks.single.toolCalls!.single;
    expect(call.id, 'call_n1');
    expect(call.name, 'file_read');
    expect(call.arguments, <String, dynamic>{'path': 'a.txt'});
    expect(chunks.where((c) => (c.toolResults ?? const []).isNotEmpty), isEmpty);
  });

  test('stream: one request, toolCalls surfaced, no toolResults', () async {
    await fix.start(sse: true);

    final chunks = await ChatApiService.sendMessageStream(
      config: _config(fix.baseUrl),
      modelId: 'gpt-test',
      messages: const [
        {'role': 'user', 'content': 'read b.txt'},
      ],
      stream: true,
      requestId: 'expose-st',
    ).toList();

    expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
    final callChunks = chunks
        .where((c) => (c.toolCalls ?? const []).isNotEmpty)
        .toList();
    expect(callChunks, hasLength(1));
    final call = callChunks.single.toolCalls!.single;
    expect(call.id, 'call_s1');
    expect(call.name, 'file_read');
    expect(call.arguments, <String, dynamic>{'path': 'b.txt'});
    expect(chunks.where((c) => (c.toolResults ?? const []).isNotEmpty), isEmpty);
  });

  test(
    'stream no-DONE vendor fallback: one request, toolCalls surfaced',
    () async {
      await fix.start(sse: true, scenario: 'no-done');

      final chunks = await ChatApiService.sendMessageStream(
        config: _config(fix.baseUrl),
        modelId: 'gpt-test',
        messages: const [
          {'role': 'user', 'content': 'read nd.txt'},
        ],
        stream: true,
        requestId: 'expose-nd',
      ).toList();

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
    },
  );

  test(
    'stream cut after toolCalls surfaced: no L1 silent-interrupt re-request',
    () async {
      // Regression (2026-09-13): a vendor may close the SSE body right after
      // the tool_calls deltas with a [DONE] marker but WITHOUT any
      // finish_reason. The [DONE] handler's own comment anticipates exactly
      // this vendor class ("model streamed tool_calls but didn't include
      // finish_reason on prior chunks"). Surfacing the calls IS the round's
      // completion — before the fix the retry loop classified that as
      // `stream-interrupted` and reissued the identical request up to 4×
      // (voice mode answered the same question 4×).
      await fix.start(sse: true, scenario: 'done-no-fr');

      final chunks = await ChatApiService.sendMessageStream(
        config: _config(fix.baseUrl),
        modelId: 'gpt-test',
        messages: const [
          {'role': 'user', 'content': 'read nd.txt'},
        ],
        stream: true,
        requestId: 'expose-done-no-fr',
      ).toList();

      final callChunks = chunks
          .where((c) => (c.toolCalls ?? const []).isNotEmpty)
          .toList();
      expect(callChunks, hasLength(1), reason: 'the toolCalls chunk is surfaced');
      // The fix: exactly ONE transport request. Without the finish-marker sync
      // on the surfacing return, the silent-interrupt detector re-requests 4×.
      expect(fix.bodies, hasLength(1));
    },
  );

  test('Responses stream: one request, toolCalls surfaced', () async {
    await fix.start(sse: true, scenario: 'responses');

    final chunks = await ChatApiService.sendMessageStream(
      config: _config(fix.baseUrl).copyWith(useResponseApi: true),
      modelId: 'gpt-test',
      messages: const [
        {'role': 'user', 'content': 'read r.txt'},
      ],
      stream: true,
      requestId: 'expose-resp',
    ).toList();

    expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
    final callChunks = chunks
        .where((c) => (c.toolCalls ?? const []).isNotEmpty)
        .toList();
    expect(callChunks, hasLength(1));
    final call = callChunks.single.toolCalls!.single;
    expect(call.id, 'call_r1');
    expect(call.name, 'file_read');
    expect(call.arguments, <String, dynamic>{'path': 'r.txt'});
    expect(chunks.where((c) => (c.toolResults ?? const []).isNotEmpty), isEmpty);
  });
}
