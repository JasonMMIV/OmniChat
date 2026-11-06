// Native attachment follow-up parity for the non-OpenAI-chat transports.
//
// The OpenAI chat body2 path is covered by `native_input_followup_test.dart`.
// These tests pin the other three continuation strategies:
//   - Responses: the serialized `responsesInitialInput` is replayed verbatim;
//   - Claude: `convo` starts from the converted `initialMessages` (document
//     blocks included) and appends tool rounds;
//   - Gemini: `convo` starts from the converted `contents` (inline_data
//     included) and appends function rounds.

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _CaptureServer {
  _CaptureServer({
    required this.toolResponse,
    required this.textResponse,
    this.sse = false,
  });

  final String toolResponse;
  final String textResponse;
  final bool sse;
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

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

Map<String, dynamic> _nativeMessage(
  String protocol,
  Map<String, dynamic> part,
) => <String, dynamic>{
  'role': 'user',
  'content': 'read this',
  '_native_input': <String, dynamic>{
    'protocol': protocol,
    'parts': <Map<String, dynamic>>[part],
  },
};

Iterable<Map> _contentBlocks(dynamic content) =>
    (content as List).whereType<Map>();

void main() {
  group('Responses input_file survives the follow-up', () {
    late _CaptureServer fix;

    setUp(() async {
      fix = _CaptureServer(
        sse: true,
        toolResponse: [
          'data: ${jsonEncode({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {
              'type': 'function_call',
              'call_id': 'call_r1',
              'name': 'file_read',
              'arguments': '',
            },
          })}',
          'data: ${jsonEncode({
            'type': 'response.function_call_arguments.delta',
            'output_index': 0,
            'delta': '{"path":"r.txt"}',
          })}',
          'data: ${jsonEncode({
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': {
              'type': 'function_call',
              'call_id': 'call_r1',
              'name': 'file_read',
              'arguments': '{"path":"r.txt"}',
            },
          })}',
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'usage': {
                'input_tokens': 5,
                'output_tokens': 5,
              },
            },
          })}',
          '',
        ].join('\n'),
        textResponse: [
          'data: ${jsonEncode({
            'type': 'response.output_text.delta',
            'delta': 'done',
          })}',
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'usage': {
                'input_tokens': 5,
                'output_tokens': 5,
              },
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

    test('both requests carry the input_file part', () async {
      final config = ProviderConfig(
        id: 'responses-native',
        enabled: true,
        name: 'responses-native',
        apiKey: 'test-key',
        baseUrl: fix.baseUrl,
        providerType: ProviderKind.openai,
        useResponseApi: true,
        models: const ['gpt-test'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'gpt-test',
        messages: [
          _nativeMessage('responses', <String, dynamic>{
            'type': 'input_file',
            'filename': 'brief.pdf',
            'file_data': 'data:application/pdf;base64,AA==',
          }),
        ],
        stream: true,
        requestId: 'responses-native',
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'file_read',
              'description': 'read',
              'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
            },
          },
        ],
        onToolCall: (name, args, {toolCallId}) async => 'ok',
      ).toList();

      expect(fix.bodies, hasLength(2));
      for (final body in fix.bodies) {
        final input = (body['input'] as List).whereType<Map>();
        final hasFile = input.any((item) {
          final content = item['content'];
          if (content is! List) return false;
          return _contentBlocks(content).any(
            (block) => block['type'] == 'input_file',
          );
        });
        expect(hasFile, isTrue, reason: 'input_file must survive follow-up');
      }
    });
  });

  group('Claude document block survives the follow-up', () {
    late _CaptureServer fix;

    setUp(() async {
      fix = _CaptureServer(
        toolResponse: jsonEncode({
          'id': 'msg_1',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'file_read',
              'input': {'path': 'r.txt'},
            },
          ],
          'stop_reason': 'tool_use',
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
          'usage': {'input_tokens': 5, 'output_tokens': 5},
        }),
      );
      await fix.start();
    });

    tearDown(() async {
      await fix.stop();
    });

    test('both requests carry the document block', () async {
      final config = ProviderConfig(
        id: 'claude-native',
        enabled: true,
        name: 'claude-native',
        apiKey: 'test-key',
        baseUrl: fix.baseUrl,
        providerType: ProviderKind.claude,
        models: const ['claude-test'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'claude-test',
        messages: [
          _nativeMessage('claude', <String, dynamic>{
            'type': 'document',
            'title': 'brief.pdf',
            'source': {
              'type': 'base64',
              'media_type': 'application/pdf',
              'data': 'AA==',
            },
          }),
        ],
        stream: false,
        requestId: 'claude-native',
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'file_read',
              'description': 'read',
              'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
            },
          },
        ],
        onToolCall: (name, args, {toolCallId}) async => 'ok',
      ).toList();

      expect(fix.bodies, hasLength(2));
      for (final body in fix.bodies) {
        final messages = (body['messages'] as List).whereType<Map>();
        final hasDocument = messages.any((message) {
          final content = message['content'];
          if (content is! List) return false;
          return _contentBlocks(content).any(
            (block) => block['type'] == 'document',
          );
        });
        expect(hasDocument, isTrue, reason: 'document must survive follow-up');
      }
    });
  });

  group('Gemini inline_data survives the follow-up', () {
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
                      'args': {'path': 'r.txt'},
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

    test('both requests carry the inline_data part', () async {
      final config = ProviderConfig(
        id: 'google-native',
        enabled: true,
        name: 'google-native',
        apiKey: 'test-key',
        baseUrl: fix.baseUrl,
        providerType: ProviderKind.google,
        models: const ['gemini-test'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'gemini-test',
        messages: [
          _nativeMessage('gemini', <String, dynamic>{
            'inline_data': {'mime_type': 'application/pdf', 'data': 'AA=='},
          }),
        ],
        stream: false,
        requestId: 'gemini-native',
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'file_read',
              'description': 'read',
              'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
            },
          },
        ],
        onToolCall: (name, args, {toolCallId}) async => 'ok',
      ).toList();

      expect(fix.bodies, hasLength(2));
      for (final body in fix.bodies) {
        final contents = (body['contents'] as List).whereType<Map>();
        final hasInline = contents.any((content) {
          final parts = content['parts'];
          if (parts is! List) return false;
          return _contentBlocks(parts).any((part) => part['inline_data'] != null);
        });
        expect(hasInline, isTrue, reason: 'inline_data must survive follow-up');
      }
    });
  });
}
