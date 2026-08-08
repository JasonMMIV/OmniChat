import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/live/live_api_session.dart';

void main() {
  group('LiveApiSession.buildWebSocketUri', () {
    test('appends key query to official endpoint', () {
      final uri = LiveApiSession.buildWebSocketUri(
        baseUrl:
            'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
        apiKey: 'AIza-xyz',
      );
      expect(uri.scheme, 'wss');
      expect(uri.queryParameters['key'], 'AIza-xyz');
      expect(uri.path, contains('BidiGenerateContent'));
    });

    test('merges key into existing query parameters', () {
      final uri = LiveApiSession.buildWebSocketUri(
        baseUrl: 'wss://example.com/ws?foo=bar',
        apiKey: 'AIza-xyz',
      );
      expect(uri.queryParameters['foo'], 'bar');
      expect(uri.queryParameters['key'], 'AIza-xyz');
    });
  });

  group('LiveApiSession.buildSetupPayload', () {
    test('includes model, voice and audio formats', () {
      final payload = jsonDecode(
        LiveApiSession.buildSetupPayload(
          model: 'gemini-3.1-flash-live-preview',
          voice: 'Kore',
        ),
      ) as Map<String, dynamic>;
      final setup = payload['setup'] as Map<String, dynamic>;
      expect(setup['model'], 'models/gemini-3.1-flash-live-preview');
      final gen = setup['generationConfig'] as Map<String, dynamic>;
      expect(gen['responseModalities'], ['AUDIO', 'TEXT']);
      final speech = gen['speechConfig'] as Map<String, dynamic>;
      final voiceConfig =
          speech['voiceConfig'] as Map<String, dynamic>;
      expect(
        (voiceConfig['prebuiltVoiceConfig'] as Map<String, dynamic>)['voiceName'],
        'Kore',
      );
      expect(
        (gen['outputAudioFormat'] as Map<String, dynamic>)['pcmFormat'],
        {'sampleRate': 24000},
      );
      expect(
        (setup['audioInputConfig'] as Map<String, dynamic>)['pcmFormat'],
        {'sampleRate': 24000},
      );
    });

    test('does not duplicate models/ prefix', () {
      final payload = jsonDecode(
        LiveApiSession.buildSetupPayload(
          model: 'models/gemini-2.0-flash-live-preview',
          voice: 'Puck',
        ),
      ) as Map<String, dynamic>;
      expect(
        (payload['setup'] as Map<String, dynamic>)['model'],
        'models/gemini-2.0-flash-live-preview',
      );
    });
  });

  group('LiveApiSession.buildRealtimeInputPayload', () {
    test('encodes pcm chunk as base64 with pcm mime type', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final payload = jsonDecode(
        LiveApiSession.buildRealtimeInputPayload(bytes),
      ) as Map<String, dynamic>;
      final ri = payload['realtimeInput'] as Map<String, dynamic>;
      final chunk = (ri['mediaChunks'] as List).first as Map<String, dynamic>;
      expect(chunk['mimeType'], 'audio/pcm;rate=24000');
      expect(base64Decode(chunk['data'] as String), [1, 2, 3, 4]);
    });
  });

  group('LiveApiSession message parsing', () {
    test('setupComplete detection', () {
      expect(
        LiveApiSession.isSetupComplete(const {'setupComplete': {}}),
        isTrue,
      );
      expect(
        LiveApiSession.isSetupComplete(const {'serverContent': {}}),
        isFalse,
      );
    });

    test('goAway and error detection', () {
      expect(LiveApiSession.isGoAway(const {'goAway': {}}), isTrue);
      expect(
        LiveApiSession.isServerError(const {'error': {'status': 'ERROR'}}),
        isTrue,
      );
    });

    test('extractText concatenates modelTurn text parts', () {
      const msg = {
        'serverContent': {
          'modelTurn': {
            'parts': [
              {'text': 'Hello'},
              {'text': ' world'},
              {'inlineData': {'data': 'AQID'}},
            ],
          },
        },
      };
      expect(LiveApiSession.extractText(msg), 'Hello world');
    });

    test('extractAudio decodes inlineData parts and skips invalid', () {
      const msg = {
        'serverContent': {
          'modelTurn': {
            'parts': [
              {'text': 'x'},
              {'inlineData': {'data': 'AQID'}},
              {'inlineData': {'data': 'BAUG'}},
              {'inlineData': {'data': '!!!not-base64!!!'}},
            ],
          },
        },
      };
      final audio = LiveApiSession.extractAudio(msg);
      expect(audio, hasLength(2));
      expect(audio[0], [1, 2, 3]);
      expect(audio[1], [4, 5, 6]);
    });

    test('interrupted and turnComplete detection', () {
      expect(
        LiveApiSession.isInterrupted(const {'serverContent': {'interrupted': true}}),
        isTrue,
      );
      expect(
        LiveApiSession.isTurnComplete(const {'serverContent': {'turnComplete': true}}),
        isTrue,
      );
      expect(
        LiveApiSession.isInterrupted(const {'serverContent': {'interrupted': false}}),
        isFalse,
      );
    });

    test('extractErrorMessage formats status and message', () {
      const msg = {'error': {'status': 'FAILED_PRECONDITION', 'message': 'bad key'}};
      expect(
        LiveApiSession.extractErrorMessage(msg),
        'FAILED_PRECONDITION: bad key',
      );
      expect(LiveApiSession.extractErrorMessage(const {'error': 42}), '');
    });
  });

  group('LiveApiSession.pcm16ToWav', () {
    test('produces a valid 44-byte header WAV', () {
      final pcm = Uint8List.fromList(List.generate(4800, (i) => i % 256));
      final wav = LiveApiSession.pcm16ToWav(pcm);
      expect(wav.length, 44 + pcm.length);
      expect(utf8.decode(wav.sublist(0, 4)), 'RIFF');
      expect(utf8.decode(wav.sublist(8, 12)), 'WAVE');
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint16(20, Endian.little), 1); // PCM
      expect(bd.getUint16(22, Endian.little), 1); // mono
      expect(bd.getUint32(24, Endian.little), 24000); // sample rate
      expect(bd.getUint16(34, Endian.little), 16); // bits per sample
      expect(bd.getUint32(40, Endian.little), pcm.length); // data size
      // payload preserved
      for (var i = 0; i < pcm.length; i++) {
        expect(wav[44 + i], pcm[i]);
      }
    });
  });
}
