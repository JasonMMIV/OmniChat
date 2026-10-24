import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/utils/reasoning_capabilities.dart';

/// Routes all HTTP traffic through [server] while preserving [config]'s
/// original baseUrl, so host-based provider detection still works.
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

Future<Map<String, dynamic>> _captureGenerateTextBody({
  required ProviderConfig config,
  required String modelId,
  int? thinkingBudget,
  bool preserveBaseUrl = false,
}) async {
  final bodyCompleter = Completer<Map<String, dynamic>>();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (!bodyCompleter.isCompleted) {
      bodyCompleter.complete(jsonDecode(raw) as Map<String, dynamic>);
    }
    request.response.headers.contentType = ContentType.json;
    final isResponses = request.uri.path.endsWith('/responses');
    request.response.write(
      jsonEncode(
        isResponses
            ? {'output_text': 'ok'}
            : {
                'choices': [
                  {
                    'message': {'content': 'ok'},
                  },
                ],
              },
      ),
    );
    await request.response.close();
  });

  final localConfig = preserveBaseUrl
      ? config
      : config.copyWith(
          baseUrl: 'http://${server.address.address}:${server.port}/v1',
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
        createHttpClient: (context) =>
            _ProxyHttpOverrides(server.port).createHttpClient(context),
      );
    } else {
      await call();
    }
    return await bodyCompleter.future.timeout(const Duration(seconds: 2));
  } finally {
    await server.close(force: true);
  }
}

ProviderConfig _config({
  String baseUrl = 'http://127.0.0.1/v1',
  String modelId = 'm',
  String? wire,
  bool useResponseApi = false,
  List<String> abilities = const ['reasoning'],
  List<Map<String, String>> body = const <Map<String, String>>[],
}) {
  return ProviderConfig(
    id: 'test-provider',
    enabled: true,
    name: 'Test Provider',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: useResponseApi,
    modelOverrides: <String, dynamic>{
      modelId: <String, dynamic>{
        'apiModelId': modelId,
        'abilities': abilities,
        if (wire != null) 'reasoningWire': wire,
        if (body.isNotEmpty) 'body': body,
      },
    },
  );
}

void main() {
  test(
    'explicit chat.thinking_mode replaces the legacy reasoning params',
    () async {
      final body = await _captureGenerateTextBody(
        config: _config(wire: 'chat.thinking_mode'),
        modelId: 'm',
        thinkingBudget: ReasoningBudget.medium,
      );

      expect(body['thinking_mode'], isTrue);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body.containsKey('reasoning'), isFalse);
      expect(body.containsKey('thinking'), isFalse);
      expect(body.containsKey('enable_thinking'), isFalse);
    },
  );

  test('explicit chat.enable_thinking carries the budget', () async {
    final body = await _captureGenerateTextBody(
      config: _config(wire: 'chat.enable_thinking'),
      modelId: 'm',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(body['enable_thinking'], isTrue);
    expect(body['thinking_budget'], ReasoningBudget.medium);
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  test('explicit chat.none strips every reasoning key', () async {
    final body = await _captureGenerateTextBody(
      config: _config(wire: 'chat.none'),
      modelId: 'm',
      thinkingBudget: ReasoningBudget.medium,
    );

    for (final key in const [
      'reasoning_effort',
      'reasoning',
      'thinking',
      'enable_thinking',
      'thinking_mode',
      'thinking_budget',
      'chat_template_kwargs',
    ]) {
      expect(body.containsKey(key), isFalse, reason: key);
    }
  });

  test(
    'explicit responses.effort writes the Responses reasoning object',
    () async {
      final body = await _captureGenerateTextBody(
        config: _config(wire: 'responses.effort', useResponseApi: true),
        modelId: 'm',
        thinkingBudget: ReasoningBudget.heavy,
      );

      expect(body['reasoning'], <String, dynamic>{
        'summary': 'auto',
        'effort': 'high',
      });
    },
  );

  test('explicit responses.none never sends reasoning', () async {
    final body = await _captureGenerateTextBody(
      config: _config(wire: 'responses.none', useResponseApi: true),
      modelId: 'm',
      thinkingBudget: ReasoningBudget.heavy,
    );

    expect(body.containsKey('reasoning'), isFalse);
  });

  test('auto (no wire) keeps the legacy reasoning_effort chain', () async {
    final body = await _captureGenerateTextBody(
      config: _config(),
      modelId: 'm',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(body['reasoning_effort'], 'medium');
    expect(body.containsKey('reasoning'), isFalse);
    expect(body.containsKey('enable_thinking'), isFalse);
  });

  test(
    'auto on OpenRouter still sends reasoning_effort (B leaves auto alone)',
    () async {
      final body = await _captureGenerateTextBody(
        config: _config(baseUrl: 'http://openrouter.ai/api/v1'),
        modelId: 'm',
        thinkingBudget: ReasoningBudget.medium,
        preserveBaseUrl: true,
      );

      expect(body['reasoning_effort'], 'medium');
      expect(body.containsKey('reasoning'), isFalse);
    },
  );

  test('a wire saved for another transport falls back to auto', () async {
    final body = await _captureGenerateTextBody(
      config: _config(wire: 'claude.budget'),
      modelId: 'm',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(body['reasoning_effort'], 'medium');
    expect(body.containsKey('thinking'), isFalse);
  });

  test('a custom body still overrides the explicit dialect', () async {
    final body = await _captureGenerateTextBody(
      config: _config(
        wire: 'chat.thinking_mode',
        body: const [
          {'key': 'thinking_mode', 'value': 'false'},
        ],
      ),
      modelId: 'm',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(body['thinking_mode'], isFalse);
  });

  test('the Kimi normalizer does not overwrite an explicit dialect', () async {
    final body = await _captureGenerateTextBody(
      config: _config(modelId: 'kimi-k2.5', wire: 'chat.thinking_mode'),
      modelId: 'kimi-k2.5',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(body['thinking_mode'], isTrue);
    expect(body.containsKey('thinking'), isFalse);
  });

  test('an explicit wire on a non-reasoning model writes nothing', () async {
    final body = await _captureGenerateTextBody(
      config: _config(abilities: const [], wire: 'chat.thinking_mode'),
      modelId: 'm',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(body.containsKey('thinking_mode'), isFalse);
    expect(body.containsKey('reasoning_effort'), isFalse);
  });
}
