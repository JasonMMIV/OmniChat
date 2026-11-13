import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/services/stt/cloud_stt_service.dart';
import 'package:OmniChat/core/services/stt/network_stt.dart';
import 'package:OmniChat/core/services/stt/pcm16_aligner.dart';

OpenAiWhisperSttOptions _openAi() => OpenAiWhisperSttOptions(
  enabled: true,
  name: 'OpenAI',
  apiKey: 'sk-1',
  baseUrl: kDefaultOpenAiSttEndpoint,
  model: 'whisper-1',
);

void main() {
  group('Pcm16Aligner', () {
    test('keeps a 1-byte carry across odd chunks', () {
      final aligner = Pcm16Aligner();
      expect(aligner.add(Uint8List.fromList([1])), isEmpty);
      expect(aligner.hasPendingByte, isTrue);
      // 1 carried + 2 new = 3 bytes → 2 usable, 1 carried again.
      expect(aligner.add(Uint8List.fromList([2, 3])), [1, 2]);
      expect(aligner.hasPendingByte, isTrue);
      expect(aligner.add(Uint8List(5)), [3, 0, 0, 0, 0, 0]);
      expect(aligner.hasPendingByte, isFalse);
      expect(aligner.takePendingByte(), isNull);
    });

    test('3-byte chunk yields 2 bytes and carries 1', () {
      final aligner = Pcm16Aligner();
      expect(aligner.add(Uint8List.fromList([1, 2, 3])), [1, 2]);
      expect(aligner.takePendingByte(), 3);
      expect(aligner.hasPendingByte, isFalse);
    });
  });

  group('BatchSttSession', () {
    test('flushes one segment per period and accumulates text', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          '{"text":"hello"}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final session = BatchSttSession(
        service: _openAi(),
        client: client,
        sampleRate: 1000,
        segmentDurationSec: 1,
      );
      await session.addPcm16(Uint8List(2000));
      await session.addPcm16(Uint8List(2000));
      final text = await session.finish();
      expect(requests, hasLength(2));
      expect(text, 'hello hello');
    });

    test('odd trailing byte is dropped, not zero padded', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"text":"ok"}', 200);
      });
      final session = BatchSttSession(
        service: _openAi(),
        client: client,
        sampleRate: 1000,
        segmentDurationSec: 1,
      );
      await session.addPcm16(Uint8List(2001));
      final text = await session.finish();
      expect(requests, hasLength(1));
      expect(text, 'ok');
    });

    test('finish is idempotent and returns the same future', () async {
      final client = MockClient(
        (request) async => http.Response('{"text":"x"}', 200),
      );
      final session = BatchSttSession(service: _openAi(), client: client);
      final first = session.finish();
      final second = session.finish();
      expect(identical(first, second), isTrue);
      expect(await first, '');
    });

    test('cancel returns empty text and sends nothing', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('{"text":"x"}', 200);
      });
      final session = BatchSttSession(
        service: _openAi(),
        client: client,
        sampleRate: 1000,
        segmentDurationSec: 1,
      );
      await session.addPcm16(Uint8List(2000));
      await session.cancel();
      expect(await session.finish(), '');
      expect(calls, 0);
    });

    test('late response after cancel is ignored', () async {
      final gate = Completer<void>();
      final client = MockClient((request) async {
        await gate.future;
        return http.Response('{"text":"late"}', 200);
      });
      final session = BatchSttSession(
        service: _openAi(),
        client: client,
        sampleRate: 1000,
        segmentDurationSec: 1,
      );
      final updates = <SttTranscriptUpdate>[];
      session.transcripts.listen(updates.add);
      await session.addPcm16(Uint8List(2000));
      await session.cancel();
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(updates, isEmpty);
    });

    test('HTTP errors surface on the errors stream without throwing', () async {
      final client = MockClient(
        (request) async => http.Response('nope', 401),
      );
      final session = BatchSttSession(
        service: _openAi(),
        client: client,
        sampleRate: 1000,
        segmentDurationSec: 1,
      );
      final errors = <SttTranscriptionException>[];
      session.errors.listen(errors.add);
      await session.addPcm16(Uint8List(2000));
      final text = await session.finish();
      await Future<void>.delayed(Duration.zero);
      expect(text, '');
      expect(errors, hasLength(1));
      expect(errors.single.statusCode, 401);
      expect(errors.single.message, contains('401'));
    });

    test('empty transcripts are not appended', () async {
      final client = MockClient(
        (request) async => http.Response('{"text":"   "}', 200),
      );
      final session = BatchSttSession(
        service: _openAi(),
        client: client,
        sampleRate: 1000,
        segmentDurationSec: 1,
      );
      await session.addPcm16(Uint8List(2000));
      expect(await session.finish(), '');
    });
  });
}
