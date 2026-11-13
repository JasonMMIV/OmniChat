import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:OmniChat/core/services/stt/network_stt.dart';
import 'package:OmniChat/core/services/stt/stt_request.dart';

http.MultipartRequest _multipart(SttServiceOptions service) {
  final request = buildSttTranscriptionRequest(
    service: service,
    wav: Uint8List.fromList([1, 2, 3, 4]),
    sampleRate: 16000,
  );
  expect(request, isA<http.MultipartRequest>());
  return request as http.MultipartRequest;
}

void main() {
  test('OpenAI sends bearer auth, model, language and WAV file', () {
    final request = _multipart(
      OpenAiWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'sk-1',
        baseUrl: kDefaultOpenAiSttEndpoint,
        model: 'whisper-1',
        language: 'zh',
      ),
    );
    expect(request.url.toString(), kDefaultOpenAiSttEndpoint);
    expect(request.headers['Authorization'], 'Bearer sk-1');
    expect(request.fields['model'], 'whisper-1');
    expect(request.fields['language'], 'zh');
    final file = request.files.single;
    expect(file.field, 'file');
    expect(file.filename, 'audio.wav');
    expect(file.contentType.toString(), 'audio/wav');
  });

  test('Groq adds response_format=json', () {
    final request = _multipart(
      GroqWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'gsk',
        baseUrl: kDefaultGroqSttEndpoint,
        model: 'whisper-large-v3',
      ),
    );
    expect(request.headers['Authorization'], 'Bearer gsk');
    expect(request.fields['response_format'], 'json');
    expect(request.fields.containsKey('language'), isFalse);
  });

  test('Mistral uses its default model and endpoint', () {
    final request = _multipart(
      MistralSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'mk',
        baseUrl: kDefaultMistralSttEndpoint,
        model: kDefaultMistralSttModel,
      ),
    );
    expect(request.url.toString(), kDefaultMistralSttEndpoint);
    expect(request.fields['model'], 'voxtral-mini-latest');
  });

  test('ElevenLabs uses xi-api-key and model_id (no model/language fields)', () {
    final request = _multipart(
      ElevenLabsSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'xi',
        baseUrl: kDefaultElevenLabsSttEndpoint,
        model: 'scribe_v2',
        language: 'en',
      ),
    );
    expect(request.headers['xi-api-key'], 'xi');
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(request.fields['model_id'], 'scribe_v2');
    expect(request.fields['tag_audio_events'], 'false');
    expect(request.fields['timestamps_granularity'], 'none');
    expect(request.fields['language_code'], 'en');
    expect(request.fields.containsKey('model'), isFalse);
    expect(request.fields.containsKey('language'), isFalse);
  });

  test('language auto is omitted', () {
    final request = _multipart(
      OpenAiWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'k',
        baseUrl: kDefaultOpenAiSttEndpoint,
        model: 'whisper-1',
        language: 'auto',
      ),
    );
    expect(request.fields.containsKey('language'), isFalse);
  });

  test('full endpoint is not duplicated', () {
    final request = _multipart(
      OpenAiWhisperSttOptions(
        enabled: true,
        name: 'n',
        apiKey: 'k',
        baseUrl: 'https://api.openai.com/v1/audio/transcriptions',
        model: 'whisper-1',
      ),
    );
    expect(
      request.url.toString(),
      'https://api.openai.com/v1/audio/transcriptions',
    );
  });

  test('parseSttTranscriptionBody handles text, plain text and Qwen output', () {
    expect(
      parseSttTranscriptionBody(NetworkSttKind.openaiWhisper, '{"text":"hi"}'),
      'hi',
    );
    expect(
      parseSttTranscriptionBody(
        NetworkSttKind.qwenAudio,
        '{"output":{"text":"你好"}}',
      ),
      '你好',
    );
    // 部分 DashScope 模型回傳 choices[0].message.content。
    expect(
      parseSttTranscriptionBody(
        NetworkSttKind.qwenAudio,
        '{"output":{"choices":[{"message":{"content":[{"text":"嗨"}]}}]}}',
      ),
      '嗨',
    );
    expect(
      parseSttTranscriptionBody(NetworkSttKind.openaiWhisper, ' plain '),
      'plain',
    );
    expect(
      parseSttTranscriptionBody(NetworkSttKind.openaiWhisper, '{"text":""}'),
      '',
    );
  });
}
