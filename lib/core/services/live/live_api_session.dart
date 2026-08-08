import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Live API 通話狀態。
enum LiveCallState { idle, connecting, active, error, ended }

/// Gemini Live API 雙向語音通話引擎。
///
/// 以 WebSocket（BidiGenerateContent）建立 session：麥克風 PCM16 24kHz
/// 串流 → `realtimeInput` 送給伺服器；伺服器 `serverContent` 的 AUDIO parts
/// 依序播放（WAV 檔暫存）、TEXT parts 累積為字幕。
class LiveApiSession extends ChangeNotifier {
  LiveApiSession({
    required this.apiKey,
    required this.model,
    required this.voice,
    required this.baseUrl,
    WebSocketChannel Function(Uri uri)? channelFactory,
    AudioRecorder Function()? recorderFactory,
  })  : _channelFactory =
            channelFactory ?? ((uri) => IOWebSocketChannel.connect(uri)),
        _recorderFactory = recorderFactory ?? (() => AudioRecorder());

  final String apiKey;
  final String model;
  final String voice;
  final String baseUrl;
  final WebSocketChannel Function(Uri uri) _channelFactory;
  final AudioRecorder Function() _recorderFactory;

  static const int sampleRate = 24000;
  static const int _micChunkBytes = 4800; // 100ms @ 24kHz mono 16-bit

  LiveCallState _state = LiveCallState.idle;
  LiveCallState get state => _state;

  String _errorMessage = '';
  String get errorMessage => _errorMessage;

  bool _muted = false;
  bool get muted => _muted;

  /// 目前未完成的助理句子（串流中）。
  String _assistantPartial = '';
  String get assistantPartial => _assistantPartial;

  /// 已完成的助理句子（`turnComplete` 後提交）。
  final List<String> _turns = <String>[];
  List<String> get turns => List.unmodifiable(_turns);

  WebSocketChannel? _ws;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  final BytesBuilder _micBuf = BytesBuilder(copy: false);

  final Queue<Uint8List> _playQueue = Queue<Uint8List>();
  AudioPlayer? _player;
  bool _playing = false;
  final BytesBuilder _playBuf = BytesBuilder(copy: false);
  int _audioSeq = 0;
  Directory? _tempDir;
  File? _currentPlaybackFile;

  bool _disposed = false;
  bool _closing = false;

  /// 建立 WebSocket URI（baseUrl + key query）。
  static Uri buildWebSocketUri({
    required String baseUrl,
    required String apiKey,
  }) {
    final uri = Uri.parse(baseUrl);
    final query = Map<String, String>.from(uri.queryParameters);
    query['key'] = apiKey;
    return uri.replace(queryParameters: query);
  }

  /// 建立 setup 訊息（JSON 字串）。
  static String buildSetupPayload({
    required String model,
    required String voice,
    int sampleRate = 24000,
  }) {
    final payload = <String, dynamic>{
      'setup': <String, dynamic>{
        'model': model.startsWith('models/') ? model : 'models/$model',
        'generationConfig': <String, dynamic>{
          'responseModalities': <String>['AUDIO', 'TEXT'],
          'speechConfig': <String, dynamic>{
            'voiceConfig': <String, dynamic>{
              'prebuiltVoiceConfig': <String, dynamic>{'voiceName': voice},
            },
          },
          'outputAudioFormat': <String, dynamic>{
            'pcmFormat': <String, dynamic>{'sampleRate': sampleRate},
          },
        },
        'audioInputConfig': <String, dynamic>{
          'pcmFormat': <String, dynamic>{'sampleRate': sampleRate},
        },
      },
    };
    return jsonEncode(payload);
  }

  /// 建立 realtimeInput 訊息（JSON 字串）。
  static String buildRealtimeInputPayload(Uint8List pcm) {
    return jsonEncode(<String, dynamic>{
      'realtimeInput': <String, dynamic>{
        'mediaChunks': <Map<String, String>>[
          <String, String>{
            'mimeType': 'audio/pcm;rate=$sampleRate',
            'data': base64Encode(pcm),
          },
        ],
      },
    });
  }

  // ---- 伺服器訊息解析（純函式，供測試）----

  static bool isSetupComplete(Map<String, dynamic> msg) =>
      msg['setupComplete'] != null;

  static bool isGoAway(Map<String, dynamic> msg) => msg['goAway'] != null;

  static bool isServerError(Map<String, dynamic> msg) =>
      msg['error'] is Map<String, dynamic>;

