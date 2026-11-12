// `generateText` is used by utility calls such as the new-chat greeting.
// Gemini may return a thought summary before the answer (or split the answer
// into several parts); the utility path must return only the answer text.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

class _GeminiServer {
  _GeminiServer(this.response);

  final Map<String, dynamic> response;
  late HttpServer _server;
  late String baseUrl;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${_server.port}';
    _server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

ProviderConfig _config(String baseUrl) => ProviderConfig(
  id: 'gemini-test',
  enabled: true,
  name: 'Gemini Test',
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.google,
  models: const ['gemini-test'],
);

Future<String> _generate(_GeminiServer server) => ChatApiService.generateText(
  config: _config(server.baseUrl),
  modelId: 'gemini-test',
  prompt: '請產生一句繁體中文問候語',
);

void main() {
  test('skips thought parts and returns the real answer', () async {
    final server = _GeminiServer({
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': [
              {'text': 'The user wants a short greeting.', 'thought': true},
              {'text': '你好！'},
              {'text': '今天想聊什麼？'},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    });
    await server.start();
    try {
      expect(await _generate(server), '你好！今天想聊什麼？');
    } finally {
      await server.stop();
    }
  });

  test('returns an empty string when every part is a thought', () async {
    final server = _GeminiServer({
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': [
              {'text': 'Thinking...', 'thought': true},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    });
    await server.start();
    try {
      expect(await _generate(server), '');
    } finally {
      await server.stop();
    }
  });

  test('joins split text parts and ignores empty text', () async {
    final server = _GeminiServer({
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': [
              {'text': '早安！'},
              {'text': ''},
              {'text': '想做什麼？'},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    });
    await server.start();
    try {
      expect(await _generate(server), '早安！想做什麼？');
    } finally {
      await server.stop();
    }
  });
}
