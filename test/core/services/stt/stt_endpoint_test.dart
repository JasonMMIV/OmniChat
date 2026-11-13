import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/stt/network_stt.dart';
import 'package:OmniChat/core/services/stt/stt_endpoint.dart';

void main() {
  group('resolveSttEndpoint', () {
    test('keeps an existing full OpenAI endpoint (no duplicate suffix)', () {
      final uri = resolveSttEndpoint(
        raw: kDefaultOpenAiSttEndpoint,
        kind: NetworkSttKind.openaiWhisper,
      );
      expect(
        uri.toString(),
        'https://api.openai.com/v1/audio/transcriptions',
      );
    });

    test('keeps an existing full Groq endpoint', () {
      final uri = resolveSttEndpoint(
        raw: kDefaultGroqSttEndpoint,
        kind: NetworkSttKind.groqWhisper,
      );
      expect(
        uri.toString(),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
    });

    test('empty raw falls back to the provider default', () {
      expect(
        resolveSttEndpoint(raw: '  ', kind: NetworkSttKind.mistral).toString(),
        kDefaultMistralSttEndpoint,
      );
    });

    test('host-only base gets the full default path', () {
      expect(
        resolveSttEndpoint(
          raw: 'https://api.openai.com',
          kind: NetworkSttKind.openaiWhisper,
        ).toString(),
        'https://api.openai.com/v1/audio/transcriptions',
      );
      expect(
        resolveSttEndpoint(
          raw: 'https://api.groq.com/',
          kind: NetworkSttKind.groqWhisper,
        ).toString(),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
    });

    test('trailing slash is trimmed before joining', () {
      expect(
        resolveSttEndpoint(
          raw: 'https://api.mistral.ai/v1/',
          kind: NetworkSttKind.mistral,
        ).toString(),
        'https://api.mistral.ai/v1/audio/transcriptions',
      );
    });

    test('proxy prefix is preserved', () {
      expect(
        resolveSttEndpoint(
          raw: 'https://gateway.example.com/openai-proxy',
          kind: NetworkSttKind.openaiWhisper,
        ).toString(),
        'https://gateway.example.com/openai-proxy/v1/audio/transcriptions',
      );
    });

    test('Groq /openai base gets /v1/audio/transcriptions', () {
      expect(
        resolveSttEndpoint(
          raw: 'https://api.groq.com/openai',
          kind: NetworkSttKind.groqWhisper,
        ).toString(),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
      expect(
        resolveSttEndpoint(
          raw: 'https://api.groq.com/openai/v1',
          kind: NetworkSttKind.groqWhisper,
        ).toString(),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
    });

    test('ElevenLabs /v1 base appends speech-to-text', () {
      expect(
        resolveSttEndpoint(
          raw: 'https://api.elevenlabs.io/v1',
          kind: NetworkSttKind.elevenLabs,
        ).toString(),
        'https://api.elevenlabs.io/v1/speech-to-text',
      );
    });

    test('query string is preserved', () {
      final uri = resolveSttEndpoint(
        raw: 'https://api.openai.com/v1?api-version=2024-01-01',
        kind: NetworkSttKind.openaiWhisper,
      );
      expect(uri.path, '/v1/audio/transcriptions');
      expect(uri.queryParameters['api-version'], '2024-01-01');
    });

    test('rejects non-http schemes, userinfo and fragments', () {
      expect(
        () => resolveSttEndpoint(
          raw: 'ftp://api.openai.com',
          kind: NetworkSttKind.openaiWhisper,
        ),
        throwsFormatException,
      );
      expect(
        () => resolveSttEndpoint(
          raw: 'https://user:pass@api.openai.com',
          kind: NetworkSttKind.openaiWhisper,
        ),
        throwsFormatException,
      );
      expect(
        () => resolveSttEndpoint(
          raw: 'https://api.openai.com/#frag',
          kind: NetworkSttKind.openaiWhisper,
        ),
        throwsFormatException,
      );
    });

    test('case-insensitive suffix detection', () {
      expect(
        resolveSttEndpoint(
          raw: 'https://api.openai.com/V1/Audio/Transcriptions',
          kind: NetworkSttKind.openaiWhisper,
        ).path,
        '/V1/Audio/Transcriptions',
      );
    });
  });

  group('resolveQwenSttEndpoint', () {
    test('workspace + region builds the maas host', () {
      final uri = resolveQwenSttEndpoint(
        endpoint: '',
        workspaceId: 'token-plan',
        region: 'cn-beijing',
      );
      expect(
        uri.toString(),
        'https://token-plan.cn-beijing.maas.aliyuncs.com'
        '/api/v1/services/aigc/multimodal-generation/generation',
      );
    });

    test('no workspace uses dashscope (intl for ap-southeast-1)', () {
      expect(
        resolveQwenSttEndpoint(
          endpoint: '',
          workspaceId: '',
          region: 'cn-beijing',
        ).host,
        'dashscope.aliyuncs.com',
      );
      expect(
        resolveQwenSttEndpoint(
          endpoint: '',
          workspaceId: '',
          region: 'ap-southeast-1',
        ).host,
        'dashscope-intl.aliyuncs.com',
      );
    });

    test('endpoint override wins', () {
      expect(
        resolveQwenSttEndpoint(
          endpoint: 'https://proxy.example.com/qwen',
          workspaceId: 'token-plan',
          region: 'cn-beijing',
        ).toString(),
        'https://proxy.example.com/qwen',
      );
    });

    test('URL in workspace ID is rejected', () {
      expect(
        () => resolveQwenSttEndpoint(
          endpoint: '',
          workspaceId: 'https://evil.example.com',
          region: 'cn-beijing',
        ),
        throwsFormatException,
      );
    });
  });
}
