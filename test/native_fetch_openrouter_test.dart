import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/builtin_tools.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

ProviderConfig _config({
  bool useResponseApi = false,
  bool fetchEnabled = true,
  bool searchEnabled = false,
}) => ProviderConfig(
  id: 'OpenRouter',
  enabled: true,
  name: 'OpenRouter',
  apiKey: 'test-key',
  baseUrl: 'http://127.0.0.1:9',
  providerType: ProviderKind.openai,
  useResponseApi: useResponseApi,
  modelOverrides: <String, dynamic>{
    'model': <String, dynamic>{
      'builtInTools': <String>[
        if (searchEnabled) BuiltInToolNames.search,
        if (fetchEnabled) BuiltInToolNames.webFetch,
      ],
      if (fetchEnabled)
        'webFetch': <String, dynamic>{
          'engine': 'exa',
          'maxUses': 5,
          'maxContentTokens': 12000,
          'allowedDomains': <String>['docs.example.com'],
        },
    },
  },
);

Future<HttpServer> _startServer(
  void Function(Uri uri, Map<String, dynamic> body) onRequest,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });
  server.listen((request) async {
    final body =
        jsonDecode(await utf8.decoder.bind(request).join())
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

String _baseUrl(HttpServer server) =>
    'http://${server.address.address}:${server.port}';

void main() {
  test('chat-completions injects openrouter:web_fetch parameters', () async {
    Map<String, dynamic>? receivedBody;
    final server = await _startServer((uri, body) {
      receivedBody = body;
    });

    await ChatApiService.sendMessageStream(
      config: _config().copyWith(baseUrl: _baseUrl(server)),
      modelId: 'model',
      messages: const [
        {'role': 'user', 'content': 'read this page'},
      ],
      stream: false,
    ).toList();

    expect(receivedBody, isNotNull);
    final tools = (receivedBody!['tools'] as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final entry = tools.singleWhere(
      (tool) => tool['type'] == 'openrouter:web_fetch',
    );
    final params = entry['parameters'] as Map<String, dynamic>;
    expect(params['engine'], 'exa');
    expect(params['max_uses'], 5);
    expect(params['max_content_tokens'], 12000);
    expect(params['allowed_domains'], ['docs.example.com']);
  });

  test('Responses path does not receive the OpenRouter server tool', () async {
    Map<String, dynamic>? receivedBody;
    final server = await _startServer((uri, body) {
      receivedBody = body;
    });

    await ChatApiService.sendMessageStream(
      config: _config(useResponseApi: true).copyWith(baseUrl: _baseUrl(server)),
      modelId: 'model',
      messages: const [
        {'role': 'user', 'content': 'read this page'},
      ],
      stream: false,
    ).toList();

    expect(receivedBody, isNotNull);
    expect(jsonEncode(receivedBody), isNot(contains('openrouter:web_fetch')));
  });  test('global webFetchEnabled=false suppresses the server tool', () async {
    Map<String, dynamic>? receivedBody;
    final server = await _startServer((uri, body) {
      receivedBody = body;
    });

    await ChatApiService.sendMessageStream(
      config: _config().copyWith(baseUrl: _baseUrl(server)),
      modelId: 'model',
      messages: const [
        {'role': 'user', 'content': 'read this page'},
      ],
      stream: false,
      webFetchEnabled: false,
    ).toList();

    expect(receivedBody, isNotNull);
    expect(jsonEncode(receivedBody), isNot(contains('openrouter:web_fetch')));
  });

  test('the search plugin remains independent from the fetch server tool',
      () async {
      Map<String, dynamic>? receivedBody;
      final server = await _startServer((uri, body) {
        receivedBody = body;
      });

      await ChatApiService.sendMessageStream(
        config: _config(
          searchEnabled: true,
        ).copyWith(baseUrl: _baseUrl(server)),
        modelId: 'model',
        messages: const [
          {'role': 'user', 'content': 'search and read'},
        ],
        stream: false,
      ).toList();

      expect(
        (receivedBody!['plugins'] as List).whereType<Map>().any(
          (plugin) => plugin['id'] == 'web',
        ),
        isTrue,
      );
      expect(jsonEncode(receivedBody), contains('openrouter:web_fetch'));
    },
  );
}
