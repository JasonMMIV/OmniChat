import 'dart:typed_data';

import 'package:record/record.dart';

/// 聽寫用 PCM16 麥克風擷取（docs/speech_recognition_import_plan.md §4.3）。
abstract interface class SttAudioCapture {
  Future<bool> hasPermission();

  Future<Stream<Uint8List>> start({required int sampleRate});

  Future<void> stop();

  Future<void> cancel();

  Future<void> dispose();
}

/// 以 `record` 套件實作的擷取層。
///
/// 只收音、不播放，因此不需要 audio focus：
/// `audioInterruption: none` 讓 Android 的 AudioSessionManager 不會在
/// focus loss 時以預設 `PAUSE` 永久暫停麥克風（手冊 §5.2.1）。
class RecordSttAudioCapture implements SttAudioCapture {
  RecordSttAudioCapture({AudioRecorder Function()? recorderFactory})
    : _recorderFactory = recorderFactory ?? (() => AudioRecorder());

  final AudioRecorder Function() _recorderFactory;
  AudioRecorder? _recorder;
  bool _disposed = false;

  AudioRecorder _ensureRecorder() => _recorder ??= _recorderFactory();

  @override
  Future<bool> hasPermission() async {
    if (_disposed) return false;
    try {
      // 與 start() 共用同一個 recorder 實例，避免每次檢查都建立一個
      // platform 物件（建構子即 fire-and-forget 呼叫原生 create）。
      return await _ensureRecorder().hasPermission();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async {
    if (_disposed) throw StateError('SttAudioCapture has been disposed');
    final recorder = _ensureRecorder();
    try {
      await recorder.stop();
    } catch (_) {
      // 尚未開始錄音時 stop() 可能拋錯；不影響後續 startStream。
    }
    return recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        audioInterruption: AudioInterruptionMode.none,
      ),
    );
  }

  @override
  Future<void> stop() async {
    try {
      await _recorder?.stop();
    } catch (_) {
      // 停止失敗不阻斷流程；下一次 start() 會重建 recorder。
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _recorder?.cancel();
    } catch (_) {}
    await stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
  }
}
