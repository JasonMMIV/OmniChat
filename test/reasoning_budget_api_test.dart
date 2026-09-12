import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/utils/reasoning_capabilities.dart';

Future<Map<String, dynamic>> _captureRequest({
  required ProviderConfig config,
  required String modelId,
  required int thinkingBudget,
}) async {
  final bodyCompleter = Completer<Map<String, dynamic>>();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
            {'text': 'ok'},
          ],
        }),
      );
    } else {
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        }),
      );
    }
    await request.response.close();
  });

  final localConfig = ProviderConfig(
    id: config.id,
    enabled: true,
    name: config.name,
    apiKey: 'test-key',
    baseUrl: 'http://${server.address.address}:${server.port}/v1',
    providerType: config.providerType,
  );
  try {
    await ChatApiService.generateText(
      config: localConfig,
      modelId: modelId,
      prompt: 'hello',
      thinkingBudget: thinkingBudget,
    );
    return await bodyCompleter.future.timeout(const Duration(seconds: 2));
  } finally {
    await server.close(force: true);
  }
}

void main() {
  test('maps namespaced GPT-5.4 budget to xhigh', () async {
    final body = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'openai/gpt-5.4',
      thinkingBudget: 64000,
    );

    expect(body['reasoning_effort'], 'xhigh');
  });

  test('maps GPT-5.6 max budget to max', () async {
    final body = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'openai/gpt-5.6',
      thinkingBudget: 128000,
    );

    expect(body['reasoning_effort'], 'max');
  });

  test(
    'normalizes Kimi K3 effort values and keeps reasoning enabled',
    () async {
      final offBody = await _captureRequest(
        config: ProviderConfig(
          id: 'OpenAI',
          enabled: true,
          name: 'OpenAI',
          apiKey: '',
          baseUrl: '',
          providerType: ProviderKind.openai,
        ),
        modelId: 'moonshotai/kimi-k3',
        thinkingBudget: ReasoningBudget.off,
      );
      final mediumBody = await _captureRequest(
        config: ProviderConfig(
          id: 'OpenAI',
          enabled: true,
          name: 'OpenAI',
          apiKey: '',
          baseUrl: '',
          providerType: ProviderKind.openai,
        ),
        modelId: 'moonshotai/kimi-k3',
        thinkingBudget: ReasoningBudget.medium,
      );
      final maxBody = await _captureRequest(
        config: ProviderConfig(
          id: 'OpenAI',
          enabled: true,
          name: 'OpenAI',
          apiKey: '',
          baseUrl: '',
          providerType: ProviderKind.openai,
        ),
        modelId: 'moonshotai/kimi-k3',
        thinkingBudget: ReasoningBudget.max,
      );

      expect(offBody['reasoning_effort'], 'low');
      expect(mediumBody['reasoning_effort'], 'high');
      expect(maxBody['reasoning_effort'], 'max');
      expect(offBody.containsKey('temperature'), isFalse);
      expect(mediumBody.containsKey('temperature'), isFalse);
      expect(maxBody.containsKey('temperature'), isFalse);
    },
  );

  test('normalizes Kimi K2.5 thinking body and strips sampling params', () async {
    final enabledBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'moonshotai/kimi-k2.5',
      thinkingBudget: ReasoningBudget.medium,
    );
    final offBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'moonshotai/kimi-k2.5',
      thinkingBudget: ReasoningBudget.off,
    );

    expect(enabledBody['thinking'], {'type': 'enabled'});
    expect(offBody['thinking'], {'type': 'disabled'});
    expect(enabledBody.containsKey('reasoning_effort'), isFalse);
    expect(offBody.containsKey('reasoning_effort'), isFalse);
    expect(enabledBody.containsKey('temperature'), isFalse);
    expect(enabledBody.containsKey('top_p'), isFalse);
    expect(enabledBody.containsKey('n'), isFalse);
    expect(enabledBody.containsKey('presence_penalty'), isFalse);
    expect(enabledBody.containsKey('frequency_penalty'), isFalse);
  });

  test('maps DeepSeek thinking mode and effort for chat completions', () async {
    final enabledBody = await _captureRequest(
      config: ProviderConfig(
        id: 'DeepSeek',
        enabled: true,
        name: 'DeepSeek',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'deepseek-v4-pro',
      thinkingBudget: ReasoningBudget.xhigh,
    );
    final disabledBody = await _captureRequest(
      config: ProviderConfig(
        id: 'DeepSeek',
        enabled: true,
        name: 'DeepSeek',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'deepseek-v4-pro',
      thinkingBudget: ReasoningBudget.off,
    );

    expect(enabledBody['thinking'], {'type': 'enabled'});
    // Manual §5.3: the Anthropic-style thinking knob replaces OpenAI-style
    // reasoning_effort in BOTH thinking states (no residual knob).
    expect(enabledBody.containsKey('reasoning_effort'), isFalse);
    expect(disabledBody['thinking'], {'type': 'disabled'});
    expect(disabledBody.containsKey('reasoning_effort'), isFalse);
  });

  test('maps Claude Opus max budget to adaptive max effort', () async {
    final body = await _captureRequest(
      config: ProviderConfig(
        id: 'Claude',
        enabled: true,
        name: 'Claude',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.claude,
      ),
      modelId: 'claude-opus-4.8',
      thinkingBudget: 128000,
    );

    expect(body['thinking'], {'type': 'adaptive', 'display': 'summarized'});
    expect(body['output_config'], {'effort': 'max'});
    expect(body.containsKey('temperature'), isFalse);
  });

  test(
    'keeps always-on Claude adaptive when the stored budget is off',
    () async {
      final body = await _captureRequest(
        config: ProviderConfig(
          id: 'Claude',
          enabled: true,
          name: 'Claude',
          apiKey: '',
          baseUrl: '',
          providerType: ProviderKind.claude,
        ),
        modelId: 'claude-fable-5',
        thinkingBudget: ReasoningBudget.off,
      );

      expect(body['thinking'], {'type': 'adaptive', 'display': 'summarized'});
      expect(body.containsKey('output_config'), isFalse);
      expect(body.containsKey('temperature'), isFalse);
    },
  );

  test('clamps a legacy Claude budget instead of sending max effort', () async {
    final body = await _captureRequest(
      config: ProviderConfig(
        id: 'Claude',
        enabled: true,
        name: 'Claude',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.claude,
      ),
      modelId: 'claude-sonnet-4-5',
      thinkingBudget: 64000,
    );

    expect(body['thinking'], {
      'type': 'enabled',
      'budget_tokens': ReasoningBudget.heavy,
    });
    expect(body.containsKey('output_config'), isFalse);
  });

  test('GPT-5.5 strips sampling params when reasoning is enabled, preserves when off, and Pro preserves', () async {
    final enabledBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'openai/gpt-5.5',
      thinkingBudget: ReasoningBudget.medium,
    );
    final offBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'openai/gpt-5.5',
      thinkingBudget: ReasoningBudget.off,
    );
    final proBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'gpt-5.5-pro',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(enabledBody['reasoning_effort'], 'medium');
    expect(enabledBody.containsKey('temperature'), isFalse);
    expect(enabledBody.containsKey('top_p'), isFalse);

    expect(offBody.containsKey('reasoning_effort'), isFalse);
    expect(offBody['temperature'], 0.3);

    expect(proBody['reasoning_effort'], 'medium');
    expect(proBody['temperature'], 0.3);
  });

  test('normalizes Kimi K2.7 thinking body and strips sampling params', () async {
    final enabledBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'moonshotai/kimi-k2.7',
      thinkingBudget: ReasoningBudget.medium,
    );
    final offBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'moonshotai/kimi-k2.7',
      thinkingBudget: ReasoningBudget.off,
    );

    expect(enabledBody['thinking'], {'type': 'enabled'});
    expect(offBody['thinking'], {'type': 'disabled'});
    expect(enabledBody.containsKey('reasoning_effort'), isFalse);
    expect(offBody.containsKey('reasoning_effort'), isFalse);
    expect(enabledBody.containsKey('temperature'), isFalse);
    expect(enabledBody.containsKey('top_p'), isFalse);
    expect(enabledBody.containsKey('n'), isFalse);
    expect(enabledBody.containsKey('presence_penalty'), isFalse);
    expect(enabledBody.containsKey('frequency_penalty'), isFalse);
    expect(offBody.containsKey('temperature'), isFalse);
    expect(offBody.containsKey('top_p'), isFalse);
  });

  test('normalizes GLM 5.x and Zhipu-like provider thinking knob', () async {
    final glmBody = await _captureRequest(
      config: ProviderConfig(
        id: 'GenericOpenAI',
        enabled: true,
        name: 'GenericOpenAI',
        apiKey: '',
        baseUrl: 'https://api.example.com/v1',
        providerType: ProviderKind.openai,
      ),
      modelId: 'glm-5.2',
      thinkingBudget: ReasoningBudget.medium,
    );
    final zaiBody = await _captureRequest(
      config: ProviderConfig(
        id: 'Zhipu',
        enabled: true,
        name: 'Zhipu',
        apiKey: '',
        baseUrl: 'https://api.z.ai/v1',
        providerType: ProviderKind.openai,
      ),
      modelId: 'glm-4.6',
      thinkingBudget: ReasoningBudget.medium,
    );

    expect(glmBody['thinking'], {'type': 'enabled'});
    expect(glmBody.containsKey('reasoning_effort'), isFalse);

    expect(zaiBody['thinking'], {'type': 'enabled'});
    expect(zaiBody.containsKey('reasoning_effort'), isFalse);
  });

  test('DeepSeek v4.1 Flash keeps the thinking knob on every host', () async {
    final maxBody = await _captureRequest(
      config: ProviderConfig(
        id: 'DeepSeek',
        enabled: true,
        name: 'DeepSeek',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'deepseek-v4.1-flash',
      thinkingBudget: ReasoningBudget.max,
    );

    // The max tier is a UI-level capability for v4.1 Flash; on the wire the
    // Anthropic-style thinking knob replaces reasoning_effort on all hosts.
    expect(maxBody['thinking'], {'type': 'enabled'});
    expect(maxBody.containsKey('reasoning_effort'), isFalse);
  });

  test('GLM 5.3 Flash maps to the Zhipu thinking knob', () async {
    final body = await _captureRequest(
      config: ProviderConfig(
        id: 'Zhipu',
        enabled: true,
        name: 'Zhipu',
        apiKey: '',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        providerType: ProviderKind.openai,
      ),
      modelId: 'glm-5.3-flash',
      thinkingBudget: ReasoningBudget.xhigh,
    );

    expect(body['thinking'], {'type': 'enabled'});
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  test('GPT-5.6 Luna supports none..max efforts and strips sampling while reasoning', () async {
    final mediumBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'gpt-5.6-luna',
      thinkingBudget: ReasoningBudget.medium,
    );
    final maxBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'gpt-5.6-luna',
      thinkingBudget: ReasoningBudget.max,
    );
    final offBody = await _captureRequest(
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: '',
        baseUrl: '',
        providerType: ProviderKind.openai,
      ),
      modelId: 'gpt-5.6-luna',
      thinkingBudget: ReasoningBudget.off,
    );

    expect(mediumBody['reasoning_effort'], 'medium');
    expect(mediumBody.containsKey('temperature'), isFalse);
    expect(mediumBody.containsKey('top_p'), isFalse);

    expect(maxBody['reasoning_effort'], 'max');

    // Luna officially supports effort 'none' (a real off), unlike 5.5.
    expect(offBody['reasoning_effort'], 'none');
    expect(offBody['temperature'], 0.3);
  });

  test('Muse Spark 1.3 always reasons: off becomes minimal, max clamps to xhigh', () async {
    final mediumBody = await _captureRequest(
      config: ProviderConfig(
        id: 'MetaModelApi',
        enabled: true,
        name: 'MetaModelApi',
        apiKey: '',
        baseUrl: 'https://api.meta.ai/v1',
        providerType: ProviderKind.openai,
      ),
      modelId: 'muse-spark-1.3',
      thinkingBudget: ReasoningBudget.medium,
    );
    final maxBody = await _captureRequest(
      config: ProviderConfig(
        id: 'MetaModelApi',
        enabled: true,
        name: 'MetaModelApi',
        apiKey: '',
        baseUrl: 'https://api.meta.ai/v1',
        providerType: ProviderKind.openai,
      ),
      modelId: 'muse-spark-1.3',
      thinkingBudget: ReasoningBudget.max,
    );
    final offBody = await _captureRequest(
      config: ProviderConfig(
        id: 'MetaModelApi',
        enabled: true,
        name: 'MetaModelApi',
        apiKey: '',
        baseUrl: 'https://api.meta.ai/v1',
        providerType: ProviderKind.openai,
      ),
      modelId: 'muse-spark-1.3',
      thinkingBudget: ReasoningBudget.off,
    );

    expect(mediumBody['reasoning_effort'], 'medium');
    // The API rejects effort 'none' (always reasons) and has no 'max' yet.
    expect(maxBody['reasoning_effort'], 'xhigh');
    expect(offBody['reasoning_effort'], 'minimal');
  });
}
