import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/builtin_tools.dart';

ProviderConfig _config({
  required String id,
  required String baseUrl,
  ProviderKind kind = ProviderKind.openai,
  bool useResponseApi = false,
  Map<String, dynamic> overrides = const <String, dynamic>{},
}) => ProviderConfig(
  id: id,
  enabled: true,
  name: id,
  apiKey: 'k',
  baseUrl: baseUrl,
  providerType: kind,
  useResponseApi: useResponseApi,
  modelOverrides: overrides,
);

void main() {
  group('supportsNativeWebFetch', () {
    test('Claude is supported only on the official Anthropic endpoint', () {
      expect(
        BuiltInToolsHelper.supportsNativeWebFetch(
          cfg: _config(
            id: 'claude',
            baseUrl: 'https://api.anthropic.com',
            kind: ProviderKind.claude,
          ),
          modelId: 'claude-opus-4-7',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.supportsNativeWebFetch(
          cfg: _config(
            id: 'deepseek-claude',
            baseUrl: 'https://api.deepseek.com/anthropic',
            kind: ProviderKind.claude,
          ),
          modelId: 'deepseek-chat',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.supportsNativeWebFetch(
          cfg: _config(
            id: 'relay',
            baseUrl: 'https://relay.example.com',
            kind: ProviderKind.claude,
          ),
          modelId: 'claude-opus-4-7',
        ),
        isFalse,
      );
    });

    test('OpenRouter is supported on chat-completions only', () {
      final chat = _config(
        id: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1',
      );
      expect(
        BuiltInToolsHelper.supportsNativeWebFetch(
          cfg: chat,
          modelId: 'anthropic/claude-sonnet-4',
        ),
        isTrue,
      );
      expect(
        BuiltInToolsHelper.supportsNativeWebFetch(
          cfg: chat.copyWith(useResponseApi: true),
          modelId: 'anthropic/claude-sonnet-4',
        ),
        isFalse,
      );
    });

    test('Gemini url_context is a native fetch capability', () {
      final cfg = _config(
        id: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        kind: ProviderKind.google,
      );
      expect(
        BuiltInToolsHelper.supportsNativeWebFetch(
          cfg: cfg,
          modelId: 'gemini-3-pro',
        ),
        isTrue,
      );
    });
  });

  group('isNativeWebFetchEnabled', () {
    test('requires the per-model builtInTools opt-in', () {
      final cfg = _config(
        id: 'claude',
        baseUrl: 'https://api.anthropic.com',
        kind: ProviderKind.claude,
      );
      expect(
        BuiltInToolsHelper.isNativeWebFetchEnabled(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        isFalse,
      );
      expect(
        BuiltInToolsHelper.isNativeWebFetchEnabled(
          cfg: cfg.copyWith(
            modelOverrides: {
              'claude-opus-4-7': {
                'builtInTools': [BuiltInToolNames.webFetch],
              },
            },
          ),
          modelId: 'claude-opus-4-7',
        ),
        isTrue,
      );
    });

    test('Gemini uses url_context, not web_fetch', () {
      final cfg = _config(
        id: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        kind: ProviderKind.google,
        overrides: {
          'gemini-3-pro': {
            'builtInTools': [BuiltInToolNames.urlContext],
          },
        },
      );
      expect(
        BuiltInToolsHelper.isNativeWebFetchEnabled(
          cfg: cfg,
          modelId: 'gemini-3-pro',
        ),
        isTrue,
      );
    });

    test('DeepSeek Claude-compatible never enables it', () {
      final cfg = _config(
        id: 'deepseek-claude',
        baseUrl: 'https://api.deepseek.com/anthropic',
        kind: ProviderKind.claude,
        overrides: {
          'deepseek-chat': {
            'builtInTools': [BuiltInToolNames.webFetch],
          },
        },
      );
      expect(
        BuiltInToolsHelper.isNativeWebFetchEnabled(
          cfg: cfg,
          modelId: 'deepseek-chat',
        ),
        isFalse,
      );
    });
  });

  group('Claude web fetch tool version', () {
    test('defaults to the stable web_fetch alias', () {
      expect(
        BuiltInToolsHelper.claudeBuiltInFetchToolType(
          cfg: _config(
            id: 'claude',
            baseUrl: 'https://api.anthropic.com',
            kind: ProviderKind.claude,
          ),
          modelId: 'claude-opus-4-7',
        ),
        'web_fetch',
      );
    });

    test('honours a pinned supported version and its beta header', () {
      final cfg = _config(
        id: 'claude',
        baseUrl: 'https://api.anthropic.com',
        kind: ProviderKind.claude,
        overrides: {
          'claude-opus-4-7': {
            'webFetch': {'toolVersion': 'web_fetch_20260318'},
          },
        },
      );
      expect(
        BuiltInToolsHelper.claudeBuiltInFetchToolType(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        'web_fetch_20260318',
      );
      expect(
        BuiltInToolsHelper.claudeWebFetchBetaHeader('web_fetch_20260318'),
        'web-fetch-2026-03-18',
      );
      expect(BuiltInToolsHelper.claudeWebFetchBetaHeader('web_fetch'), isNull);
    });

    test('unknown versions fall back to stable', () {
      final cfg = _config(
        id: 'claude',
        baseUrl: 'https://api.anthropic.com',
        kind: ProviderKind.claude,
        overrides: {
          'claude-opus-4-7': {
            'webFetch': {'toolVersion': 'not-a-tool'},
          },
        },
      );
      expect(
        BuiltInToolsHelper.claudeBuiltInFetchToolType(
          cfg: cfg,
          modelId: 'claude-opus-4-7',
        ),
        'web_fetch',
      );
    });
  });

  test('webFetch is normalized and stored before url_context', () {
    expect(BuiltInToolNames.normalize('webFetch'), BuiltInToolNames.webFetch);
    expect(
      BuiltInToolNames.orderedForStorage([
        BuiltInToolNames.urlContext,
        BuiltInToolNames.webFetch,
        BuiltInToolNames.search,
      ]),
      [
        BuiltInToolNames.search,
        BuiltInToolNames.webFetch,
        BuiltInToolNames.urlContext,
      ],
    );
  });
}
