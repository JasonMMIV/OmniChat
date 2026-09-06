// Per-provider single-round expose tests (IMPORT_PLAN_COWORK.md P0-3).
//
// Same contract as `send_message_stream_expose_test.dart` but across the
// Claude and Gemini transports: with `exposeToolCallsOnly: true` each call
// must be exactly one request, surface tool calls once, and never execute
// them.

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
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
  group('Claude exposeToolCallsOnly', () {
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
      'non-stream tool_use round: one request, surfaced, not executed',
      () async {
        var executed = 0;
        final chunks = await ChatApiService.sendMessageStream(
          config: _claudeConfig(),
          modelId: 'claude-test',
          messages: const [
            {'role': 'user', 'content': 'read c.txt'},
          ],
          stream: false,
          requestId: 'expose-claude-ns',
          exposeToolCallsOnly: true,
          onToolCall: (name, args) async {
            executed++;
            return 'BODY';
          },
        ).toList();

        expect(executed, 0);
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

  group('Claude streaming exposeToolCallsOnly', () {
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
      'stream tool_use round: one request, surfaced, not executed',
      () async {
        var executed = 0;
        final chunks = await ChatApiService.sendMessageStream(
          config: _claudeConfig(),
          modelId: 'claude-test',
          messages: const [
            {'role': 'user', 'content': 'read c.txt'},
          ],
          stream: true,
          requestId: 'expose-claude-st',
          exposeToolCallsOnly: true,
          onToolCall: (name, args) async {
            executed++;
            return 'BODY';
          },
        ).toList();

        expect(executed, 0);
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

  group('Gemini exposeToolCallsOnly', () {
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
      'non-stream functionCall round: one request, surfaced, not executed',
      () async {
        var executed = 0;
        final chunks = await ChatApiService.sendMessageStream(
          config: _googleConfig(),
          modelId: 'gemini-test',
          messages: const [
            {'role': 'user', 'content': 'read d.txt'},
          ],
          stream: false,
          requestId: 'expose-gemini-ns',
          exposeToolCallsOnly: true,
          onToolCall: (name, args) async {
            executed++;
            return 'BODY';
          },
        ).toList();

        expect(executed, 0);
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

      var executed = 0;
      final chunks = await ChatApiService.sendMessageStream(
        config: _googleConfig(),
        modelId: 'gemini-test',
        messages: const [
          {'role': 'user', 'content': 'read e.txt'},
        ],
        stream: true,
        requestId: 'expose-gemini-st',
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
      expect(call.id, 'fc_s1');
      expect(call.name, 'file_read');
      expect(call.arguments, <String, dynamic>{'path': 'e.txt'});
      expect(
        chunks.where((c) => (c.toolResults ?? const []).isNotEmpty),
        isEmpty,
      );
    });
  });
}
