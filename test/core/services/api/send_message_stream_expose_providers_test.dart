// Per-provider single-round transport tests (IMPORT_PLAN_COWORK.md P0-3).
//
// Same contract as `send_message_stream_expose_test.dart` but across the
// Claude and Gemini transports: each call is exactly one request, surfaces
// tool calls once, and never executes them. Provider-internal continuations
// that belong to the same turn (Claude `pause_turn` / server tools) are still
// allowed and covered below.

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/services/api/gemini_signature_scope.dart';
import 'package:flutter_test/flutter_test.dart';

class _Server {
  final List<Map<String, dynamic>> bodies = [];
  final List<List<String>> responses;
  final String pathHint;
  final bool sse;

  _Server({required this.responses, required this.pathHint, required this.sse});

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
    // If the transport ever issued a follow-up request, fail loudly by
    // returning an empty body (test asserts bodies.length == 1 anyway).
    final response = bodies.length <= responses.length
        ? responses[bodies.length - 1]
        : <String>[];
    if (sse) {
      req.response.headers.contentType = ContentType.parse('text/event-stream');
      req.response.write(response.join('\n'));
    } else {
      req.response.headers.contentType = ContentType.parse('application/json');
      req.response.write(response.join(''));
    }
    await req.response.close();
  }
}

