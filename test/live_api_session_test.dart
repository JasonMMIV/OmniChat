import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/live/live_api_session.dart';

void main() {
  group('LiveApiSession 音訊常數（P0 輸入/輸出取樣率分離）', () {
    test('mic input is 16kHz and output is 24kHz, never shared', () {
      expect(LiveApiSession.micSampleRate, 16000);
      expect(LiveApiSession.outputSampleRate, 24000);
      expect(
        LiveApiSession.micSampleRate,
        isNot(LiveApiSession.outputSampleRate),
      );
    });

    test('realtimeInput mime rate matches micSampleRate', () {
      final payload = jsonDecode(
        LiveApiSession.buildRealtimeInputPayload(Uint8List.fromList([1, 2])),
      ) as Map<String, dynamic>;
      final audio =
          (payload['realtimeInput'] as Map<String, dynamic>)['audio']
              as Map<String, dynamic>;
      expect(
        audio['mimeType'],
        'audio/pcm;rate=${LiveApiSession.micSampleRate}',
      );
    });

    test('pcm16ToWav default header uses outputSampleRate (24kHz)', () {
      final pcm = Uint8List.fromList(List.generate(8, (i) => i));
      final wav = LiveApiSession.pcm16ToWav(pcm);
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(24, Endian.little), LiveApiSession.outputSampleRate);
    });
  });

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
    test('includes model, voice and modalities (snake_case per proto)', () {
      final payload = jsonDecode(
        LiveApiSession.buildSetupPayload(
          model: 'gemini-3.1-flash-live-preview',
          voice: 'Kore',
        ),
      ) as Map<String, dynamic>;
      final setup = payload['setup'] as Map<String, dynamic>;
      expect(setup['model'], 'models/gemini-3.1-flash-live-preview');
      final gen = setup['generation_config'] as Map<String, dynamic>;
      expect(gen['response_modalities'], ['AUDIO']);
      final speech = gen['speech_config'] as Map<String, dynamic>;
      final voiceConfig =
          speech['voice_config'] as Map<String, dynamic>;
      expect(
        (voiceConfig['prebuilt_voice_config'] as Map<String, dynamic>)['voice_name'],
        'Kore',
      );
      // v1beta BidiGenerateContentSetup 無 output_audio_format/audio_input_config
      expect(gen.containsKey('output_audio_format'), isFalse);
      expect(setup.containsKey('audio_input_config'), isFalse);
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
      final audio = ri['audio'] as Map<String, dynamic>;
      expect(audio['mimeType'], 'audio/pcm;rate=16000');
      expect(base64Decode(audio['data'] as String), [1, 2, 3, 4]);
      expect(ri.containsKey('mediaChunks'), isFalse);
    });
  });

  group('LiveApiSession.buildAudioStreamEndPayload', () {
    test('emits realtimeInput.audio_stream_end empty message', () {
      final payload = jsonDecode(
        LiveApiSession.buildAudioStreamEndPayload(),
      ) as Map<String, dynamic>;
      final ri = payload['realtimeInput'] as Map<String, dynamic>;
      expect(ri['audio_stream_end'], <String, dynamic>{});
      expect(ri.containsKey('audio'), isFalse);
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
