import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/services/api/provider_request_headers.dart';

Future<({ProviderConfig config, List<Map<String, dynamic>> bodies})>
_startCapture({
  Map<String, dynamic> modelOverrides = const <String, dynamic>{},
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final bodies = <Map<String, dynamic>>[];

  server.listen((request) async {
    try {
      final raw = await utf8.decoder.bind(request).join();
      bodies.add(jsonDecode(raw) as Map<String, dynamic>);
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: {"choices":[{"index":0,"delta":{"content":"ok"},'
        '"finish_reason":"stop"}]}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
    } finally {
      await request.response.close();
    }
  });

  return (
    config: ProviderConfig(
      id: 'local-capture',
      enabled: true,
      name: 'Local capture',
      apiKey: 'test-key',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      providerType: ProviderKind.openai,
      models: const ['test-model'],
      modelOverrides: modelOverrides,
    ),
    bodies: bodies,
  );
}

void main() {
  test(
    'the subagent round reaches the wire with its sampling values',
    () async {
      final capture = await _startCapture();

      final chunks = await ChatApiService.sendMessageStream(
        config: capture.config,
        modelId: 'test-model',
        messages: const [
          {'role': 'user', 'content': 'task'},
        ],
        temperature: 0.3,
        topP: 0.9,
        maxTokens: 4096,
        stream: true,
        requestId: 'run-1',
        sessionId: 'session-1',
      ).timeout(const Duration(seconds: 5)).toList();

      expect(chunks, isNotEmpty);
      final body = capture.bodies.single;
      expect(body['model'], 'test-model');
      expect(body['temperature'], 0.3);
      expect(body['top_p'], 0.9);
      expect(body['max_tokens'], 4096);
      expect(body['stream'], isTrue);
      expect(body['stream_options'], {'include_usage': true});
    },
  );

  test('thinking budget follows the parent wire dialect', () async {
    final capture = await _startCapture(
      modelOverrides: const {
        'test-model': {
          'abilities': ['reasoning'],
          'reasoningWire': 'chat.thinking_budget',
        },
      },
    );

    await ChatApiService.sendMessageStream(
      config: capture.config,
      modelId: 'test-model',
      messages: const [
        {'role': 'user', 'content': 'task'},
      ],
      thinkingBudget: 2345,
      stream: true,
      requestId: 'run-2',
      sessionId: 'session-2',
    ).timeout(const Duration(seconds: 5)).drain<void>();

    expect(capture.bodies.single['thinking'], {
      'type': 'enabled',
      'budget_tokens': 2345,
    });
  });

  test('provider session headers carry the subagent session id', () {
    final config = ProviderConfig(
      id: 'chatgpt',
      enabled: true,
      name: 'ChatGPT',
      apiKey: 'k',
      baseUrl: 'https://chatgpt.com/backend-api',
      providerType: ProviderKind.openai,
      oauthProvider: OAuthProvider.chatgpt,
      models: const ['m'],
    );
    final headers = providerSessionHeaders(
      config,
      sessionId: 'sub-session-1',
      conversationId: 'sub-session-1',
      requestId: 'run_subagent_1',
    );
    expect(headers['session_id'], 'sub-session-1');
    expect(headers['conversation_id'], 'sub-session-1');
    expect(headers['x-client-request-id'], 'run_subagent_1');
  });
}
