import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/builtin_tools.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

ProviderConfig _openRouterConfig({
  required String modelId,
  bool searchEnabled = true,
  bool useResponseApi = false,
}) {
  return ProviderConfig(
    id: 'OpenRouter',
    enabled: true,
    name: 'OpenRouter',
    apiKey: 'test-key',
    baseUrl: 'http://127.0.0.1:9',
    providerType: ProviderKind.openai,
    useResponseApi: useResponseApi,
    modelOverrides: <String, dynamic>{
      if (searchEnabled)
        modelId: <String, dynamic>{
          'builtInTools': const <String>[BuiltInToolNames.search],
        },
    },
  );
}

Future<HttpServer> _startServer(
  void Function(Uri uri, Map<String, dynamic> body) onRequest,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    onRequest(request.uri, body);
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 1,
          'completion_tokens': 1,
          'total_tokens': 2,
        },
      }),
    );
    await request.response.close();
  });
  return server;
}

String _baseUrl(HttpServer server) {
  return 'http://${server.address.address}:${server.port}';
}

void main() {
  group('OpenRouter built-in search', () {
    test('support matrix enables web search for OpenRouter models', () {
      final cfg = _openRouterConfig(modelId: 'deepseek/deepseek-chat');

      expect(
        BuiltInToolsHelper.supportsBuiltInSearchForModel(
          cfg: cfg,
          modelId: 'deepseek/deepseek-chat',
        ),
        isTrue,
      );
    });

    test('support matrix keeps OpenRouter Responses path unsupported', () {
      final cfg = _openRouterConfig(
        modelId: 'deepseek/deepseek-chat',
        useResponseApi: true,
      );

      expect(
        BuiltInToolsHelper.supportsBuiltInSearchForModel(
          cfg: cfg,
          modelId: 'deepseek/deepseek-chat',
        ),
        isFalse,
      );
    });

    test('Chat Completions request injects default web plugin', () async {
      Map<String, dynamic>? receivedBody;
      final server = await _startServer((uri, body) {
        receivedBody = body;
      });

      await ChatApiService.sendMessageStream(
        config: _openRouterConfig(
          modelId: 'deepseek/deepseek-chat',
        ).copyWith(baseUrl: _baseUrl(server)),
        modelId: 'deepseek/deepseek-chat',
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'latest AI news'},
        ],
        stream: false,
      ).toList();

      expect(receivedBody, isNotNull);
      expect(receivedBody!['model'], 'deepseek/deepseek-chat');
      expect(
        receivedBody!['plugins'],
        contains(
          predicate<Map<String, dynamic>>((plugin) => plugin['id'] == 'web'),
        ),
      );
    });

    test('Chat Completions request leaves plugins absent when disabled',
        () async {
      Map<String, dynamic>? receivedBody;
      final server = await _startServer((uri, body) {
        receivedBody = body;
      });

      await ChatApiService.sendMessageStream(
        config: _openRouterConfig(
          modelId: 'deepseek/deepseek-chat',
          searchEnabled: false,
        ).copyWith(baseUrl: _baseUrl(server)),
        modelId: 'deepseek/deepseek-chat',
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'latest AI news'},
        ],
        stream: false,
      ).toList();

      expect(receivedBody, isNotNull);
      expect(receivedBody!.containsKey('plugins'), isFalse);
    });
  });
}
