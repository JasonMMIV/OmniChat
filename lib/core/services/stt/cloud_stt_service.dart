import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../audio/wav_codec.dart';
import 'network_stt.dart';
import 'pcm16_aligner.dart';
import 'stt_request.dart';
import 'transcript_join.dart';

/// 一次轉錄進度更新。批次模式沒有 partial，`partialText` 固定為空。
class SttTranscriptUpdate {
  const SttTranscriptUpdate({required this.finalText, this.partialText = ''});

  final String finalText;
  final String partialText;
}

class SttTranscriptionException implements Exception {
  const SttTranscriptionException({
    required this.provider,
    required this.message,
    this.statusCode,
  });

  final String provider;
  final int? statusCode;
  final String message;

  @override
  String toString() => message;
}

/// 語音辨識 session。`transcripts` 只送累積文字，呼叫端以「取代」顯示。
abstract interface class SttSession {
  Stream<SttTranscriptUpdate> get transcripts;

  /// 非致命錯誤（單段失敗仍可繼續）；UI 顯示後不應清空既有文字。
  Stream<SttTranscriptionException> get errors;

  Future<void> addPcm16(Uint8List chunk);

  /// 冪等；重複呼叫回傳同一個 future。
  Future<String> finish();

  /// 冪等；丟棄未完成結果。
  Future<void> cancel();
}

enum _BatchPhase { idle, recording, flushing, finishing, done, cancelled }

/// 分段批次轉錄（OpenAI／Groq／Mistral／ElevenLabs／Qwen 錄音檔）。
///
/// 狀態機：`idle → recording ⇄ flushing → finishing → done/cancelled`。
/// `flushing` 仍接受 PCM（進下一個 buffer），只有 `finishing`／`done`／
/// `cancelled` 停止收音；上傳佇列一次只送一段，確保文字順序。
class BatchSttSession implements SttSession {
  BatchSttSession({
    required SttServiceOptions service,
    http.Client? client,
    int? sampleRate,
    int? segmentDurationSec,
    Duration requestTimeout = const Duration(seconds: 60),
    Duration finishTimeout = const Duration(seconds: 90),
  }) : _service = service,
       _client = client ?? http.Client(),
       _sampleRate = sampleRate ?? service.sampleRate,
       _segmentBytes =
           (sampleRate ?? service.sampleRate) *
           2 *
           (segmentDurationSec ?? service.segmentDurationSec),
       _requestTimeout = requestTimeout,
       _finishTimeout = finishTimeout;

  final SttServiceOptions _service;
  final http.Client _client;
  final int _sampleRate;
  final int _segmentBytes;
  final Duration _requestTimeout;
  final Duration _finishTimeout;

  final StreamController<SttTranscriptUpdate> _transcripts =
      StreamController<SttTranscriptUpdate>.broadcast();
  final StreamController<SttTranscriptionException> _errors =
      StreamController<SttTranscriptionException>.broadcast();

  final Pcm16Aligner _aligner = Pcm16Aligner();
  final List<Uint8List> _chunks = <Uint8List>[];
  int _bufferedBytes = 0;

  _BatchPhase _phase = _BatchPhase.idle;
  String _text = '';
  int _pendingUploads = 0;
  bool _cancelled = false;
  Future<void> _uploadChain = Future<void>.value();
  Future<String>? _finishFuture;

  @override
  Stream<SttTranscriptUpdate> get transcripts => _transcripts.stream;

  @override
  Stream<SttTranscriptionException> get errors => _errors.stream;

  String get text => _text;

  @override
  Future<void> addPcm16(Uint8List chunk) async {
    if (_cancelled ||
        _phase == _BatchPhase.finishing ||
        _phase == _BatchPhase.done) {
      return;
    }
    if (chunk.isEmpty) return;
    if (_phase == _BatchPhase.idle) _phase = _BatchPhase.recording;
    // record 的 chunk 可能切在半個 sample；carry 由 aligner 保留。
    final aligned = _aligner.add(chunk);
    if (aligned.isEmpty) return;
    _append(aligned);
    // `_segmentBytes > 0` 防呆：0 會在 while 迴圈中永遠不減少而卡死。
    while (_segmentBytes > 0 && _bufferedBytes >= _segmentBytes) {
      _enqueueSegment(_take(_segmentBytes));
    }
  }

  @override
  Future<String> finish() {
    final inFlight = _finishFuture;
    if (inFlight != null) return inFlight;
    final future = _finishInternal();
    _finishFuture = future;
    return future;
  }

