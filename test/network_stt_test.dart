import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/stt/network_stt.dart';

OpenAiWhisperSttOptions _openAi({String? id}) => OpenAiWhisperSttOptions(
  id: id,
  enabled: true,
  name: 'My Whisper',
  apiKey: 'sk-123',
  baseUrl: kDefaultOpenAiSttEndpoint,
  model: 'whisper-1',
);

void main() {
  group('SttServiceOptions JSON round-trip', () {
    test('OpenAI Whisper round-trips with all fields', () {
      final original = OpenAiWhisperSttOptions(
        id: 'stt-1',
        enabled: true,
        name: 'My Whisper',
        apiKey: 'sk-123',
        baseUrl: 'https://api.openai.com/v1/audio/transcriptions',
        model: 'whisper-1',
        language: 'zh',
      );

      final restored = SttServiceOptions.fromJson(original.toJson());

      expect(restored, isA<OpenAiWhisperSttOptions>());
      expect(restored.id, 'stt-1');
      expect(restored.enabled, isTrue);
      expect(restored.name, 'My Whisper');
      expect(restored.kind, NetworkSttKind.openaiWhisper);
      expect(restored.language, 'zh');
      final typed = restored as OpenAiWhisperSttOptions;
      expect(typed.apiKey, 'sk-123');
      expect(typed.baseUrl, 'https://api.openai.com/v1/audio/transcriptions');
      expect(typed.model, 'whisper-1');
      expect(typed.configuredEndpoint, typed.baseUrl);
    });

    test('Groq Whisper round-trips with all fields', () {
      final restored = SttServiceOptions.fromJson(
        GroqWhisperSttOptions(
          id: 'stt-2',
          enabled: true,
          name: 'Groq Fast',
          apiKey: 'gsk-456',
          baseUrl: kDefaultGroqSttEndpoint,
          model: 'whisper-large-v3',
        ).toJson(),
      );

      expect(restored, isA<GroqWhisperSttOptions>());
      expect(restored.id, 'stt-2');
      expect(restored.kind, NetworkSttKind.groqWhisper);
      expect((restored as GroqWhisperSttOptions).apiKey, 'gsk-456');
    });

    test('Mistral and ElevenLabs round-trip', () {
      final mistral = SttServiceOptions.fromJson(
        MistralSttOptions(
          enabled: true,
          name: 'Mistral',
          apiKey: 'mk',
          baseUrl: kDefaultMistralSttEndpoint,
          model: kDefaultMistralSttModel,
        ).toJson(),
      );
      expect(mistral.kind, NetworkSttKind.mistral);
      expect(mistral.model, 'voxtral-mini-latest');

      final eleven = SttServiceOptions.fromJson(
        ElevenLabsSttOptions(
          enabled: true,
          name: 'Eleven',
          apiKey: 'xi',
          baseUrl: kDefaultElevenLabsSttEndpoint,
          model: kDefaultElevenLabsSttModel,
        ).toJson(),
      );
      expect(eleven.kind, NetworkSttKind.elevenLabs);
      expect(eleven.model, 'scribe_v2');
    });

    test('Qwen recorded round-trips workspace/region/endpoint', () {
      final restored = SttServiceOptions.fromJson(
        QwenAudioSttOptions(
          id: 'q1',
          enabled: true,
          name: 'Qwen',
          apiKey: 'dq',
          workspaceId: 'token-plan',
          region: 'ap-southeast-1',
          endpoint: 'https://proxy.example.com/qwen',
          model: kDefaultQwenSttModel,
        ).toJson(),
      );
      expect(restored, isA<QwenAudioSttOptions>());
      final qwen = restored as QwenAudioSttOptions;
      expect(qwen.workspaceId, 'token-plan');
      expect(qwen.region, 'ap-southeast-1');
      expect(qwen.endpoint, 'https://proxy.example.com/qwen');
      expect(qwen.mode, QwenSttMode.recorded);
      expect(qwen.configuredEndpoint, 'https://proxy.example.com/qwen');
    });

    test('Qwen defaults: recorded mode, cn-beijing, empty endpoint', () {
      final qwen = QwenAudioSttOptions(
        enabled: true,
        name: 'Qwen',
        apiKey: 'dq',
        model: kDefaultQwenSttModel,
      );
      expect(qwen.mode, QwenSttMode.recorded);
      expect(qwen.region, kDefaultQwenSttRegion);
      expect(qwen.endpoint, isEmpty);
      expect(qwen.configuredEndpoint, defaultSttEndpoint(NetworkSttKind.qwenAudio));
    });

    test('Qwen realtime mode survives round-trip and stays unavailable', () {
      final restored = SttServiceOptions.fromJson(
        QwenAudioSttOptions(
          enabled: true,
          name: 'Qwen',
          apiKey: 'dq',
          model: kDefaultQwenSttModel,
          mode: QwenSttMode.realtime,
        ).toJson(),
      ) as QwenAudioSttOptions;
      expect(restored.mode, QwenSttMode.realtime);
      expect(isSttServiceAvailable(restored), isFalse);
    });
  });

  group('tolerant parsing', () {
    test('unknown kind returns null (never silently becomes OpenAI)', () {
      expect(
        SttServiceOptions.tryFromJson({
          'kind': 'mystery',
          'enabled': true,
          'name': 'X',
          'apiKey': 'k',
        }),
        isNull,
      );
      expect(
        () => SttServiceOptions.fromJson({
          'kind': 'mystery',
          'enabled': true,
          'apiKey': 'k',
        }),
        throwsFormatException,
      );
    });

    test('missing api key and invalid base URL are rejected', () {
      expect(
        SttServiceOptions.tryFromJson({
          'kind': 'openaiWhisper',
          'enabled': true,
          'name': 'X',
        }),
        isNull,
      );
      expect(
        SttServiceOptions.tryFromJson({
          'kind': 'openaiWhisper',
          'enabled': true,
          'apiKey': 'k',
          'baseUrl': 'not a url',
        }),
        isNull,
      );
    });

    test('Qwen rejects URL in workspace and invalid endpoint override', () {
      expect(
        SttServiceOptions.tryFromJson({
          'kind': 'qwenAudio',
          'enabled': true,
          'apiKey': 'k',
          'workspaceId': 'https://x.dev',
        }),
        isNull,
      );
      expect(
        SttServiceOptions.tryFromJson({
          'kind': 'qwenAudio',
          'enabled': true,
          'apiKey': 'k',
          'endpoint': 'ftp://x',
        }),
        isNull,
      );
      expect(
        SttServiceOptions.tryFromJson({
          'kind': 'qwenAudio',
          'enabled': true,
          'apiKey': 'k',
        }),
        isA<QwenAudioSttOptions>(),
      );
    });

    test('legacy entries without new fields still load', () {
      final restored = SttServiceOptions.tryFromJson({
        'id': 'a',
        'enabled': true,
        'name': 'Legacy',
        'kind': 'groqWhisper',
        'apiKey': 'gsk',
        'baseUrl': 'https://api.groq.com/openai/v1/audio/transcriptions',
        'model': 'whisper-large-v3',
      });
      expect(restored, isA<GroqWhisperSttOptions>());
      expect(restored!.language, isEmpty);
      expect(restored.sampleRate, kDefaultSttSampleRate);
      expect(restored.segmentDurationSec, kDefaultSttSegmentDurationSec);
    });
  });

  group('shared getters and helpers', () {
    test('display names are stable', () {
      expect(networkSttKindDisplayName(NetworkSttKind.openaiWhisper), 'OpenAI Whisper');
      expect(networkSttKindDisplayName(NetworkSttKind.groqWhisper), 'Groq Whisper');
      expect(networkSttKindDisplayName(NetworkSttKind.mistral), 'Mistral Voxtral');
      expect(networkSttKindDisplayName(NetworkSttKind.elevenLabs), 'ElevenLabs Scribe');
      expect(networkSttKindDisplayName(NetworkSttKind.qwenAudio), 'Qwen Audio');
    });

    test('defaults per kind', () {
      expect(defaultSttModel(NetworkSttKind.openaiWhisper), 'whisper-1');
      expect(defaultSttModel(NetworkSttKind.groqWhisper), 'whisper-large-v3');
      expect(defaultSttModel(NetworkSttKind.mistral), 'voxtral-mini-latest');
      expect(defaultSttModel(NetworkSttKind.elevenLabs), 'scribe_v2');
      expect(defaultSttModel(NetworkSttKind.qwenAudio), 'qwen-audio-3.0-asr-flash');
      expect(defaultSttEndpoint(NetworkSttKind.elevenLabs), kDefaultElevenLabsSttEndpoint);
    });

    test('resolvedLanguage treats auto/empty as null', () {
      expect(_openAi().resolvedLanguage, isNull);
      final withAuto = OpenAiWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'k',
        baseUrl: kDefaultOpenAiSttEndpoint,
        model: 'whisper-1',
        language: ' AUTO ',
      );
      expect(withAuto.resolvedLanguage, isNull);
      final withZh = OpenAiWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'k',
        baseUrl: kDefaultOpenAiSttEndpoint,
        model: 'whisper-1',
        language: 'zh',
      );
      expect(withZh.resolvedLanguage, 'zh');
    });

    test('all batch kinds are available; Qwen realtime is not', () {
      expect(isSttServiceAvailable(_openAi()), isTrue);
      expect(
        isSttServiceAvailable(
          QwenAudioSttOptions(
            enabled: true,
            name: 'q',
            apiKey: 'k',
            model: kDefaultQwenSttModel,
          ),
        ),
        isTrue,
      );
    });

    test('generated ids are unique per instance', () {
      expect(_openAi().id, isNot(_openAi().id));
    });
  });
}
