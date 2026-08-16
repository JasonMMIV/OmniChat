import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/builtin_tools.dart';

ProviderConfig _claudeConfig(Map<String, dynamic> modelOverrides) {
  return ProviderConfig(
    id: 'claude-test',
    enabled: true,
    name: 'Claude',
    apiKey: 'test-key',
    baseUrl: 'https://api.anthropic.com',
    providerType: ProviderKind.claude,
    modelOverrides: modelOverrides,
  );
}

void main() {
  group('BuiltInToolNames.effectiveModelId', () {
    test('returns apiModelId override when present', () {
      final cfg = _claudeConfig({
        'my-model': {'apiModelId': 'claude-opus-4-7'},
      });
      expect(
        BuiltInToolNames.effectiveModelId(cfg: cfg, modelId: 'my-model'),
        'claude-opus-4-7',
      );
    });

    test('falls back to the logical model id', () {
      final cfg = _claudeConfig({});
      expect(
        BuiltInToolNames.effectiveModelId(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        'claude-opus-4-7',
      );
    });

    test('handles null config', () {
      expect(
        BuiltInToolNames.effectiveModelId(
          cfg: null,
          modelId: 'claude-opus-4-7',
        ),
        'claude-opus-4-7',
      );
    });
  });

  group('isClaudeDynamicWebSearchSupportedModel', () {
    test('supports official 4.7 / 4.6 / mythos models', () {
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-opus-4-7',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-opus-4-6',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-sonnet-4-6',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-opus-4-6-mythos',
        ),
        isTrue,
      );
    });

    test('supports Claude Opus 4.8 and Fable 5 models', () {
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-opus-4-8',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-fable-5',
        ),
        isTrue,
      );
    });

    test('is case and whitespace insensitive', () {
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          '  Claude-Opus-4-7  ',
        ),
        isTrue,
      );
    });

    test('rejects legacy and unrelated models', () {
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-opus-4-5@20251101',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-opus-4-1-20250805',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'claude-sonnet-4-5-20250929',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(
          'gpt-5',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(null),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchSupportedModel(''),
        isFalse,
      );
    });
  });

  group('supportsClaudeDynamicWebSearchForModel', () {
    test('true for claude kind with supported model', () {
      final cfg = _claudeConfig({});
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: 'claude-opus-4-8',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: 'claude-fable-5',
        ),
        isTrue,
      );
    });

    test('false for DeepSeek providers (legacy search tool only)', () {
      final cfg = ProviderConfig(
        id: 'deepseek-anthropic',
        enabled: true,
        name: 'DeepSeek',
        apiKey: 'test-key',
        baseUrl: 'https://api.deepseek.com/anthropic',
        providerType: ProviderKind.claude,
      );
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: 'deepseek-chat',
        ),
        isFalse,
      );
    });

    test('resolves via apiModelId override', () {
      final cfg = _claudeConfig({
        'Claude 4.7': {'apiModelId': 'claude-opus-4-7'},
      });
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: 'Claude 4.7',
        ),
        isTrue,
      );
    });

    test('false for non-claude providers', () {
      final cfg = ProviderConfig(
        id: 'openai-test',
        enabled: true,
        name: 'OpenAI',
        apiKey: 'test-key',
        baseUrl: 'https://api.openai.com',
        providerType: ProviderKind.openai,
      );
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        isFalse,
      );
    });

    group('isOpenRouterProvider', () {
      test('detects OpenRouter by baseUrl host or provider id', () {
        expect(
          BuiltInToolsHelper.isOpenRouterProvider(
            ProviderConfig(
              id: 'router',
              enabled: true,
              name: 'Router',
              apiKey: 'k',
              baseUrl: 'https://openrouter.ai/api/v1',
              providerType: ProviderKind.openai,
            ),
          ),
          isTrue,
        );
        expect(
          BuiltInToolsHelper.isOpenRouterProvider(
            ProviderConfig(
              id: 'openrouter-proxy',
              enabled: true,
              name: 'Proxy',
              apiKey: 'k',
              baseUrl: 'https://proxy.example.com',
              providerType: ProviderKind.openai,
            ),
          ),
          isTrue,
        );
        expect(
          BuiltInToolsHelper.isOpenRouterProvider(null),
          isFalse,
        );
        expect(
          BuiltInToolsHelper.isOpenRouterProvider(
            ProviderConfig(
              id: 'openai',
              enabled: true,
              name: 'OpenAI',
              apiKey: 'k',
              baseUrl: 'https://api.openai.com',
              providerType: ProviderKind.openai,
            ),
          ),
          isFalse,
        );
      });
    });

    group('isDeepSeekProvider', () {
      test('detects DeepSeek by baseUrl host, id, or name', () {
        expect(
          BuiltInToolsHelper.isDeepSeekProvider(
            ProviderConfig(
              id: 'deepseek',
              enabled: true,
              name: 'DeepSeek',
              apiKey: 'k',
              baseUrl: 'https://api.deepseek.com',
              providerType: ProviderKind.openai,
            ),
          ),
          isTrue,
        );
        expect(
          BuiltInToolsHelper.isDeepSeekProvider(
            ProviderConfig(
              id: 'ds-claude',
              enabled: true,
              name: 'DeepSeek-Anthropic',
              apiKey: 'k',
              baseUrl: 'https://api.deepseek.com/anthropic',
              providerType: ProviderKind.claude,
            ),
          ),
          isTrue,
        );
        expect(
          BuiltInToolsHelper.isDeepSeekProvider(null),
          isFalse,
        );
        expect(
          BuiltInToolsHelper.isDeepSeekProvider(
            ProviderConfig(
              id: 'anthropic',
              enabled: true,
              name: 'Anthropic',
              apiKey: 'k',
              baseUrl: 'https://api.anthropic.com',
              providerType: ProviderKind.claude,
            ),
          ),
          isFalse,
        );
      });
    });

    group('supportsBuiltInSearchForModel', () {
      ProviderConfig _openRouter() => ProviderConfig(
        id: 'openrouter',
        enabled: true,
        name: 'OpenRouter',
        apiKey: 'k',
        baseUrl: 'https://openrouter.ai/api/v1',
        providerType: ProviderKind.openai,
      );

      test('enables web search for OpenRouter chat-completions models', () {
        expect(
          BuiltInToolsHelper.supportsBuiltInSearchForModel(
            cfg: _openRouter(),
            modelId: 'deepseek/deepseek-chat',
          ),
          isTrue,
        );
      });

      test('keeps OpenRouter Responses path unsupported', () {
        expect(
          BuiltInToolsHelper.supportsBuiltInSearchForModel(
            cfg: _openRouter().copyWith(useResponseApi: true),
            modelId: 'deepseek/deepseek-chat',
          ),
          isFalse,
        );
      });

      test('enables web search for DeepSeek Claude-compatible providers', () {
        expect(
          BuiltInToolsHelper.supportsBuiltInSearchForModel(
            cfg: ProviderConfig(
              id: 'deepseek',
              enabled: true,
              name: 'DeepSeek',
              apiKey: 'k',
              baseUrl: 'https://api.deepseek.com/anthropic',
              providerType: ProviderKind.claude,
            ),
            modelId: 'deepseek-chat',
          ),
          isTrue,
        );
      });
    });

    test('false for unsupported models and null inputs', () {
      final cfg = _claudeConfig({});
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: 'claude-opus-4-5@20251101',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: cfg,
          modelId: null,
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.supportsClaudeDynamicWebSearchForModel(
          cfg: null,
          modelId: 'claude-opus-4-7',
        ),
        isFalse,
      );
    });
  });

  group('isClaudeDynamicWebSearchEnabled', () {
    test('true when webSearch.toolVersion matches (camelCase)', () {
      final cfg = _claudeConfig({
        'claude-opus-4-7': {
          'webSearch': {'toolVersion': 'web_search_20260209'},
        },
      });
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchEnabled(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        isTrue,
      );
    });

    test('true when webSearch.tool_version matches (snake_case)', () {
      final cfg = _claudeConfig({
        'claude-opus-4-7': {
          'webSearch': {'tool_version': 'web_search_20260209'},
        },
      });
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchEnabled(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        isTrue,
      );
    });

    test('false without override or with a different tool version', () {
      final cfg = _claudeConfig({
        'claude-opus-4-7': {
          'webSearch': {'toolVersion': 'web_search_20250305'},
        },
      });
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchEnabled(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        isFalse,
      );
      final empty = _claudeConfig({});
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchEnabled(
          cfg: empty,
          modelId: 'claude-opus-4-7',
        ),
        isFalse,
      );
    });

    test('false for unsupported models even with the override set', () {
      final cfg = _claudeConfig({
        'claude-opus-4-5@20251101': {
          'webSearch': {'toolVersion': 'web_search_20260209'},
        },
      });
      expect(
        BuiltInToolsHelper.isClaudeDynamicWebSearchEnabled(
          cfg: cfg,
          modelId: 'claude-opus-4-5@20251101',
        ),
        isFalse,
      );
    });
  });

  group('claudeBuiltInSearchToolType', () {
    test('returns web_search_20260209 when dynamic search is enabled', () {
      final cfg = _claudeConfig({
        'claude-opus-4-7': {
          'webSearch': {'toolVersion': 'web_search_20260209'},
        },
      });
      expect(
        BuiltInToolsHelper.claudeBuiltInSearchToolType(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        'web_search_20260209',
      );
    });

    test('returns legacy web_search_20250305 otherwise', () {
      final cfg = _claudeConfig({});
      expect(
        BuiltInToolsHelper.claudeBuiltInSearchToolType(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        'web_search_20250305',
      );
      expect(
        BuiltInToolsHelper.claudeBuiltInSearchToolType(
          cfg: cfg,
          modelId: 'claude-3-7-sonnet-20250219',
        ),
        'web_search_20250305',
      );
    });
  });
}