  Future<String> _finishInternal() async {
    if (_phase == _BatchPhase.cancelled) return '';
    _phase = _BatchPhase.finishing;
    // 單一 byte 不是完整 sample；補零會產生 click，直接丟棄。
    _aligner.takePendingByte();
    final remainder = _take(_bufferedBytes);
    if (remainder.isNotEmpty) _enqueueSegment(remainder);
    try {
      await _uploadChain.timeout(_finishTimeout);
    } on TimeoutException {
      _reportError(
        SttTranscriptionException(
          provider: networkSttKindDisplayName(_service.kind),
          message: 'Finishing transcription timed out.',
        ),
      );
    }
    if (_cancelled) return '';
    _phase = _BatchPhase.done;
    if (!_transcripts.isClosed) {
      _transcripts.add(SttTranscriptUpdate(finalText: _text));
      await _transcripts.close();
    }
    if (!_errors.isClosed) await _errors.close();
    return _text;
  }

  @override
  Future<void> cancel() async {
    if (_phase == _BatchPhase.cancelled || _phase == _BatchPhase.done) return;
    _cancelled = true;
    _phase = _BatchPhase.cancelled;
    _chunks.clear();
    _bufferedBytes = 0;
    try {
      _client.close();
    } catch (_) {}
    if (!_transcripts.isClosed) await _transcripts.close();
    if (!_errors.isClosed) await _errors.close();
  }

  void _append(Uint8List data) {
    if (data.isEmpty) return;
    _chunks.add(data);
    _bufferedBytes += data.length;
  }

  Uint8List _take(int count) {
    final length = count > _bufferedBytes ? _bufferedBytes : count;
    final out = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      final head = _chunks.first;
      final need = length - filled;
      if (head.length <= need) {
        out.setRange(filled, filled + head.length, head);
        filled += head.length;
        _chunks.removeAt(0);
      } else {
        out.setRange(filled, filled + need, head);
        _chunks[0] = Uint8List.sublistView(head, need);
        filled += need;
      }
    }
    _bufferedBytes -= length;
    return out;
  }

  void _enqueueSegment(Uint8List pcm) {
    if (pcm.isEmpty) return;
    final padded = _padToMinimum(pcm);
    final wav = pcm16MonoToWav(padded, sampleRate: _sampleRate);
    if (_phase == _BatchPhase.recording) _phase = _BatchPhase.flushing;
    _pendingUploads++;
    _uploadChain = _uploadChain.then((_) => _sendSegment(wav));
  }

  /// Groq 最短 10 ms、ElevenLabs 最短 100 ms；太短的尾巴補零，否則 API 會拒絕。
  Uint8List _padToMinimum(Uint8List pcm) {
    final minMs = switch (_service.kind) {
      NetworkSttKind.groqWhisper => 10,
      NetworkSttKind.elevenLabs => 100,
      _ => 0,
    };
    if (minMs <= 0) return pcm;
    var minBytes = (_sampleRate * 2 * minMs / 1000).ceil();
    // WAV data 必須是 2-byte 對齊（極端 sampleRate 下 ceil 可能是奇數）。
    if (minBytes.isOdd) minBytes += 1;
    if (pcm.length >= minBytes) return pcm;
    final padded = Uint8List(minBytes);
    padded.setRange(0, pcm.length, pcm);
    return padded;
  }

  Future<void> _sendSegment(Uint8List wav) async {
    final provider = networkSttKindDisplayName(_service.kind);
    try {
      if (_cancelled) return;
      final request = buildSttTranscriptionRequest(
        service: _service,
        wav: wav,
        sampleRate: _sampleRate,
      );
      final streamed = await _client.send(request).timeout(_requestTimeout);
      final body = await streamed.stream.bytesToString();
      if (_cancelled) return;
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw SttTranscriptionException(
          provider: provider,
          statusCode: streamed.statusCode,
          message: '$provider returned HTTP ${streamed.statusCode}: '
              '${_truncate(body)}',
        );
      }
      final text = parseSttTranscriptionBody(_service.kind, body);
      if (text.isEmpty) return;
      _text = _text.isEmpty ? text : joinTranscript(_text, text);
      if (!_transcripts.isClosed) {
        _transcripts.add(SttTranscriptUpdate(finalText: _text));
      }
    } on SttTranscriptionException catch (e) {
      _reportError(e);
    } on TimeoutException {
      _reportError(
        SttTranscriptionException(
          provider: provider,
          message: '$provider request timed out.',
        ),
      );
    } catch (e) {
      _reportError(
        SttTranscriptionException(
          provider: provider,
          message: '$provider request failed: ${_truncate('$e')}',
        ),
      );
    } finally {
      _pendingUploads--;
      if (_phase == _BatchPhase.flushing && _pendingUploads <= 0) {
        _phase = _BatchPhase.recording;
      }
    }
  }

  void _reportError(SttTranscriptionException error) {
    if (_cancelled || _errors.isClosed) return;
    _errors.add(error);
  }

  String _truncate(String value) {
    final oneLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 300 ? oneLine : '${oneLine.substring(0, 300)}…';
  }
}
