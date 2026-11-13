import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/services/stt/cloud_stt_service.dart';
import 'package:OmniChat/core/services/stt/network_dictation_session.dart';
import 'package:OmniChat/core/services/stt/network_stt.dart';
import 'package:OmniChat/core/services/stt/stt_audio_capture.dart';

class _FakeCapture implements SttAudioCapture {
  _FakeCapture({this.permitted = true});

  final bool permitted;
  final StreamController<Uint8List> audio =
      StreamController<Uint8List>.broadcast();
  bool started = false;
  bool stopped = false;
  bool cancelled = false;
  bool disposed = false;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async {
    started = true;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeSession implements SttSession {
  final StreamController<SttTranscriptUpdate> transcriptCtrl =
      StreamController<SttTranscriptUpdate>.broadcast();
  final StreamController<SttTranscriptionException> errorCtrl =
      StreamController<SttTranscriptionException>.broadcast();
  final List<Uint8List> chunks = <Uint8List>[];
  bool finished = false;
  bool cancelled = false;

  @override
  Stream<SttTranscriptUpdate> get transcripts => transcriptCtrl.stream;

  @override
  Stream<SttTranscriptionException> get errors => errorCtrl.stream;

  @override
  Future<void> addPcm16(Uint8List chunk) async => chunks.add(chunk);

  @override
  Future<String> finish() async {
    finished = true;
    return 'done';
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

OpenAiWhisperSttOptions _service() => OpenAiWhisperSttOptions(
  enabled: true,
  name: 'OpenAI',
  apiKey: 'k',
  baseUrl: kDefaultOpenAiSttEndpoint,
  model: 'whisper-1',
);

void main() {
  test('forwards captured PCM into the STT session', () async {
    final capture = _FakeCapture();
    final session = _FakeSession();
    final dictation = NetworkDictationSession(
      service: _service(),
      capture: capture,
      client: MockClient((request) async => http.Response('{}', 200)),
      sessionFactory: (_, __) => session,
    );

    final updates = <NetworkDictationUpdate>[];
    dictation.updates.listen(updates.add);

    await dictation.start();
    expect(capture.started, isTrue);
    capture.audio.add(Uint8List.fromList([1, 2]));
    await Future<void>.delayed(Duration.zero);
    expect(session.chunks.single, [1, 2]);

    session.transcriptCtrl.add(
      const SttTranscriptUpdate(finalText: 'hello'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(updates.last.finalText, 'hello');
    expect(updates.last.isTranscribing, isTrue);

    final text = await dictation.finish();
    expect(text, 'done');
    expect(session.finished, isTrue);
    expect(capture.stopped, isTrue);
  });

  test('permission denial throws a typed exception', () async {
    final dictation = NetworkDictationSession(
      service: _service(),
      capture: _FakeCapture(permitted: false),
      client: MockClient((request) async => http.Response('{}', 200)),
      sessionFactory: (_, __) => _FakeSession(),
    );
    expect(
      () => dictation.start(),
      throwsA(isA<SttMicrophonePermissionException>()),
    );
  });

  test('cancel stops the capture and the session', () async {
    final capture = _FakeCapture();
    final session = _FakeSession();
    final dictation = NetworkDictationSession(
      service: _service(),
      capture: capture,
      client: MockClient((request) async => http.Response('{}', 200)),
      sessionFactory: (_, __) => session,
    );
    await dictation.start();
    await dictation.cancel();
    expect(capture.cancelled, isTrue);
    expect(session.cancelled, isTrue);
    expect(await dictation.finish(), '');
  });

  group('composeNetworkDictationText', () {
    test('composes base + final without duplicating', () {
      expect(
        composeNetworkDictationText(
          base: 'Hi',
          finalText: 'hello',
          partialText: '',
        ),
        'Hi hello',
      );
      expect(
        composeNetworkDictationText(
          base: '你好',
          finalText: '世界',
          partialText: '',
        ),
        '你好世界',
      );
    });

    test('partial is appended on top of final (Phase 4 shape)', () {
      expect(
        composeNetworkDictationText(
          base: '',
          finalText: 'hello',
          partialText: 'world',
        ),
        'hello world',
      );
    });

    test('empty base returns final text', () {
      expect(
        composeNetworkDictationText(
          base: '',
          finalText: 'hello',
          partialText: '',
        ),
        'hello',
      );
    });
  });
}
