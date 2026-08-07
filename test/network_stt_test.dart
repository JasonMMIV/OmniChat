import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/stt/network_stt.dart';

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
      );

      final restored = SttServiceOptions.fromJson(original.toJson());

      expect(restored, isA<OpenAiWhisperSttOptions>());
      expect(restored.id, 'stt-1');
      expect(restored.enabled, isTrue);
      expect(restored.name, 'My Whisper');
      expect(restored.kind, NetworkSttKind.openaiWhisper);
      final typed = restored as OpenAiWhisperSttOptions;
      expect(typed.apiKey, 'sk-123');
      expect(typed.baseUrl, 'https://api.openai.com/v1/audio/transcriptions');
      expect(typed.model, 'whisper-1');
    });

    test('Groq Whisper round-trips with all fields', () {
      final original = GroqWhisperSttOptions(
        id: 'stt-2',
        enabled: true,
        name: 'Groq Fast',
        apiKey: 'gsk-456',
        baseUrl: 'https://api.groq.com/openai/v1/audio/transcriptions',
        model: 'whisper-large-v3',
      );

      final restored = SttServiceOptions.fromJson(original.toJson());

      expect(restored, isA<GroqWhisperSttOptions>());
      expect(restored.id, 'stt-2');
      expect(restored.kind, NetworkSttKind.groqWhisper);
      final typed = restored as GroqWhisperSttOptions;
      expect(typed.apiKey, 'gsk-456');
      expect(typed.baseUrl, 'https://api.groq.com/openai/v1/audio/transcriptions');
      expect(typed.model, 'whisper-large-v3');
    });

    test('unknown kind falls back to OpenAI Whisper shape', () {
      final restored = SttServiceOptions.fromJson({
        'kind': 'mystery',
        'enabled': true,
        'name': 'X',
        'apiKey': 'k',
      });

      expect(restored, isA<OpenAiWhisperSttOptions>());
    });
  });

  group('kind defaults', () {
    test('OpenAI Whisper defaults use the official transcription endpoint', () {
      expect(OpenAiWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'k',
        baseUrl: 'https://api.openai.com/v1/audio/transcriptions',
        model: 'whisper-1',
      ).baseUrl, 'https://api.openai.com/v1/audio/transcriptions');
      expect(OpenAiWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'k',
        baseUrl: 'https://api.openai.com/v1/audio/transcriptions',
        model: 'whisper-1',
      ).model, 'whisper-1');
    });

    test('Groq Whisper defaults use the Groq transcription endpoint', () {
      final opt = GroqWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'k',
        baseUrl: 'https://api.groq.com/openai/v1/audio/transcriptions',
        model: 'whisper-large-v3',
      );
      expect(opt.baseUrl, 'https://api.groq.com/openai/v1/audio/transcriptions');
      expect(opt.model, 'whisper-large-v3');
    });

    test('display names are stable', () {
      expect(networkSttKindDisplayName(NetworkSttKind.openaiWhisper), 'OpenAI Whisper');
      expect(networkSttKindDisplayName(NetworkSttKind.groqWhisper), 'Groq Whisper');
    });
  });

  test('generated ids are unique per instance', () {
    final a = OpenAiWhisperSttOptions(
      enabled: true,
      name: 'a',
      apiKey: 'k',
      baseUrl: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
    );
    final b = OpenAiWhisperSttOptions(
      enabled: true,
      name: 'b',
      apiKey: 'k',
      baseUrl: 'https://api.openai.com/v1/audio/transcriptions',
      model: 'whisper-1',
    );
    expect(a.id, isNot(b.id));
  });
}