  static Map<String, dynamic>? serverContent(Map<String, dynamic> msg) {
    final c = msg['serverContent'];
    return c is Map<String, dynamic> ? c : null;
  }

  static bool isInterrupted(Map<String, dynamic> msg) =>
      serverContent(msg)?['interrupted'] == true;

  static bool isTurnComplete(Map<String, dynamic> msg) =>
      serverContent(msg)?['turnComplete'] == true;

  /// 取出 serverContent.modelTurn.parts 中的文字。
  static String extractText(Map<String, dynamic> msg) {
    final content = serverContent(msg);
    if (content == null) return '';
    final turn = content['modelTurn'];
    if (turn is! Map) return '';
    final parts = turn['parts'];
    if (parts is! List) return '';
    final buf = StringBuffer();
    for (final p in parts) {
      if (p is Map && p['text'] is String) {
        buf.write(p['text']);
      }
    }
    return buf.toString();
  }

  /// 取出 serverContent.modelTurn.parts 中的音訊（base64 → PCM bytes）。
  static List<Uint8List> extractAudio(Map<String, dynamic> msg) {
    final content = serverContent(msg);
    if (content == null) return const <Uint8List>[];
    final turn = content['modelTurn'];
    if (turn is! Map) return const <Uint8List>[];
    final parts = turn['parts'];
    if (parts is! List) return const <Uint8List>[];
    final result = <Uint8List>[];
    for (final p in parts) {
      if (p is Map && p['inlineData'] is Map<String, dynamic>) {
        final data = (p['inlineData'] as Map<String, dynamic>)['data'];
        if (data is String && data.isNotEmpty) {
          try {
            result.add(base64Decode(data));
          } catch (_) {}
        }
      }
    }
    return result;
  }

  /// 提取 server error 訊息文字。
  static String extractErrorMessage(Map<String, dynamic> msg) {
    final e = msg['error'];
    if (e is! Map) return '';
    final status = e['status'];
    final message = e['message'];
    if (status is String && message is String) return '$status: $message';
    if (message is String) return message;
    return status is String ? status : '';
  }

  // ---- WAV 封裝 ----

  /// 將 PCM16 封裝為 WAV（含 44 bytes header）。
  static Uint8List pcm16ToWav(
    Uint8List pcm, {
    int sampleRate = 24000,
    int channels = 1,
  }) {
    final dataLen = pcm.length;
    final bytes = BytesBuilder(copy: false);
    final header = ByteData(44);
    void w(String tag, int offset) {
      for (var i = 0; i < tag.length; i++) {
        header.setUint8(offset + i, tag.codeUnitAt(i));
      }
    }

    w('RIFF', 0);
    header.setUint32(4, 36 + dataLen, Endian.little);
    w('WAVE', 8);
    w('fmt ', 12);
    header.setUint32(16, 16, Endian.little); // fmt chunk size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    final byteRate = sampleRate * channels * 2;
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, channels * 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    w('data', 36);
    header.setUint32(40, dataLen, Endian.little);
    bytes.add(header.buffer.asUint8List());
    bytes.add(pcm);
    return bytes.toBytes();
  }

  // ---- Session 生命週期 ----

  Future<void> start() async {
    if (_state == LiveCallState.connecting || _state == LiveCallState.active) {
      return;
    }
    _state = LiveCallState.connecting;
    _errorMessage = '';
    _notify();
    try {
      final uri = buildWebSocketUri(baseUrl: baseUrl, apiKey: apiKey);
      final ws = _channelFactory(uri);
      _ws = ws;
      await ws.ready.timeout(const Duration(seconds: 15));
      ws.sink.add(buildSetupPayload(model: model, voice: voice));
      await _startMic();
      if (_state == LiveCallState.error) return;
      _closing = false;
      ws.stream.listen(
        _onServerMessage,
        onError: (Object e) => _fail('$e'),
        onDone: _onServerDone,
      );
    } catch (e) {
      _fail('$e');
    }
  }

