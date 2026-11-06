// Regression for multimodal plan §7 F3: the chat-completions follow-up used to
// rebuild `mm2` from the neutral messages and silently drop every native
// attachment. The transport now derives the follow-up from the already
// serialized `mm` list, so the second request must still carry the parts.

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderConfig _config(String baseUrl) => ProviderConfig(
  id: 'native-followup',
  enabled: true,
  name: 'native-followup',
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  models: const ['gpt-test'],
  modelOverrides: const {
    'gpt-test': {
      'input': ['text', 'audio', 'pdf'],
      'output': ['text'],
    },
  },
);

class _Server {
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
    req.response.headers.contentType = ContentType.parse('text/event-stream');
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
                      'id': 'call_1',
                      'type': 'function',
                      'function': {
                        'name': 'file_read',
                        'arguments': '{"path":"a.txt"}',
                      },
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
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
                'delta': {'content': 'done'},
                'finish_reason': 'stop',
              },
            ],
          })}',
          'data: [DONE]',
          '',
        ].join('\n'),
      );
    }
    await req.response.close();
  }
}

void main() {
  late _Server fix;

  setUp(() async {
    fix = _Server();
    await fix.start();
  });

  tearDown(() async {
    await fix.stop();
  });

  test('audio part survives the tool-call follow-up (body2)', () async {
    final nativePart = <String, dynamic>{
      'type': 'input_audio',
      'input_audio': {'data': 'AAAA', 'format': 'wav'},
    };
    // P0-3: the transport is single-round; the agent-loop kernel composes the
    // follow-up from the neutral messages (native parts included).
    await for (final _ in runAgentLoop(
      messages: [
        {'role': 'system', 'content': 'sys'},
        {
          'role': 'user',
          'content': 'listen',
          '_native_input': {
            'protocol': 'openAiChat',
            'parts': [nativePart],
          },
        },
      ],
      sendRound: (msgs) async => ChatApiService.sendMessageStream(
        config: _config(fix.baseUrl),
        modelId: 'gpt-test',
        messages: msgs,
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'file_read',
              'description': 'read a file',
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
        ],
        requestId: 'native-followup',
      ),
      onToolCall: (call) async => '{"ok":true}',
    )) {}

    expect(fix.bodies, hasLength(2));
    for (final body in fix.bodies) {
      final messages = (body['messages'] as List).cast<Map>();
      final user = messages.firstWhere((m) => m['role'] == 'user');
      final content = (user['content'] as List).cast<Map>();
      expect(
        content.any((block) => block['type'] == 'input_audio'),
        isTrue,
        reason: 'native audio must survive every follow-up round',
      );
    }
  });
}
