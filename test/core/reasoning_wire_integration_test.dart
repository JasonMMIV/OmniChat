import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Capture the first chat-completions request body while returning a minimal
/// SSE stream.
Future<Map<String, dynamic>> _captureRequest(Map<String, dynamic> overrides,
    {int? thinkingBudget}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));

  final captured = <Map<String, dynamic>>[];
  server.listen((request) async {
    final body =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    captured.add(body);
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      'data: ${jsonEncode({
            'id': 'cmpl-wire',
            'object': 'chat.completion.chunk',
            'created': 0,
            'model': 'wire-model',
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\n',
    );
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  });

  final cfg = ProviderConfig(
    id: 'Zhipu AI',
    enabled: true,
    name: 'Zhipu AI',
    apiKey: 'test-key',
    baseUrl: 'http://${server.address.address}:${server.port}/v1',
    providerType: ProviderKind.openai,
    useResponseApi: false,
    modelOverrides: {'wire-model': overrides},
  );

  await ChatApiService.sendMessageStream(
    config: cfg,
    modelId: 'wire-model',
    messages: const [
      {'role': 'user', 'content': 'hi'},
    ],
    thinkingBudget: thinkingBudget,
  ).drain<void>();

  expect(captured, hasLength(1));
  return captured.first;
}

void main() {
  test('explicit wire replaces the Zhipu auto thinking knob', () async {
    final body = await _captureRequest(
      {'abilities': ['reasoning'], 'reasoningWire': 'chat.thinking_mode'},
      thinkingBudget: 16000,
    );

    expect(body['thinking_mode'], isTrue);
    expect(body.containsKey('thinking'), isFalse);
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  test('auto (no wire) keeps the Zhipu vendor knob', () async {
    final body = await _captureRequest(
      {'abilities': ['reasoning']},
      thinkingBudget: 16000,
    );

    expect(body['thinking'], {'type': 'enabled'});
    expect(body.containsKey('thinking_mode'), isFalse);
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  test('chat.none strips every reasoning key from the wire body', () async {
    final body = await _captureRequest(
      {'abilities': ['reasoning'], 'reasoningWire': 'chat.none'},
      thinkingBudget: 16000,
    );

    for (final key in const [
      'reasoning_effort',
      'reasoning',
      'thinking',
      'thinking_mode',
      'enable_thinking',
      'thinking_budget',
    ]) {
      expect(body.containsKey(key), isFalse, reason: key);
    }
  });
}
