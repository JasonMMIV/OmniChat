import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/opencode.dart';
import 'package:OmniChat/core/services/api/provider_request_headers.dart';

ProviderConfig _config({
  String id = 'OpenCode Go',
  String baseUrl = 'https://opencode.ai/zen/go/v1',
  OAuthProvider? oauthProvider,
}) {
  return ProviderConfig(
    id: id,
    enabled: true,
    name: id,
    apiKey: 'test-key',
    baseUrl: baseUrl,
    oauthProvider: oauthProvider,
  );
}

void main() {
  group('isOpenCodeBaseUrl', () {
    test('accepts the exact OpenCode host over http and https', () {
      expect(isOpenCodeBaseUrl('https://opencode.ai/zen/v1'), isTrue);
      expect(isOpenCodeBaseUrl('http://opencode.ai/zen/go/v1'), isTrue);
    });

    test('tolerates a scheme-less base URL', () {
      expect(isOpenCodeBaseUrl('opencode.ai/zen/v1'), isTrue);
    });

    test('rejects lookalike and unrelated hosts', () {
      expect(isOpenCodeBaseUrl('https://opencode.ai.example.com/v1'), isFalse);
      expect(isOpenCodeBaseUrl('https://fakeopencode.ai/v1'), isFalse);
      expect(isOpenCodeBaseUrl('https://openrouter.ai/api/v1'), isFalse);
      expect(isOpenCodeBaseUrl(''), isFalse);
    });
  });

  group('resolveOpenCodeSessionId', () {
    test('prefers the conversation id', () {
      expect(
        resolveOpenCodeSessionId(
          providerId: 'OpenCode Go',
          baseUrl: kOpenCodeGoBaseUrl,
          conversationId: ' conv-1 ',
          sessionId: 'session-1',
          requestId: 'request-1',
        ),
        'conv-1',
      );
    });

    test('falls back to session and request ids', () {
      expect(
        resolveOpenCodeSessionId(
          providerId: 'OpenCode Go',
          baseUrl: kOpenCodeGoBaseUrl,
          sessionId: 'session-1',
          requestId: 'request-1',
        ),
        'session-1',
      );
      expect(
        resolveOpenCodeSessionId(
          providerId: 'OpenCode Go',
          baseUrl: kOpenCodeGoBaseUrl,
          requestId: 'request-1',
        ),
        'request-1',
      );
    });

    test('uses a stable deterministic fallback when no id exists', () {
      final first = resolveOpenCodeSessionId(
        providerId: 'OpenCode Go',
        baseUrl: kOpenCodeGoBaseUrl,
      );
      final second = resolveOpenCodeSessionId(
        providerId: 'OpenCode Go',
        baseUrl: kOpenCodeGoBaseUrl,
      );
      expect(first, isNotEmpty);
      expect(first, second);
    });
  });

  group('providerSessionHeaders', () {
    test('emits the OpenCode contract for non-OAuth configs', () {
      final headers = providerSessionHeaders(
        _config(),
        conversationId: 'conv-1',
      );
      expect(headers['x-opencode-session'], 'conv-1');
      expect(headers['x-opencode-client'], 'omnichat');
    });

    test('does not emit OpenCode headers for other hosts', () {
      final headers = providerSessionHeaders(
        _config(baseUrl: 'https://openrouter.ai/api/v1'),
        conversationId: 'conv-1',
      );
      expect(headers, isEmpty);
    });

    test('keeps the existing OAuth behavior unchanged', () {
      final headers = providerSessionHeaders(
        _config(oauthProvider: OAuthProvider.chatgpt),
        sessionId: 'session-1',
        conversationId: 'conv-1',
        requestId: 'request-1',
      );
      expect(headers['session_id'], 'session-1');
      expect(headers['conversation_id'], 'conv-1');
      expect(headers['x-client-request-id'], 'request-1');
      expect(headers.containsKey('x-opencode-session'), isFalse);
    });
  });

  group('normalizeOpenCodeModelId', () {
    test('strips OpenCode provider prefixes', () {
      expect(normalizeOpenCodeModelId('opencode/glm-5.3'), 'glm-5.3');
      expect(normalizeOpenCodeModelId('opencode-go/kimi-k3'), 'kimi-k3');
    });

    test('leaves bare ids and unrelated slashes intact', () {
      expect(normalizeOpenCodeModelId('glm-5.3'), 'glm-5.3');
      expect(normalizeOpenCodeModelId('anthropic/claude-sonnet-5'), 'anthropic/claude-sonnet-5');
    });
  });
}
