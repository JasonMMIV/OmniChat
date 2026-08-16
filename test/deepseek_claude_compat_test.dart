import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/utils/reasoning_capabilities.dart';

/// Routes all HTTP traffic through [server] while preserving [config]'s
/// original baseUrl, so baseUrl-based provider detection still works.
class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides(this.port);

  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    return client;
  }
}

Future<Map<String, dynamic>> _captureClaudeRequest({
  required ProviderConfig config,
  required String modelId,
  int? thinkingBudget,
  bool preserveBaseUrl = false,
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
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      }),
    );
    await request.response.close();
  });

  final localConfig = preserveBaseUrl
      ? config
      : config.copyWith(
          baseUrl: 'http://${server.address.address}:${server.port}',
        );
  try {
    Future<void> call() => ChatApiService.generateText(
      config: localConfig,
      modelId: modelId,
      prompt: 'hello',
      thinkingBudget: thinkingBudget,
    );
    if (preserveBaseUrl) {
      await HttpOverrides.runZoned(
        call,
        createHttpClient: (context) {
          return _ProxyHttpOverrides(server.port).createHttpClient(context);
        },
      );
    } else {
      await call();
    }
    return await bodyCompleter.future.timeout(const Duration(seconds: 2));
  } finally {
    await server.close(force: true);
  }
}

void main() {
  group('DeepSeek Claude-compatible provider detection', () {
    test(
      'detects DeepSeek via baseUrl even when modelId has no deepseek token',
      () async {
        final body = await _captureClaudeRequest(
          config: ProviderConfig(
            id: 'MyCustomClaudeProxy',
            enabled: true,
            name: 'My Claude Proxy',
            apiKey: 'test-key',
            baseUrl: 'http://api.deepseek.com/anthropic',
            providerType: ProviderKind.claude,
            modelOverrides: <String, dynamic>{
              'custom-chat-model': <String, dynamic>{
                'type': 'chat',
                'input': ['text'],
                'output': ['text'],
                'abilities': ['reasoning'],
              },
            },
          ),
          modelId: 'custom-chat-model',
          thinkingBudget: ReasoningBudget.heavy,
          preserveBaseUrl: true,
        );

        expect(body['thinking'], <String, dynamic>{'type': 'enabled'});
        expect(body['output_config'], <String, dynamic>{'effort': 'high'});
      },
    );

    test('detects DeepSeek via provider id', () async {
      final body = await _captureClaudeRequest(
        config: ProviderConfig(
          id: 'DeepSeek-Anthropic',
          enabled: true,
          name: 'My Proxy',
          apiKey: 'test-key',
          baseUrl: 'https://api.example.com/anthropic',
          providerType: ProviderKind.claude,
          modelOverrides: <String, dynamic>{
            'custom-chat-model': <String, dynamic>{
              'type': 'chat',
              'input': ['text'],
              'output': ['text'],
              'abilities': ['reasoning'],
            },
          },
        ),
        modelId: 'custom-chat-model',
        thinkingBudget: ReasoningBudget.heavy,
      );

      expect(body['thinking'], <String, dynamic>{'type': 'enabled'});
    });

    test('detects DeepSeek via provider name', () async {
      final body = await _captureClaudeRequest(
        config: ProviderConfig(
          id: 'proxy-1',
          enabled: true,
          name: 'DeepSeek Claude Endpoint',
          apiKey: 'test-key',
          baseUrl: 'https://api.example.com/anthropic',
          providerType: ProviderKind.claude,
          modelOverrides: <String, dynamic>{
            'custom-chat-model': <String, dynamic>{
              'type': 'chat',
              'input': ['text'],
              'output': ['text'],
              'abilities': ['reasoning'],
            },
          },
        ),
        modelId: 'custom-chat-model',
        thinkingBudget: ReasoningBudget.heavy,
      );

      expect(body['thinking'], <String, dynamic>{'type': 'enabled'});
    });

    test('keeps modelId-based detection when config is unrelated', () async {
      final body = await _captureClaudeRequest(
        config: ProviderConfig(
          id: 'Claude',
          enabled: true,
          name: 'Claude',
          apiKey: 'test-key',
          baseUrl: 'https://api.anthropic.com',
          providerType: ProviderKind.claude,
          modelOverrides: <String, dynamic>{
            'deepseek-chat': <String, dynamic>{
              'type': 'chat',
              'input': ['text'],
              'output': ['text'],
              'abilities': ['reasoning'],
            },
          },
        ),
        modelId: 'deepseek-chat',
        thinkingBudget: ReasoningBudget.heavy,
      );

      expect(body['thinking'], <String, dynamic>{'type': 'enabled'});
      expect(body['output_config'], <String, dynamic>{'effort': 'high'});
    });

    test('non-DeepSeek Claude providers keep adaptive/disabled behavior',
        () async {
      final body = await _captureClaudeRequest(
        config: ProviderConfig(
          id: 'Claude',
          enabled: true,
          name: 'Claude',
          apiKey: 'test-key',
          baseUrl: 'https://api.anthropic.com',
          providerType: ProviderKind.claude,
          modelOverrides: <String, dynamic>{
            'claude-opus-4-7': <String, dynamic>{
              'type': 'chat',
              'input': ['text'],
              'output': ['text'],
              'abilities': ['reasoning'],
            },
          },
        ),
        modelId: 'claude-opus-4-7',
        thinkingBudget: ReasoningBudget.heavy,
      );

      // claude-opus-4-7 is not DeepSeek-compatible: keeps adaptive thinking.
      expect(body['thinking'], isNot(<String, dynamic>{'type': 'enabled'}));
    });
  });
}
