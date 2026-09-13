// Single-round expose-mode tests (IMPORT_PLAN_COWORK.md P0-3).
//
// With `exposeToolCallsOnly: true`, `ChatApiService.sendMessageStream` must
// behave as exactly one transport request per call:
//   - collected tool calls are surfaced as a `toolCalls` chunk,
//   - the tool is NOT executed (`onToolCall` never fires),
//   - no follow-up request is issued,
//   - the L1 retry loop must NOT re-request the round when the server closes
//     the SSE body right after the calls are surfaced — surfacing the calls is
//     the round's completion (silent-interrupt false-positive regression,
//     standard voice mode answered 4×).
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
  // 'bare' = tool_calls deltas with NO finish_reason and NO [DONE] — the
  // worst-case vendor stream; the expose-mode flags sync must mark the
  // surfaced round as complete so the L1 loop does not re-request it.
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
      if (scenario == 'voice-no-fr') {
        // Voice-mode legacy-loop scenario. Request 1: the model streams a
        // search tool call with NO finish_reason (the vendor class the
        // [DONE] handler anticipates) and ends with [DONE]. Request 2
        // (follow-up): a clean answer with finish_reason='stop' and [DONE].
        if (bodies.length == 1) {
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
                          'id': 'call_v1',
                          'type': 'function',
                          'function': {
                            'name': 'search_web',
                            'arguments': '{"query": "weather"}',
                          },
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
        } else {
          req.response.write(
            [
              'data: ${jsonEncode({
                'id': '2',
                'object': 'chat.completion.chunk',
                'choices': [
                  {
                    'index': 0,
                    'delta': {
                      'content': 'Good evening! How can I help you today?',
                    },
                    'finish_reason': null,
                  },
                ],
              })}',
              'data: ${jsonEncode({
                'id': '2',
                'object': 'chat.completion.chunk',
                'choices': [
                  {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
                ],
                'usage': {
                  'prompt_tokens': 5,
                  'completion_tokens': 5,
                  'total_tokens': 10,
                },
              })}',
              'data: [DONE]',
              '',
            ].join('\n'),
          );
        }
        await req.response.close();
        return;
      }
      if (scenario == 'done-no-fr') {
        // Tool-call deltas with [DONE] but NO finish_reason anywhere —
        // the vendor class the [DONE] handler anticipates. Expose mode
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
        onToolCall: (name, args, {String? toolCallId}) async {
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
      onToolCall: (name, args, {String? toolCallId}) async {
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
      onToolCall: (name, args, {String? toolCallId}) async {
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

  test('stream cut after toolCalls surfaced: no L1 silent-interrupt '
      're-request', () async {
    // Regression (2026-09-13): a vendor may close the SSE body right after
    // the tool_calls deltas with a [DONE] marker but WITHOUT any
    // finish_reason. The [DONE] handler's own comment anticipates exactly
    // this vendor class ("model streamed tool_calls but didn't include
    // finish_reason on prior chunks"). Surfacing the calls IS the round's
    // completion — before the fix the retry loop classified that as
    // `stream-interrupted` and reissued the identical request up to 4×
    // (voice mode answered the same question 4×).
    await fix.start(sse: true, scenario: 'done-no-fr');
    var executed = 0;

    final chunks = await ChatApiService.sendMessageStream(
      config: _config(fix.baseUrl),
      modelId: 'gpt-test',
      messages: const [
        {'role': 'user', 'content': 'read nd.txt'},
      ],
      stream: true,
      requestId: 'expose-done-no-fr',
      exposeToolCallsOnly: true,
      onToolCall: (name, args, {String? toolCallId}) async {
        executed++;
        return 'BODY';
      },
    ).toList();

    final callChunks = chunks
        .where((c) => (c.toolCalls ?? const []).isNotEmpty)
        .toList();
    expect(callChunks, hasLength(1), reason: 'the toolCalls chunk is surfaced');
    expect(executed, 0);
    // The fix: exactly ONE transport request. Without the finish-marker sync
    // on the expose return, the silent-interrupt detector re-requests 4×.
    expect(fix.bodies, hasLength(1));
  });

  test(
    'legacy voice-mode tool round without finish_reason: one follow-up, '
    'no L1 silent-interrupt re-request',
    () async {
      // Regression (2026-09-13, standard voice mode answered 4×): the voice
      // path (ChatTurnService → sendMessageStream with onToolCall, NO
      // exposeToolCallsOnly) drains the legacy multi-round transport loop to
      // completion. Round 1 here streams tool_calls deltas with NO
      // finish_reason and NO [DONE] (the vendor class the [DONE] handler's
      // own comment anticipates); round 2 answers with finish_reason='stop'
      // and [DONE]. The follow-up round's finish reason is parsed into a
      // LOCAL variable (finishReason2) that never passes through the
      // per-chunk flags sync — so before the legacy-loop flags sync the
      // whole transport return left flags.finishReason == null, the L1
      // silent-interruption detector classified the completed turn as a
      // dropped stream, and the retry loop re-issued the ORIGINAL request
      // up to 4×, appending each attempt's full answer to the same message.
      await fix.start(sse: true, scenario: 'voice-no-fr');
      var executed = 0;

      final chunks = await ChatApiService.sendMessageStream(
        config: _config(fix.baseUrl),
        modelId: 'gpt-test',
        messages: const [
          {'role': 'user', 'content': 'search the web'},
        ],
        stream: true,
        requestId: 'legacy-voice',
        onToolCall: (name, args, {String? toolCallId}) async {
          executed++;
          return 'SEARCH_RESULTS';
        },
      ).toList();

      expect(executed, 1, reason: 'the tool is executed exactly once');
      // Exactly two transport requests: round 1 (tool call) + round 2
      // (follow-up answer). Before the fix the L1 loop re-issued the whole
      // sequence up to 4× (8 requests, 4 duplicated answers).
      expect(fix.bodies, hasLength(2));
      // One answer — not four concatenated ones.
      final visible = chunks
          .where((c) => c.content.isNotEmpty)
          .map((c) => c.content)
          .join();
      expect(visible, 'Good evening! How can I help you today?');
      expect(chunks.where((c) => c.isDone), hasLength(1));
      expect(
        chunks.where((c) => c.errorKind != null && c.attempt != null),
        isEmpty,
        reason: 'no L1 retry chunk may be emitted for a clean turn',
      );
      final followUp = fix.bodies[1]['messages'] as List;
      expect(
        followUp.where((m) => m is Map && m['role'] == 'tool'),
        hasLength(1),
        reason: 'the follow-up carries the executed tool result',
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

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
        onToolCall: (name, args, {String? toolCallId}) async {
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
