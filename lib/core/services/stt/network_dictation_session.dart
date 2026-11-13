import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_stt_service.dart';
import 'network_stt.dart';
import 'stt_audio_capture.dart';
import 'transcript_join.dart';

/// 聽寫 update：`finalText` 是已定稿累積文字，`partialText` 僅即時模式使用。
class NetworkDictationUpdate {
  const NetworkDictationUpdate({
    this.finalText = '',
    this.partialText = '',
    this.isTranscribing = false,
    this.error,
  });

  final String finalText;
  final String partialText;
  final bool isTranscribing;
  final Object? error;
}

class SttMicrophonePermissionException implements Exception {
  const SttMicrophonePermissionException();

  @override
  String toString() => 'Microphone permission was not granted.';
}

/// 顯示文字一律由 `base + final + partial` 重算，不可在目前文字上 append。
String composeNetworkDictationText({
  required String base,
  required String finalText,
  required String partialText,
}) {
  var out = base;
  if (finalText.isNotEmpty) out = joinTranscript(out, finalText);
  if (partialText.isNotEmpty) out = joinTranscript(out, partialText);
  return out;
}

/// 網路聽寫 session（plain class）：擷取 PCM → 批次轉錄 → 文字 update。
///
/// 不持有 `TextEditingController`；狀態與輸入框由 `HomePageController` 擁有。
class NetworkDictationSession {
  NetworkDictationSession({
    required this.service,
    SttAudioCapture? capture,
    http.Client? client,
    SttSession Function(SttServiceOptions service, http.Client client)?
    sessionFactory,
  }) : _capture = capture ?? RecordSttAudioCapture(),
       _client = client ?? http.Client(),
       _sessionFactory =
           sessionFactory ??
           ((service, client) => BatchSttSession(service: service, client: client));

  final SttServiceOptions service;
  final SttAudioCapture _capture;
  final http.Client _client;
  final SttSession Function(SttServiceOptions, http.Client) _sessionFactory;

  final StreamController<NetworkDictationUpdate> _updates =
      StreamController<NetworkDictationUpdate>.broadcast();

  SttSession? _session;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<SttTranscriptUpdate>? _transcriptSub;
  StreamSubscription<SttTranscriptionException>? _errorSub;
  String _finalText = '';
  bool _started = false;
  bool _closed = false;

  Stream<NetworkDictationUpdate> get updates => _updates.stream;

  String get finalText => _finalText;

  bool get isStarted => _started;

  Future<void> start() async {
    if (_started || _closed) return;
    if (!await _capture.hasPermission()) {
      throw const SttMicrophonePermissionException();
    }
    if (_closed) return;
    final session = _sessionFactory(service, _client);
    _session = session;
    _transcriptSub = session.transcripts.listen((update) {
      _finalText = update.finalText;
      _emit(
        finalText: update.finalText,
        partialText: update.partialText,
        isTranscribing: true,
      );
    });
    _errorSub = session.errors.listen((error) => _emit(error: error));
    final stream = await _capture.start(sampleRate: service.sampleRate);
    _audioSub = stream.listen((chunk) {
      // addPcm16 的錯誤由 session 內部轉成 errors stream；此處吞掉避免
      // 未處理的 async error 中斷擷取。
      unawaited(session.addPcm16(chunk).catchError((Object _) {}));
    });
    _started = true;
    _emit(isTranscribing: true);
  }

  Future<String> finish() async {
    if (_closed) return _finalText;
    _started = false;
    await _audioSub?.cancel();
    _audioSub = null;
    // 擷取層停止失敗不可阻斷最後一段：內部已吞錯，這裡再擋一層。
    try {
      await _capture.stop();
    } catch (_) {}
    final session = _session;
    final text = session == null ? _finalText : await session.finish();
    _finalText = text;
    _emit(finalText: text, isTranscribing: false);
    await _close();
    return text;
  }

  Future<void> cancel() async {
    if (_closed) return;
    _started = false;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _capture.cancel();
    } catch (_) {}
    try {
      await _session?.cancel();
    } catch (_) {}
    await _close();
  }

  Future<void> dispose() async {
    await cancel();
    await _capture.dispose();
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _transcriptSub?.cancel();
    await _errorSub?.cancel();
    _transcriptSub = null;
    _errorSub = null;
    if (!_updates.isClosed) await _updates.close();
    try {
      _client.close();
    } catch (_) {}
  }

  void _emit({
    String finalText = '',
    String partialText = '',
    bool isTranscribing = false,
    Object? error,
  }) {
    if (_updates.isClosed) return;
    _updates.add(
      NetworkDictationUpdate(
        finalText: finalText,
        partialText: partialText,
        isTranscribing: isTranscribing,
        error: error,
      ),
    );
  }
}
