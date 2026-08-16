import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

Future<Map<String, dynamic>> _captureRequest({
  required ProviderConfig config,
  required String modelId,
}) async {
  final bodyCompleter = Completer<Map<String, dynamic>>();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });
  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (!bodyCompleter.isCompleted) {
      bodyCompleter.complete(jsonDecode(raw) as Map<String, dynamic>);
    }
    request.response.headers.contentType = ContentType.json;
    if (config.providerType == ProviderKind.claude) {
      request.response.write(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        }),
      );
    } else {
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
    }
    await request.response.close();
  });

  final localConfig = config.copyWith(
    baseUrl: 'http://${server.address.address}:${server.port}',
  );
  try {
    await ChatApiService.sendMessageStream(
      config: localConfig,
      modelId: modelId,
      messages: const <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hello'},
      ],
      stream: false,
    ).toList();
    return await bodyCompleter.future.timeout(const Duration(seconds: 2));
  } finally {
    await server.close(force: true);
  }
}

Future<Map<String, dynamic>> _captureGenerateTextBody({
  required ProviderConfig config,
  required String modelId,
}) async {
  final bodyCompleter = Completer<Map<String, dynamic>>();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });
  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (!bodyCompleter.isCompleted) {
      bodyCompleter.complete(jsonDecode(raw) as Map<String, dynamic>);
    }
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

  try {
    await ChatApiService.generateText(
      config: config.copyWith(
        baseUrl: 'http://${server.address.address}:${server.port}',
      ),
      modelId: modelId,
      prompt: 'hello',
    );
    return await bodyCompleter.future.timeout(const Duration(seconds: 2));
  } finally {
    await server.close(force: true);
  }
}

void main() {
  group('Claude prompt caching on the Anthropic path', () {
    ProviderConfig claudeConfig({
      bool? claudePromptCachingEnabled,
      String? claudePromptCachingTtl,
    }) {
      return ProviderConfig(
        id: 'ClaudeTest',
        enabled: true,
        name: 'ClaudeTest',
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:9',
        providerType: ProviderKind.claude,
        claudePromptCachingEnabled: claudePromptCachingEnabled,
        claudePromptCachingTtl: claudePromptCachingTtl,
      );
    }

    test('injects cache_control when caching is enabled', () async {
      final body = await _captureRequest(
        config: claudeConfig(claudePromptCachingEnabled: true),
        modelId: 'claude-sonnet-4-5',
      );

      expect(body['cache_control'], <String, dynamic>{'type': 'ephemeral'});
    });

    test('includes ttl 1h when configured', () async {
      final body = await _captureRequest(
        config: claudeConfig(
          claudePromptCachingEnabled: true,
          claudePromptCachingTtl: '1h',
        ),
        modelId: 'claude-sonnet-4-5',
      );

      expect(
        body['cache_control'],
        <String, dynamic>{'type': 'ephemeral', 'ttl': '1h'},
      );
    });

    test('omits cache_control when caching is disabled', () async {
      final body = await _captureRequest(
        config: claudeConfig(claudePromptCachingEnabled: false),
        modelId: 'claude-sonnet-4-5',
      );

      expect(body.containsKey('cache_control'), isFalse);
    });

    test('omits cache_control by default', () async {
      final body = await _captureRequest(
        config: claudeConfig(),
        modelId: 'claude-sonnet-4-5',
      );

      expect(body.containsKey('cache_control'), isFalse);
    });
  });

  group('Claude prompt caching on the OpenRouter path', () {
    ProviderConfig openRouterConfig({
      required String modelId,
      bool claudePromptCachingEnabled = true,
    }) {
      return ProviderConfig(
        id: 'OpenRouter',
        enabled: true,
        name: 'OpenRouter',
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:9',
        providerType: ProviderKind.openai,
        claudePromptCachingEnabled: claudePromptCachingEnabled,
        modelOverrides: <String, dynamic>{
          modelId: <String, dynamic>{
            'type': 'chat',
            'input': ['text'],
            'output': ['text'],
            'abilities': ['tool'],
          },
        },
      );
    }

    test('injects cache_control for Claude models when enabled', () async {
      final body = await _captureRequest(
        config: openRouterConfig(modelId: 'anthropic/claude-sonnet-4-5'),
        modelId: 'anthropic/claude-sonnet-4-5',
      );

      expect(body['cache_control'], <String, dynamic>{'type': 'ephemeral'});
    });

    test('includes ttl 1h for OpenRouter Claude models', () async {
      final body = await _captureRequest(
        config: openRouterConfig(
          modelId: 'anthropic/claude-sonnet-4-5',
        ).copyWith(claudePromptCachingTtl: '1h'),
        modelId: 'anthropic/claude-sonnet-4-5',
      );

      expect(
        body['cache_control'],
        <String, dynamic>{'type': 'ephemeral', 'ttl': '1h'},
      );
    });

    test('omits cache_control for non-Claude models', () async {
      final body = await _captureRequest(
        config: openRouterConfig(modelId: 'openai/gpt-5'),
        modelId: 'openai/gpt-5',
      );

      expect(body.containsKey('cache_control'), isFalse);
    });

    test('omits cache_control when disabled', () async {
      final body = await _captureRequest(
        config: openRouterConfig(
          modelId: 'anthropic/claude-sonnet-4-5',
          claudePromptCachingEnabled: false,
        ),
        modelId: 'anthropic/claude-sonnet-4-5',
      );

      expect(body.containsKey('cache_control'), isFalse);
    });

    test('omits cache_control for non-OpenRouter OpenAI providers', () async {
      final body = await _captureRequest(
        config: ProviderConfig(
          id: 'OpenAI',
          enabled: true,
          name: 'OpenAI',
          apiKey: 'test-key',
          baseUrl: 'http://127.0.0.1:9',
          providerType: ProviderKind.openai,
          claudePromptCachingEnabled: true,
        ),
        modelId: 'anthropic/claude-sonnet-4-5',
      );

      expect(body.containsKey('cache_control'), isFalse);
    });

    test('simple generateText body also carries cache_control', () async {
      final body = await _captureGenerateTextBody(
        config: openRouterConfig(modelId: 'anthropic/claude-sonnet-4-5'),
        modelId: 'anthropic/claude-sonnet-4-5',
      );

      expect(body['cache_control'], <String, dynamic>{'type': 'ephemeral'});
    });

    test('Claude generateText body also carries cache_control', () async {
      final body = await _captureGenerateTextBody(
        config: ProviderConfig(
          id: 'ClaudeTest',
          enabled: true,
          name: 'ClaudeTest',
          apiKey: 'test-key',
          baseUrl: 'http://127.0.0.1:9',
          providerType: ProviderKind.claude,
          claudePromptCachingEnabled: true,
        ),
        modelId: 'claude-sonnet-4-5',
      );

      expect(body['cache_control'], <String, dynamic>{'type': 'ephemeral'});
    });
  });
}