void main() {
  group('Claude pause_turn continuation', () {
    late _Server fix;

    List<String> _textRound(String text, String stopReason) => [
      'data: ${jsonEncode({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text', 'text': ''},
      })}',
      '',
      'data: ${jsonEncode({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': text},
      })}',
      '',
      'data: ${jsonEncode({'type': 'content_block_stop', 'index': 0})}',
      '',
      'data: ${jsonEncode({
        'type': 'message_delta',
        'delta': {'stop_reason': stopReason},
        'usage': {'input_tokens': 5, 'output_tokens': 5},
      })}',
      '',
      'data: ${jsonEncode({'type': 'message_stop'})}',
      '',
    ];

    setUp(() async {
      fix = _Server(
        pathHint: 'messages',
        sse: true,
        responses: [
          _textRound('Searching...', 'pause_turn'),
          _textRound('Done.', 'end_turn'),
        ],
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    test('one internal continuation, then the turn finishes', () async {
      final config = ProviderConfig(
        id: 'claude-test',
        enabled: true,
        name: 'claude-test',
        apiKey: 'test-key',
        baseUrl: fix.baseUrl,
        providerType: ProviderKind.claude,
        models: const ['claude-test'],
      );

      final chunks = await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'claude-test',
        messages: const [
          {'role': 'user', 'content': 'search something'},
        ],
        stream: true,
        requestId: 'pause-turn',
      ).toList();

      // Exactly one internal continuation request — not a client tool loop.
      expect(fix.bodies, hasLength(2));
      // The continuation replays the assistant turn produced by round 1.
      final secondMessages = (fix.bodies[1]['messages'] as List).cast<Map>();
      final assistant = secondMessages.lastWhere(
        (m) => m['role'] == 'assistant',
      );
      expect((assistant['content'] as List).first, {
        'type': 'text',
        'text': 'Searching...',
      });

      expect(chunks.map((c) => c.content).join(), contains('Done.'));
      expect(chunks.last.isDone, isTrue);
    });
  });

  group('Claude single-round tool surface', () {
    late _Server fix;

    setUp(() async {
      fix = _Server(
        pathHint: 'messages',
        sse: false,
        responses: [
          [
            jsonEncode({
              'id': 'msg_1',
              'type': 'message',
              'role': 'assistant',
              'content': [
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
          ],
        ],
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    ProviderConfig _claudeConfig() => ProviderConfig(
      id: 'claude-test',
      enabled: true,
      name: 'claude-test',
      apiKey: 'test-key',
      baseUrl: fix.baseUrl,
      providerType: ProviderKind.claude,
      models: const ['claude-test'],
    );

    test(
      'non-stream tool_use round: one request, surfaced, never executed',
      () async {
        final chunks = await ChatApiService.sendMessageStream(
          config: _claudeConfig(),
          modelId: 'claude-test',
          messages: const [
            {'role': 'user', 'content': 'read c.txt'},
          ],
          stream: false,
          requestId: 'expose-claude-ns',
        ).toList();

        expect(fix.bodies, hasLength(1));
        final callChunks = chunks
            .where((c) => (c.toolCalls ?? const []).isNotEmpty)
            .toList();
        expect(callChunks, hasLength(1));
        final call = callChunks.single.toolCalls!.single;
        expect(call.id, 'toolu_1');
        expect(call.name, 'file_read');
        expect(call.arguments, <String, dynamic>{'path': 'c.txt'});
      },
    );
  });

  group('Claude streaming single-round tool surface', () {
    late _Server fix;

    setUp(() async {
      fix = _Server(
        pathHint: 'messages',
        sse: true,
        responses: [
          [
            'data: ${jsonEncode({
              'type': 'message_start',
              'message': {
                'id': 'msg_1',
                'role': 'assistant',
                'content': <dynamic>[],
                'usage': {'input_tokens': 5, 'output_tokens': 1},
              },
            })}',
            'data: ${jsonEncode({
              'type': 'content_block_start',
              'index': 0,
              'content_block': {'type': 'tool_use', 'id': 'toolu_s1', 'name': 'file_read', 'input': <String, dynamic>{}},
            })}',
            'data: ${jsonEncode({
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'input_json_delta', 'partial_json': '{"path": "c.txt"}'},
            })}',
            'data: ${jsonEncode({'type': 'content_block_stop', 'index': 0})}',
            'data: ${jsonEncode({
              'type': 'message_delta',
              'delta': {'stop_reason': 'tool_use', 'stop_sequence': null},
              'usage': {'output_tokens': 10},
            })}',
            'data: ${jsonEncode({'type': 'message_stop'})}',
            '',
          ],
        ],
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    ProviderConfig _claudeConfig() => ProviderConfig(
      id: 'claude-test',
      enabled: true,
      name: 'claude-test',
      apiKey: 'test-key',
      baseUrl: fix.baseUrl,
      providerType: ProviderKind.claude,
      models: const ['claude-test'],
    );

    test(
      'stream tool_use round: one request, surfaced, never executed',
      () async {
        final chunks = await ChatApiService.sendMessageStream(
          config: _claudeConfig(),
          modelId: 'claude-test',
          messages: const [
            {'role': 'user', 'content': 'read c.txt'},
          ],
          stream: true,
          requestId: 'expose-claude-st',
        ).toList();

        expect(fix.bodies, hasLength(1));
        final callChunks = chunks
            .where((c) => (c.toolCalls ?? const []).isNotEmpty)
            .toList();
        expect(callChunks, hasLength(1));
        final call = callChunks.single.toolCalls!.single;
        expect(call.id, 'toolu_s1');
        expect(call.name, 'file_read');
        expect(call.arguments, <String, dynamic>{'path': 'c.txt'});
      },
    );
  });

  group('Gemini single-round tool surface', () {
    late _Server fix;

    setUp(() async {
      fix = _Server(
        pathHint: 'generateContent',
        sse: false,
        responses: [
          [
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {
                        'functionCall': {
                          'name': 'file_read',
                          'args': {'path': 'd.txt'},
                        },
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
          ],
        ],
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    ProviderConfig _googleConfig() => ProviderConfig(
      id: 'google-test',
      enabled: true,
      name: 'google-test',
      apiKey: 'test-key',
      baseUrl: fix.baseUrl,
      providerType: ProviderKind.google,
      models: const ['gemini-test'],
    );

    test(
      'non-stream functionCall round: one request, surfaced, never executed',
      () async {
        final chunks = await ChatApiService.sendMessageStream(
          config: _googleConfig(),
          modelId: 'gemini-test',
          messages: const [
            {'role': 'user', 'content': 'read d.txt'},
          ],
          stream: false,
          requestId: 'expose-gemini-ns',
        ).toList();

        expect(fix.bodies, hasLength(1));
        final callChunks = chunks
            .where((c) => (c.toolCalls ?? const []).isNotEmpty)
            .toList();
        expect(callChunks, hasLength(1));
        final call = callChunks.single.toolCalls!.single;
        expect(call.name, 'file_read');
        expect(call.arguments, <String, dynamic>{'path': 'd.txt'});
      },
    );

    test('stream per-part functionCall round: one request, surfaced, not '
        'executed, no follow-up', () async {
      fix = _Server(
        pathHint: 'generateContent',
        sse: true,
        responses: [
          [
            'data: ${jsonEncode({
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {
                        'functionCall': {
                          'id': 'fc_s1',
                          'name': 'file_read',
                          'args': {'path': 'e.txt'},
                        },
                      },
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
              'usageMetadata': {'promptTokenCount': 5, 'candidatesTokenCount': 5, 'totalTokenCount': 10},
            })}',
            '',
          ],
        ],
      );
      await fix.start();

      final chunks = await ChatApiService.sendMessageStream(
        config: _googleConfig(),
        modelId: 'gemini-test',
        messages: const [
          {'role': 'user', 'content': 'read e.txt'},
        ],
        stream: true,
        requestId: 'expose-gemini-st',
      ).toList();

      expect(fix.bodies, hasLength(1), reason: 'no follow-up request allowed');
      final callChunks = chunks
          .where((c) => (c.toolCalls ?? const []).isNotEmpty)
          .toList();
      expect(callChunks, hasLength(1));
      final call = callChunks.single.toolCalls!.single;
      expect(call.id, 'fc_s1');
      expect(call.name, 'file_read');
      expect(call.arguments, <String, dynamic>{'path': 'e.txt'});
      expect(
        chunks.where((c) => (c.toolResults ?? const []).isNotEmpty),
        isEmpty,
      );
    });
  });

  group('Gemini thought-signature isolation', () {
    late _Server fix;

    setUp(() async {
      fix = _Server(
        pathHint: 'generateContent',
        sse: false,
        responses: [
          [
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {'text': 'ok'},
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
              'usageMetadata': {
                'promptTokenCount': 1,
                'candidatesTokenCount': 1,
                'totalTokenCount': 2,
              },
            }),
          ],
        ],
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    ProviderConfig config() => ProviderConfig(
      id: 'google-test',
      enabled: true,
      name: 'google-test',
      apiKey: 'test-key',
      baseUrl: fix.baseUrl,
      providerType: ProviderKind.google,
      models: const ['gemini-3.5-flash'],
    );

    Future<Map<String, dynamic>> send({
      required String sourceProviderId,
      required String signatureScope,
    }) async {
      final cfg = config();
      fix.bodies.clear();
      await ChatApiService.sendMessageStream(
        config: cfg,
        modelId: 'gemini-3.5-flash',
        messages: [
          {'role': 'user', 'content': 'hi'},
          {
            'role': 'assistant',
            'content':
                'answer\n<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"SIG_FROM_${sourceProviderId.toUpperCase()}"},"scope":"$signatureScope"} -->',
            '_provider_id': sourceProviderId,
          },
          {'role': 'user', 'content': 'next'},
        ],
        stream: false,
        requestId: 'g2-${sourceProviderId.hashCode}',
      ).toList();
      return fix.bodies.single;
    }

    test('a signature from another endpoint is dropped', () async {
      final body = await send(
        sourceProviderId: 'other',
        signatureScope: 'other|http://other-provider:443|gemini-3.5-flash',
      );
      final wire = jsonEncode(body);
      expect(wire, isNot(contains('SIG_FROM_OTHER')));
      expect(wire, contains('answer'));
      expect(body['contents'], isA<List<dynamic>>());
    });

    test('the same provider + model + origin replays its signature', () async {
      final cfg = config();
      final scope = geminiProviderScope(
        providerId: cfg.id,
        baseUrl: cfg.baseUrl,
        modelId: 'gemini-3.5-flash',
      );
      final body = await send(sourceProviderId: cfg.id, signatureScope: scope);
      expect(jsonEncode(body), contains('SIG_FROM_GOOGLE-TEST'));
    });
  });

  group('Gemini streaming thought-signature placeholder', () {
    late _Server fix;

    setUp(() async {
      fix = _Server(
        pathHint: 'streamGenerateContent',
        sse: true,
        responses: [
          [
            'data: ${jsonEncode({
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {'text': 'ok'},
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
              'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 1, 'totalTokenCount': 2},
            })}',
            '',
          ],
        ],
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    test('streaming tool-call replay gets the fallback signature', () async {
      final cfg = ProviderConfig(
        id: 'google-test',
        enabled: true,
        name: 'google-test',
        apiKey: 'test-key',
        baseUrl: fix.baseUrl,
        providerType: ProviderKind.google,
        models: const ['gemini-3.5-flash'],
      );
      await ChatApiService.sendMessageStream(
        config: cfg,
        modelId: 'gemini-3.5-flash',
        messages: [
          {'role': 'user', 'content': 'go'},
          {
            'role': 'assistant',
            'content': '\n\n',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'file_read', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'name': 'file_read',
            'tool_call_id': 'call_1',
            'content': 'ok',
          },
          {'role': 'user', 'content': 'continue'},
        ],
        stream: true,
        requestId: 'g2-stream-placeholder',
      ).toList();

      final wire = jsonEncode(fix.bodies.single);
      expect(wire, contains('functionCall'));
      expect(wire, contains('context_engineering_is_the_way_to_go'));
    });
  });

  group('Claude provider-native server tools', () {
    late _Server fix;

    setUp(() async {
      fix = _Server(
        pathHint: 'messages',
        sse: true,
        responses: [
          [
            'data: ${jsonEncode({
              'type': 'content_block_start',
              'index': 0,
              'content_block': {
                'type': 'server_tool_use',
                'id': 'srvtoolu_1',
                'name': 'web_search',
              },
            })}',
            '',
            'data: ${jsonEncode({
              'type': 'content_block_delta',
              'index': 0,
              'delta': {
                'type': 'input_json_delta',
                'partial_json': '{"query":"x"}',
              },
            })}',
            '',
            'data: ${jsonEncode({'type': 'content_block_stop', 'index': 0})}',
            '',
            'data: ${jsonEncode({
              'type': 'content_block_start',
              'index': 1,
              'content_block': {
                'type': 'web_search_tool_result',
                'tool_use_id': 'srvtoolu_1',
                'content': [
                  {
                    'type': 'web_search_result',
                    'title': 'T',
                    'url': 'https://example.com',
                  },
                ],
              },
            })}',
            '',
            'data: ${jsonEncode({'type': 'content_block_stop', 'index': 1})}',
            '',
            'data: ${jsonEncode({
              'type': 'message_delta',
              // Anthropic pauses the turn when a server tool needs to continue.
              'delta': {'stop_reason': 'pause_turn'},
              'usage': {'input_tokens': 5, 'output_tokens': 5},
            })}',
            '',
            'data: ${jsonEncode({'type': 'message_stop'})}',
            '',
          ],
          [
            'data: ${jsonEncode({
              'type': 'content_block_start',
              'index': 0,
              'content_block': {'type': 'text', 'text': ''},
            })}',
            '',
            'data: ${jsonEncode({
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': 'Done.'},
            })}',
            '',
            'data: ${jsonEncode({'type': 'content_block_stop', 'index': 0})}',
            '',
            'data: ${jsonEncode({
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
              'usage': {'input_tokens': 5, 'output_tokens': 5},
            })}',
            '',
            'data: ${jsonEncode({'type': 'message_stop'})}',
            '',
          ],
        ],
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    test('server tool is display-only and never executable by the kernel', () async {
      final config = ProviderConfig(
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
            'abilities': ['tool'],
          },
        },
      );

      final chunks = await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'claude-test',
        messages: const [
          {'role': 'user', 'content': 'search it'},
        ],
        stream: true,
        requestId: 'server-tool',
      ).toList();

      // The transport continued the same turn internally (pause_turn-like
      // server-tool continuation), so two requests are expected.
      expect(fix.bodies, hasLength(2));

      final callChunks = chunks
          .where((c) => (c.toolCalls ?? const []).isNotEmpty)
          .toList();
      expect(callChunks, hasLength(1));
      final call = callChunks.single.toolCalls!.single;
      expect(call.id, 'srvtoolu_1');
      expect(call.name, 'search_web');
      expect(
        call.execute,
        isFalse,
        reason: 'server tools already ran inside the provider turn',
      );

      // The server result is surfaced for the UI under the same id.
      final resultChunks = chunks
          .where((c) => (c.toolResults ?? const []).isNotEmpty)
          .toList();
      expect(resultChunks, isNotEmpty);
      expect(resultChunks.single.toolResults!.single.id, 'srvtoolu_1');

      expect(chunks.map((c) => c.content).join(), contains('Done.'));
      expect(chunks.last.isDone, isTrue);
    });
  });
}
