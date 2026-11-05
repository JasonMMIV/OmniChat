import 'package:OmniChat/core/utils/provider_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider API version', () {
    test('appends v1/v1beta when the base has no version', () {
      expect(
        ensureProviderApiVersion(
          'https://api.openai.com',
          providerType: 'openai',
        ).url,
        'https://api.openai.com/v1',
      );
      expect(
        ensureProviderApiVersion(
          'https://generativelanguage.googleapis.com',
          providerType: 'google',
        ).url,
        'https://generativelanguage.googleapis.com/v1beta',
      );
      expect(
        ensureProviderApiVersion(
          'https://openrouter.ai/api',
          providerType: 'openai',
        ).url,
        'https://openrouter.ai/api/v1',
      );
    });

    test('keeps an existing version and strips a pasted endpoint', () {
      expect(
        ensureProviderApiVersion(
          'https://api.openai.com/v1/',
          providerType: 'openai',
        ).url,
        'https://api.openai.com/v1',
      );
      expect(
        ensureProviderApiVersion(
          'https://api.openai.com/v1/chat/completions',
          providerType: 'openai',
        ).url,
        'https://api.openai.com/v1',
      );
    });
  });

  group('request URL resolution', () {
    test('OpenAI chat and Responses paths', () {
      expect(
        resolveProviderRequestUrl(
          baseUrl: 'https://api.openai.com/v1',
          providerType: 'openai',
          modelId: 'gpt-5.6',
          chatPath: '/chat/completions',
        ).url,
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        resolveProviderRequestUrl(
          baseUrl: 'https://api.openai.com/v1',
          providerType: 'openai',
          modelId: 'gpt-5.6',
          useResponses: true,
        ).url,
        'https://api.openai.com/v1/responses',
      );
    });

    test('an explicitly empty chatPath keeps the base as the endpoint', () {
      expect(
        resolveProviderRequestUrl(
          baseUrl: 'https://gateway.example.com/v1/complete',
          providerType: 'openai',
          modelId: 'gpt-5.6',
          chatPath: '',
        ).url,
        'https://gateway.example.com/v1/complete',
      );
    });

    test('a query on the base does not swallow the appended path', () {
      expect(
        resolveProviderRequestUrl(
          baseUrl: 'https://gateway.example.com/gemini?key=abc',
          providerType: 'google',
          modelId: 'gemini-4-argon',
          isStream: true,
        ).url,
        'https://gateway.example.com/gemini/models/'
        'gemini-4-argon:streamGenerateContent?key=abc&alt=sse',
      );
    });

    test('Claude uses /messages', () {
      expect(
        resolveProviderRequestUrl(
          baseUrl: 'https://api.anthropic.com/v1/',
          providerType: 'claude',
          modelId: 'claude-opus-5-5',
        ).url,
        'https://api.anthropic.com/v1/messages',
      );
    });

    test('Google generateContent and Vertex regional URLs', () {
      expect(
        resolveProviderRequestUrl(
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          providerType: 'google',
          modelId: 'gemini-4-argon',
        ).url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-4-argon:generateContent',
      );
      expect(
        resolveProviderRequestUrl(
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          providerType: 'google',
          modelId: 'gemini-4-argon',
          isStream: true,
        ).url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-4-argon:streamGenerateContent?alt=sse',
      );
      expect(
        resolveProviderRequestUrl(
          baseUrl: '',
          providerType: 'google',
          modelId: 'gemini-4-argon',
          vertexAI: true,
          location: 'us-central1',
          projectId: 'my-project',
          isStream: true,
        ).url,
        'https://aiplatform.googleapis.com/v1/projects/my-project/'
        'locations/us-central1/publishers/google/models/'
        'gemini-4-argon:streamGenerateContent?alt=sse',
      );
    });
  });
}
