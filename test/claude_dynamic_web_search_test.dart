import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

ProviderConfig _claudeConfig(
  Map<String, dynamic> modelOverrides, {
  String baseUrl = 'http://127.0.0.1:9',
}) {
  return ProviderConfig(
    id: 'ClaudeTest',
    enabled: true,
    name: 'ClaudeTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.claude,
    modelOverrides: modelOverrides,
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
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'usage': {'input_tokens': 1, 'output_tokens': 1},
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
  group('Claude built-in search tool injection', () {
    test(
      'uses web_search_20260209 + code_execution companion when dynamic '
      'search is enabled',
      () async {
        late List<dynamic> tools;
        final server = await _startServer((uri, body) {
          tools = body['tools'] as List<dynamic>;
        });

        await ChatApiService.sendMessageStream(
          config: _claudeConfig(
            {
              'claude-opus-4-7': {
                'builtInTools': ['search'],
                'webSearch': {'toolVersion': 'web_search_20260209'},
              },
            },
            baseUrl: _baseUrl(server),
          ),
          modelId: 'claude-opus-4-7',
          messages: const [
            {'role': 'user', 'content': 'search for the latest news'},
          ],
          stream: false,
        ).toList();

        expect(tools, containsAll(<Map<String, dynamic>>[
          {'type': 'web_search_20260209', 'name': 'web_search'},
          {'type': 'code_execution_20250825', 'name': 'code_execution'},
        ]));
      },
    );

    test(
      'keeps legacy web_search_20250305 without code_execution when dynamic '
      'search is disabled',
      () async {
        late List<dynamic> tools;
        final server = await _startServer((uri, body) {
          tools = body['tools'] as List<dynamic>;
        });

        await ChatApiService.sendMessageStream(
          config: _claudeConfig(
            {
              'claude-opus-4-7': {
                'builtInTools': ['search'],
              },
            },
            baseUrl: _baseUrl(server),
          ),
          modelId: 'claude-opus-4-7',
          messages: const [
            {'role': 'user', 'content': 'search for the latest news'},
          ],
          stream: false,
        ).toList();

        expect(tools, containsAll(<Map<String, dynamic>>[
          {'type': 'web_search_20250305', 'name': 'web_search'},
        ]));
        expect(
          tools.where(
            (t) =>
                t is Map &&
                (t['type'] == 'code_execution_20250825' ||
                    t['type'] == 'code_execution'),
          ),
          isEmpty,
        );
      },
    );

    test('snake_case tool_version override also enables dynamic search', () async {
      late List<dynamic> tools;
      final server = await _startServer((uri, body) {
        tools = body['tools'] as List<dynamic>;
      });

      await ChatApiService.sendMessageStream(
        config: _claudeConfig(
          {
            'claude-opus-4-7': {
              'builtInTools': ['search'],
              'webSearch': {'tool_version': 'web_search_20260209'},
            },
          },
          baseUrl: _baseUrl(server),
        ),
        modelId: 'claude-opus-4-7',
        messages: const [
          {'role': 'user', 'content': 'search'},
        ],
        stream: false,
      ).toList();

      expect(tools, containsAll(<Map<String, dynamic>>[
        {'type': 'web_search_20260209', 'name': 'web_search'},
        {'type': 'code_execution_20250825', 'name': 'code_execution'},
      ]));
    });

    test(
      'DeepSeek Claude-compatible provider gets legacy web_search_20250305 '
      'without code_execution companion',
      () async {
        late List<dynamic> tools;
        final server = await _startServer((uri, body) {
          tools = body['tools'] as List<dynamic>;
        });

        final cfg = ProviderConfig(
          id: 'deepseek-anthropic',
          enabled: true,
          name: 'DeepSeek Claude',
          apiKey: 'test-key',
          baseUrl: 'https://api.deepseek.com/anthropic',
          providerType: ProviderKind.claude,
          modelOverrides: {
            'deepseek-chat': {
              'builtInTools': ['search'],
              'webSearch': {'toolVersion': 'web_search_20260209'},
            },
          },
        ).copyWith(baseUrl: _baseUrl(server));

        await ChatApiService.sendMessageStream(
          config: cfg,
          modelId: 'deepseek-chat',
          messages: const [
            {'role': 'user', 'content': 'search'},
          ],
          stream: false,
        ).toList();

        expect(tools, containsAll(<Map<String, dynamic>>[
          {'type': 'web_search_20250305', 'name': 'web_search'},
        ]));
        expect(
          tools.where(
            (t) => t is Map && t['type'] == 'web_search_20260209',
          ),
          isEmpty,
        );
        expect(
          tools.where(
            (t) =>
                t is Map &&
                (t['type'] == 'code_execution_20250825' ||
                    t['type'] == 'code_execution'),
          ),
          isEmpty,
        );
      },
    );

    test('unsupported models never get the dynamic tool version', () async {
      late List<dynamic> tools;
      final server = await _startServer((uri, body) {
        tools = body['tools'] as List<dynamic>;
      });

      await ChatApiService.sendMessageStream(
        config: _claudeConfig(
          {
            'claude-3-7-sonnet-20250219': {
              'builtInTools': ['search'],
              'webSearch': {'toolVersion': 'web_search_20260209'},
            },
          },
          baseUrl: _baseUrl(server),
        ),
        modelId: 'claude-3-7-sonnet-20250219',
        messages: const [
          {'role': 'user', 'content': 'search'},
        ],
        stream: false,
      ).toList();

      expect(tools, containsAll(<Map<String, dynamic>>[
        {'type': 'web_search_20250305', 'name': 'web_search'},
      ]));
      expect(
        tools.where(
          (t) =>
              t is Map &&
              (t['type'] == 'code_execution_20250825' ||
                  t['type'] == 'code_execution'),
        ),
        isEmpty,
      );
    });
  });
}
