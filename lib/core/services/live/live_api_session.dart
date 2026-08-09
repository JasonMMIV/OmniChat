import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../logging/flutter_logger.dart';
import 'live_api_models_service.dart' show maskApiKey;

/// Live API 通話狀態。
enum LiveCallState {
  idle,
  connecting,
  active,
  /// 進入背景（lifecycle paused/hidden）：連線保留、麥克風暫停。
  background,
  /// 斷線後自動重連中（有限次數退避）。
  reconnecting,
  error,
  ended,
}

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
    AudioPlayer Function(String playerId)? playerFactory,
    this.maxReconnectAttempts = 3,
    this.reconnectBackoffBase = const Duration(seconds: 1),
  })  : _channelFactory =
            channelFactory ?? ((uri) => IOWebSocketChannel.connect(uri)),
        _recorderFactory = recorderFactory ?? (() => AudioRecorder()),
        _playerFactory = playerFactory ?? ((id) => AudioPlayer(playerId: id));

  final String apiKey;
  final String model;
  final String voice;
  final String baseUrl;
  final WebSocketChannel Function(Uri uri) _channelFactory;
  final AudioRecorder Function() _recorderFactory;
  final AudioPlayer Function(String playerId) _playerFactory;

  /// 輸出（模型音訊）取樣率：16-bit PCM、mono、24 kHz。
  static const int outputSampleRate = 24000;

  /// 輸入（麥克風）取樣率：16-bit PCM、mono、16 kHz。
  /// 與 [outputSampleRate] 刻意分開命名，兩者不得共用同一個常數。
  static const int micSampleRate = 16000;

  /// 100ms @ 16kHz mono 16-bit。
  static const int _micChunkBytes = 3200;

  LiveCallState _state = LiveCallState.idle;
  LiveCallState get state => _state;

  String _errorMessage = '';
  String get errorMessage => _errorMessage;

  bool _muted = false;
  bool get muted => _muted;

  /// 目前未完成的助理句子（串流中）。
  String _assistantPartial = '';
  String get assistantPartial => _assistantPartial;

  /// 目前使用者的語音即時轉錄（input transcription，串流中）。
  ///
  /// 與 [assistantPartial] 不同：同一句話的文字會持續遞增/修正，
  /// 因此採「取代」語意；turnComplete 時清除（下一個語句重新填入）。
  String _userPartial = '';
  String get userPartial => _userPartial;

  /// 已完成的助理句子（`turnComplete` 後提交）。
  final List<String> _turns = <String>[];
  List<String> get turns => List.unmodifiable(_turns);

  WebSocketChannel? _ws;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  final BytesBuilder _micBuf = BytesBuilder(copy: false);

  // 診斷（P0 驗證）：實際 mic chunk 長度、每秒 chunk 數與推估取樣率。
  int _micChunkCount = 0;
  int _micChunkBytesTotal = 0;
  DateTime? _micStatsStart;

  final Queue<Uint8List> _playQueue = Queue<Uint8List>();
  AudioPlayer? _player;
  StreamSubscription<void>? _playSub;
  bool _playing = false;
  final BytesBuilder _playBuf = BytesBuilder(copy: false);
  int _audioSeq = 0;

  bool _disposed = false;
  bool _closing = false;

  // 診斷：用於定位「連線中數分鐘後 1008」
  DateTime? _connectStart;
  DateTime? _setupCompleteAt;
  int _serverMessageCount = 0;
  String _lastServerKeys = '';
  Timer? _setupTimeout;

  /// §5.7：斷線自動重連——有限次數 + 退避。
  final int maxReconnectAttempts;
  final Duration reconnectBackoffBase;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Future<void>? _pendingCleanup;

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
  }) {
    final payload = <String, dynamic>{
      'setup': <String, dynamic>{
        'model': model.startsWith('models/') ? model : 'models/$model',
        'generation_config': <String, dynamic>{
          'response_modalities': <String>['AUDIO'],
          'speech_config': <String, dynamic>{
            'voice_config': <String, dynamic>{
              'prebuilt_voice_config': <String, dynamic>{'voice_name': voice},
            },
          },
        },
        'realtime_input_config': <String, dynamic>{
          'automatic_activity_detection': <String, dynamic>{
            'start_of_speech_sensitivity': 'START_SENSITIVITY_HIGH',
            'end_of_speech_sensitivity': 'END_SENSITIVITY_HIGH',
            'prefix_padding_ms': 100,
            'silence_duration_ms': 500,
          },
        },
        'input_audio_transcription': <String, dynamic>{},
        'output_audio_transcription': <String, dynamic>{},
      },
    };
    return jsonEncode(payload);
  }

  /// 建立 realtimeInput 訊息（JSON 字串）。
  static String buildRealtimeInputPayload(Uint8List pcm) {
    return jsonEncode(<String, dynamic>{
      'realtimeInput': <String, dynamic>{
        'audio': <String, String>{
          'mimeType': 'audio/pcm;rate=$micSampleRate',
          'data': base64Encode(pcm),
        },
      },
    });
  }

  /// 建立 `audio_stream_end` 訊息（JSON 字串）。
  ///
  /// 通知伺服器輸入串流已結束（mute、停止錄音與通話結束時送出），
  /// 讓伺服器可以完成目前 turn 的 VAD 判斷。
  static String buildAudioStreamEndPayload() {
    return jsonEncode(<String, dynamic>{
      'realtimeInput': <String, dynamic>{
        'audio_stream_end': <String, dynamic>{},
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

  /// 取出 serverContent 中的使用者語音即時轉錄（input transcription）。
  ///
  /// Live API 實測回傳 snake_case（`input_transcription`，與既有
  /// `output_transcription` 一致），但官方文件寫 camelCase
  /// （`inputTranscription`）——兩種都解析以防 API 變動。
  static String extractInputTranscription(Map<String, dynamic> msg) {
    final content = serverContent(msg);
    if (content == null) return '';
    final t = content['input_transcription'] ?? content['inputTranscription'];
    if (t is Map<String, dynamic> && t['text'] is String) {
      return t['text'] as String;
    }
    return '';
  }

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
    int sampleRate = outputSampleRate,
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

  /// 開始通話（或錯誤後手動重試）。重連流程內部呼叫 [_connect]，
  /// 不會重置重連計數。
  Future<void> start() async {
    if (_state == LiveCallState.connecting ||
        _state == LiveCallState.active ||
        _state == LiveCallState.reconnecting) {
      return;
    }
    _reconnectAttempt = 0;
    await _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _state = LiveCallState.connecting;
    _errorMessage = '';
    _notify();
    try {
      final uri = buildWebSocketUri(baseUrl: baseUrl, apiKey: apiKey);
      final ws = _channelFactory(uri);
      _ws = ws;
      await ws.ready.timeout(const Duration(seconds: 15));
      _connectStart = DateTime.now();
      _serverMessageCount = 0;
      _lastServerKeys = '';
      _setupCompleteAt = null;
      _closing = false;
      ws.stream.listen(
        _onServerMessage,
        onError: (Object e) => _onWsError(ws, e),
        onDone: () => _onServerDone(ws),
      );
      ws.sink.add(buildSetupPayload(model: model, voice: voice));
      _setupTimeout?.cancel();
      _setupTimeout = Timer(const Duration(seconds: 15), () {
        if (_state == LiveCallState.connecting && !_disposed && !_closing) {
          final elapsed = _connectStart != null
              ? DateTime.now().difference(_connectStart!).inSeconds
              : -1;
          _scheduleReconnect(
            'setup timeout (${elapsed}s): '
            'received $_serverMessageCount msgs, last=[$_lastServerKeys]',
          );
        }
      });
      await _startMic();
    } catch (e) {
      // WebSocketException 訊息含完整 uri（含 `?key=...`），先遮蔽再顯示。
      _scheduleReconnect('connect failed: ${maskApiKey('$e', apiKey)}');
    }
  }

  Future<void> _startMic() async {
    final recorder = _recorderFactory();
    _recorder = recorder;
    try {
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          // P0：錄音必須使用 micSampleRate（16 kHz），
          // 不得沿用輸出用的 outputSampleRate（24 kHz）。
          sampleRate: micSampleRate,
          numChannels: 1,
          echoCancel: true,
          autoGain: false,
          noiseSuppress: false,
          // Android：record 的 AudioSessionManager 在 focus loss 時會暫停錄音，
          // 且預設 PAUSE 中斷模式在 focus 回來時不會恢復（永久停 mic）。
          // 本 app 由 call mode（startCallMode/audio_session）集中管理 focus，
          // 錄音器必須對 focus 變化免疫，避免播放模型語音時 mic 被暫停。
          audioInterruption: AudioInterruptionMode.none,
        ),
      );
      _micSub = stream.listen(
        (chunk) => _onMicChunk(chunk),
        onError: (Object e) => _fail('mic: $e'),
        // 診斷：平台側自行結束串流（非我方 stop）時記錄，用於定位 mic 中斷。
        onDone: () => FlutterLogger.log('mic stream ended', tag: 'live-api'),
      );
    } catch (e) {
      _fail('mic: $e');
    }
  }

  void _onMicChunk(Uint8List chunk) {
    // 診斷：統計實際收到的 chunk（含播放中丟棄的），驗證 mic 真實輸出格式。
    _micChunkCount++;
    _micChunkBytesTotal += chunk.length;
    _micStatsStart ??= DateTime.now();
    if (_micChunkCount % 10 == 0) _logMicStats();

    if (_disposed || _closing || _muted) return;
    if (_state != LiveCallState.active) return; // setupComplete 前不送音訊
    if (_playing) return; // 半雙工：播放中不送 mic，避免回聲
    _micBuf.add(chunk);
    if (_micBuf.length < _micChunkBytes) return;
    var data = _micBuf.takeBytes();
    // PCM16 frame = 2 bytes；送出前維持偶數對齊，避免伺服器解碼錯位。
    if (data.length.isOdd) {
      FlutterLogger.log(
        'mic odd-length frame ${data.length} bytes; dropping 1 byte '
        'to keep PCM16 alignment',
        tag: 'live-api',
      );
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    _send(buildRealtimeInputPayload(data));
  }

  /// 記錄實際 mic 輸出格式診斷（chunk 長度、每秒 chunk 數、推估取樣率）。
  void _logMicStats() {
    final start = _micStatsStart;
    if (start == null || _micChunkCount == 0) return;
    final elapsed = DateTime.now().difference(start).inMilliseconds / 1000.0;
    final avgChunkBytes = _micChunkBytesTotal / _micChunkCount;
    final estRate = elapsed > 0 ? ((_micChunkBytesTotal ~/ 2) / elapsed).round() : 0;
    FlutterLogger.log(
      'mic pcm: chunks=$_micChunkCount bytes=$_micChunkBytesTotal '
      'avgChunkBytes=${avgChunkBytes.toStringAsFixed(1)} '
      'channels=1 bits=16 configRate=$micSampleRate '
      'estRate=${estRate}Hz (over ${elapsed.toStringAsFixed(1)}s)',
      tag: 'live-api',
    );
  }

  void _send(String payload) {
    try {
      if (_ws != null && !_closing) {
        _ws!.sink.add(payload);
      }
    } catch (_) {}
  }

  /// 送出 `audio_stream_end`。僅在 session active（setupComplete 後）且
  /// 連線仍存在時送出；state 離開 active 後重複呼叫會自動 no-op。
  void _sendStreamEnd() {
    if (_disposed || _closing) return;
    if (_state != LiveCallState.active) return; // setupComplete 前不得送
    if (_ws == null) return;
    _send(buildAudioStreamEndPayload());
  }

  void _onServerMessage(dynamic raw) {
    if (_disposed || _closing) return;
    final Map<String, dynamic> msg;
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return;
    }
    _serverMessageCount++;
    _lastServerKeys = msg.keys.join(',');
    if (isSetupComplete(msg)) {
      _setupTimeout?.cancel();
      _setupCompleteAt = DateTime.now();
      // 連線成功 → 重設重連計數，避免多次短暫斷線累加耗盡重試次數
      _reconnectAttempt = 0;
      _state = LiveCallState.active;
      _notify();
      return;
    }
    if (isGoAway(msg)) {
      unawaited(_closeGracefully());
      return;
    }
    if (isServerError(msg)) {
      // 伺服器錯誤訊息亦過遮蔽層，防任何管道回顯 API Key。
      _fail(maskApiKey(extractErrorMessage(msg), apiKey));
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

    // 轉錄（AUDIO 模式下的字幕來源）
    final sc2 = serverContent(msg);
    if (sc2 != null) {
      final outTrans = sc2['output_transcription'];
      if (outTrans is Map<String, dynamic> && outTrans['text'] is String) {
        final t = outTrans['text'] as String;
        if (t.isNotEmpty) {
          _assistantPartial += t;
          _notify();
        }
      }
    }
    // 使用者語音即時轉錄：取代語意（同一句話的遞增/修正文字）。
    final inTrans = extractInputTranscription(msg);
    if (inTrans.isNotEmpty && inTrans != _userPartial) {
      _userPartial = inTrans;
      _notify();
    }
    final text = extractText(msg);
    if (text.isNotEmpty) {
      _assistantPartial += text;
      _notify();
    }

    final audio = extractAudio(msg);
    if (_state == LiveCallState.background) {
      // 背景：不播放模型音訊（audio focus 已讓出），只累積轉錄
      _playBuf.clear();
    } else {
      for (final a in audio) {
        _playBuf.add(a);
        if (_playBuf.length >= 24000) {
          // ~0.5 秒一包，平衡延遲與斷續
          _enqueuePlayback(_playBuf.takeBytes());
        }
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
      // 本輪使用者語句已完成，清除即時轉錄；下一個語句的轉錄會重新填入。
      _userPartial = '';
      _notify();
    }
  }

  void _onServerDone(WebSocketChannel ws) {
    if (_disposed || _closing) return;
    if (_ws != ws) return; // 已被取代的舊連線
    _setupTimeout?.cancel();
    final code = ws.closeCode;
    final reason = ws.closeReason ?? '';
    final detail =
        code != null ? ' (code: $code${reason.isNotEmpty ? ', $reason' : ''})' : '';
    final elapsed = _connectStart != null
        ? DateTime.now().difference(_connectStart!).inSeconds
        : -1;
    final diag =
        ' [diag: setupComplete=${_setupCompleteAt != null ? 'yes' : 'no'}, '
        'msgs=$_serverMessageCount, last=[$_lastServerKeys], elapsed=${elapsed}s]';
    // §5.7：非預期斷線 → 有限次數退避重連；無法恢復才進 error
    _scheduleReconnect('connection closed$detail$diag');
  }

  void _onWsError(WebSocketChannel ws, Object e) {
    if (_disposed || _closing) return;
    if (_ws != ws) return;
    // WebSocketException 訊息含完整 uri（含 `?key=...`），先遮蔽再顯示。
    _scheduleReconnect('ws error: ${maskApiKey('$e', apiKey)}');
  }

  /// §5.7：斷線自動重連——先完成上一個 session 的 cleanup（不並存多個
  /// recorder/ws/player），再以退避延遲重連；超過 [maxReconnectAttempts]
  /// 次後進入 [LiveCallState.error]，由 UI 提供手動重試。
  void _scheduleReconnect(String reason) {
    if (_disposed || _state == LiveCallState.ended) return;
    if (_state == LiveCallState.reconnecting) return;
    if (_reconnectAttempt >= maxReconnectAttempts) {
      _fail(
        '$reason — 已重連 $_reconnectAttempt 次仍失敗，請檢查網路後重試',
      );
      return;
    }
    _reconnectAttempt++;
    _state = LiveCallState.reconnecting;
    _errorMessage = reason;
    _notify();
    // 重試前完成上一個 session 的資源清理
    _cleanup();
    final delay = reconnectBackoffBase * (1 << (_reconnectAttempt - 1));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (_disposed || _state == LiveCallState.ended) return;
      await _cleanup();
      if (_disposed || _state == LiveCallState.ended) return;
      await _connect();
    });
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
    // 通話結束：先通知伺服器輸入串流結束，再關閉連線
    _sendStreamEnd();
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

  /// §5.6：依序播放——下一個播放包只在上一個完成（或失敗）後啟動。
  ///
  /// - 播放失敗（如 Windows Media Foundation）會 dispose player 並記錄
  ///   可診斷 log，再繼續佇列。
  /// - setPlayerMode/play 等待期間若被 [flushPlayback]（interrupted、stop、
  ///   錯誤、goAway）取代，直接放棄該 player，不重設狀態、不續播。
  Future<void> _playNext() async {
    if (_playing || _disposed || _closing) return;
    if (_playQueue.isEmpty) return;
    _playing = true;
    final wav = _playQueue.removeFirst();
    final seq = _audioSeq++;
    final player = _playerFactory('live_$seq');
    _player = player;
    StreamSubscription<void>? sub;
    try {
      // Android：必須用 mediaPlayer 模式——lowLatency 走 SoundPool，而
      // SoundPool 不支援 BytesSource（setForSoundPool 直接 error），
      // 導致模型語音在 Android 上完全無法播放。Windows 僅支援 mediaPlayer。
      await player.setPlayerMode(PlayerMode.mediaPlayer);
      FlutterLogger.log('play #$seq start (${wav.length} bytes)', tag: 'live-api');
      if (_player != player) {
        // 播放設定期間已被 flush/stop 取代
        unawaited(player.dispose().catchError((_) {}));
        return;
      }
      sub = player.onPlayerComplete.listen((_) {
        if (_player != player) return; // 已被 flush/stop 清理
        _player = null;
        _playSub = null;
        unawaited(sub?.cancel());
        unawaited(player.dispose().catchError((_) {}));
        _playing = false;
        FlutterLogger.log('play #$seq done', tag: 'live-api');
        unawaited(_playNext());
      });
      _playSub = sub;
      await player.play(BytesSource(wav));
    } catch (e) {
      final isCurrent = _player == player;
      if (isCurrent) {
        _player = null;
        _playSub = null;
        _playing = false;
      }
      unawaited(sub?.cancel());
      unawaited(player.dispose().catchError((_) {}));
      FlutterLogger.log('live playback failed: $e', tag: 'live-api');
      if (isCurrent && !_disposed && !_closing) {
        unawaited(_playNext());
      }
    }
  }

  /// 清空播放佇列並釋放目前 player（interrupted、stop、錯誤、goAway 共用）。
  void _flushPlayback() {
    _playQueue.clear();
    _playBuf.clear();
    _playSub?.cancel();
    _playSub = null;
    final p = _player;
    _player = null;
    _playing = false;
    if (p != null) {
      unawaited(p.stop().then((_) {}, onError: (_) {}));
      unawaited(p.dispose().catchError((_) {}));
    }
  }

  // ---- lifecycle（§5.7）----

  /// 進入背景：送出 stream end、停止麥克風、清空播放佇列；WebSocket
  /// 連線保留，前景恢復時直接重啟 mic，不需重連。
  Future<void> pause() async {
    if (_disposed || _state != LiveCallState.active) return;
    _sendStreamEnd();
    _state = LiveCallState.background;
    _notify();
    _micBuf.clear();
    await _stopMic();
    _flushPlayback();
  }

  /// 回到前景：重新啟動麥克風串流並恢復 [LiveCallState.active]。
  Future<void> resume() async {
    if (_disposed || _state != LiveCallState.background) return;
    _state = LiveCallState.active;
    _notify();
    _micBuf.clear();
    await _startMic();
  }

  // ---- 控制 ----

  Future<void> setMuted(bool value) async {
    if (_muted == value) return;
    _muted = value;
    if (value) {
      // 靜音：通知伺服器輸入串流結束，讓伺服器完成目前 turn
      _sendStreamEnd();
    } else {
      // 解除靜音：清掉暫存，避免送出停頓前的舊語音；重新開始音訊串流
      _micBuf.clear();
    }
    _notify();
  }

  Future<void> stop() async {
    await _closeGracefully();
  }

  Future<void> _stopMic() async {
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
  }

  /// 清理 session 資源。重連/重試/停止/錯誤共用；並發呼叫去重，重試
  /// 流程會先 await 此清理完成才建立新連線（§5.7 驗收）。
  Future<void> _cleanup() {
    return _pendingCleanup ??= _doCleanup().whenComplete(() {
      _pendingCleanup = null;
    });
  }

  Future<void> _doCleanup() async {
    _closing = true;
    _setupTimeout?.cancel();
    _reconnectTimer?.cancel();
    final ws = _ws;
    _ws = null; // 立即斷開，避免後續 _send/_onServerDone 打到舊連線
    _micBuf.clear();
    _micChunkCount = 0;
    _micChunkBytesTotal = 0;
    _micStatsStart = null;
    await _stopMic();
    _flushPlayback();
    if (ws != null) {
      try {
        await ws.sink.close();
      } catch (_) {}
    }
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