  Future<void> _startMic() async {
    final recorder = _recorderFactory();
    _recorder = recorder;
    try {
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          echoCancel: true,
          autoGain: false,
          noiseSuppress: false,
        ),
      );
      _micSub = stream.listen(
        (chunk) => _onMicChunk(chunk),
        onError: (Object e) => _fail('mic: $e'),
      );
    } catch (e) {
      _fail('mic: $e');
    }
  }

  void _onMicChunk(Uint8List chunk) {
    if (_disposed || _closing || _muted) return;
    if (_state != LiveCallState.active) return; // setupComplete 前不送音訊
    _micBuf.add(chunk);
    if (_micBuf.length < _micChunkBytes) return;
    final data = _micBuf.takeBytes();
    _send(buildRealtimeInputPayload(data));
  }

  void _send(String payload) {
    try {
      if (_ws != null && !_closing) {
        _ws!.sink.add(payload);
      }
    } catch (_) {}
  }

  void _onServerMessage(dynamic raw) {
    if (_disposed) return;
    final Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return;
    }
    if (isSetupComplete(msg)) {
      _state = LiveCallState.active;
      _notify();
      return;
    }
    if (isGoAway(msg)) {
      unawaited(_closeGracefully());
      return;
    }
    if (isServerError(msg)) {
      _fail(extractErrorMessage(msg));
      return;
    }
    if (serverContent(msg) == null) return;

    if (isInterrupted(msg)) {
      _flushPlayback();
      if (_assistantPartial.isNotEmpty) {
        _assistantPartial = '';
        _notify();
      }
      return;
    }

    final text = extractText(msg);
    if (text.isNotEmpty) {
      _assistantPartial += text;
      _notify();
    }

    final audio = extractAudio(msg);
    for (final a in audio) {
      _playBuf.add(a);
      if (_playBuf.length >= sampleRate * 2) {
        // ~1 秒一包
        _enqueuePlayback(_playBuf.takeBytes());
      }
    }

    if (isTurnComplete(msg)) {
      if (_playBuf.length > 0) {
        _enqueuePlayback(_playBuf.takeBytes());
      }
      if (_assistantPartial.trim().isNotEmpty) {
        _turns.add(_assistantPartial.trim());
      }
      _assistantPartial = '';
      _notify();
    }
  }

  void _onServerDone() {
    if (_disposed || _closing) return;
    _fail('connection closed');
  }

  void _fail(String message) {
    if (_disposed || _state == LiveCallState.ended) return;
    _state = LiveCallState.error;
    _errorMessage = message;
    _notify();
    unawaited(_cleanup());
  }

  Future<void> _closeGracefully() async {
    if (_closing) return;
    _closing = true;
    try {
      if (_ws != null) {
        _ws!.sink.add('{"clientClose":true}');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {}
    await _cleanup();
    if (!_disposed) {
      _state = LiveCallState.ended;
      _notify();
    }
  }

  // ---- 播放佇列 ----

  void _enqueuePlayback(Uint8List pcm) {
    _playQueue.add(pcm16ToWav(pcm));
    if (!_playing) {
      unawaited(_playNext());
    }
  }

  Future<void> _playNext() async {
    if (_playing || _disposed) return;
    if (_playQueue.isEmpty) return;
    _playing = true;
    final wav = _playQueue.removeFirst();
    try {
      final dir = _tempDir ??= await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}live_api_${_audioSeq++}.wav');
      await file.writeAsBytes(wav, flush: true);
      _currentPlaybackFile = file;
      final player = AudioPlayer();
      _player = player;
      player.onPlayerComplete.listen((_) {
        if (_player != player) return; // 已被 flush/stop 清理
        _player = null;
        if (_currentPlaybackFile == file) _currentPlaybackFile = null;
        unawaited(player.dispose());
        unawaited(file.delete().then((_) {}, onError: (_) {}));
        _playing = false;
        unawaited(_playNext());
      });
      await player.play(DeviceFileSource(file.path));
    } catch (_) {
      _playing = false;
      unawaited(_playNext());
    }
  }

  void _flushPlayback() {
    _playQueue.clear();
    _playBuf.clear();
    final p = _player;
    _player = null;
    _playing = false;
    final f = _currentPlaybackFile;
    _currentPlaybackFile = null;
    if (f != null) {
      unawaited(f.delete().then((_) {}, onError: (_) {}));
    }
    if (p != null) {
      unawaited(p.stop().then((_) {}, onError: (_) {}));
      unawaited(p.dispose());
    }
  }

  // ---- 控制 ----

  Future<void> setMuted(bool value) async {
    if (_muted == value) return;
    _muted = value;
    _notify();
    if (!value) {
      // 解除靜音時清掉暫存，避免送出停頓前的舊語音
      _micBuf.clear();
    }
  }

  Future<void> stop() async {
    await _closeGracefully();
  }

  Future<void> _cleanup() async {
    _closing = true;
    _micBuf.clear();
    try {
      await _micSub?.cancel();
    } catch (_) {}
    _micSub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    try {
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
    _flushPlayback();
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _closing = true;
    unawaited(_cleanup());
    super.dispose();
  }
}
