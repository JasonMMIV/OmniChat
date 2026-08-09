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

/// 工具處理器：執行名為 [name] 的工具並回傳 JSON 可序列化結果。
/// 回傳值會以 `toolResponse` 送回伺服器；拋錯時以 `{'error': ...}` 回傳。
typedef LiveToolHandler = Future<Map<String, dynamic>> Function(
  String name,
  Map<String, dynamic> args,
);

/// 伺服器 `toolCall` 訊息中的單一 function call。
class LiveFunctionCall {
  const LiveFunctionCall({
    required this.id,
    required this.name,
    required this.args,
  });

  final String id;
  final String name;
  final Map<String, dynamic> args;
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
    this.tools = const <Map<String, dynamic>>[],
    this.toolHandler,
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

  /// Function calling：setup 宣告的 tools（`functionDeclarations`）清單。
  final List<Map<String, dynamic>> tools;

  /// 工具執行器（可為 null——此時工具呼叫回傳 `{'error': ...}`）。
  final LiveToolHandler? toolHandler;

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

  /// 等待執行的 function calls（供 UI 顯示「正在呼叫工具」）。
  List<LiveFunctionCall> get pendingToolCalls =>
      List.unmodifiable(_pendingToolCalls);

  WebSocketChannel? _ws;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  final BytesBuilder _micBuf = BytesBuilder(copy: false);

  // 診斷（P0 驗證）：實際 mic chunk 長度、每秒 chunk 數與推估取樣率。
  int _micChunkCount = 0;
  int _micChunkBytesTotal = 0;
  DateTime? _micStatsStart;

  final Queue<Uint8List> _playQueue = Queue<Uint8List>();
  /// gapless：目前播放中的槽與已 prepare、等待切換的槽。
  _PlayerSlot? _current;
  _PlayerSlot? _next;
  bool _playing = false;
  /// setSource（prepare）進行中，避免並發預備。
  bool _priming = false;
  /// flush 時遞增，讓進行中的 async 播放操作自動失效。
  int _playEpoch = 0;
  final BytesBuilder _playBuf = BytesBuilder(copy: false);
  int _audioSeq = 0;

  /// 收到 `toolCall` 後、`toolResponse` 送出前的 function calls。
  final List<LiveFunctionCall> _pendingToolCalls = <LiveFunctionCall>[];

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
    List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[],
  }) {
    final setup = <String, dynamic>{
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
    };
    if (tools.isNotEmpty) {
      setup['tools'] = tools;
    }
    return jsonEncode(<String, dynamic>{'setup': setup});
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

  /// 建立 `toolResponse` 訊息（JSON 字串）：回覆伺服器的 function call。
  static String buildToolResponsePayload({
    required String id,
    required String name,
    required Map<String, dynamic> response,
  }) {
    return jsonEncode(<String, dynamic>{
      'toolResponse': <String, dynamic>{
        'functionResponses': <Map<String, dynamic>>[
          <String, dynamic>{'id': id, 'name': name, 'response': response},
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

  /// 取出 `toolCall` 訊息中的 function calls。
  static List<LiveFunctionCall> extractToolCalls(Map<String, dynamic> msg) {
    final tc = msg['toolCall'];
    if (tc is! Map<String, dynamic>) return const <LiveFunctionCall>[];
    final calls = tc['functionCalls'];
    if (calls is! List) return const <LiveFunctionCall>[];
    final result = <LiveFunctionCall>[];
    for (final c in calls) {
      if (c is Map<String, dynamic> &&
          c['id'] is String &&
          c['name'] is String) {
        final args = c['args'];
        result.add(LiveFunctionCall(
          id: c['id'] as String,
          name: c['name'] as String,
          args: args is Map<String, dynamic> ? args : const <String, dynamic>{},
        ));
      }
    }
    return result;
  }

  /// 取出 `toolCallCancellation` 訊息中要取消的 call id。
  static List<String> extractCancelledToolIds(Map<String, dynamic> msg) {
    final tcc = msg['toolCallCancellation'];
    if (tcc is! Map<String, dynamic>) return const <String>[];
    final ids = tcc['ids'];
    if (ids is! List) return const <String>[];
    return ids.whereType<String>().toList();
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
      ws.sink.add(buildSetupPayload(model: model, voice: voice, tools: tools));
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
    if (msg['toolCall'] is Map<String, dynamic>) {
      _handleToolCall(msg);
      return;
    }
    if (msg['toolCallCancellation'] is Map<String, dynamic>) {
      final ids = extractCancelledToolIds(msg);
      if (ids.isNotEmpty) {
        _pendingToolCalls.removeWhere((c) => ids.contains(c.id));
        _notify();
      }
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

  // ---- Function calling ----

  void _handleToolCall(Map<String, dynamic> msg) {
    final calls = extractToolCalls(msg);
    if (calls.isEmpty) return;
    _pendingToolCalls.addAll(calls);
    _notify();
    final handler = toolHandler;
    for (final call in calls) {
      unawaited(_runTool(call, handler));
    }
  }

  Future<void> _runTool(LiveFunctionCall call, LiveToolHandler? handler) async {
    Map<String, dynamic> result;
    if (handler == null) {
      result = <String, dynamic>{'error': 'no tool handler registered'};
    } else {
      try {
        result = await handler(call.name, call.args);
      } catch (e) {
        result = <String, dynamic>{'error': '$e'};
      }
    }
    if (_disposed || _closing) return;
    _send(buildToolResponsePayload(
      id: call.id,
      name: call.name,
      response: result,
    ));
    _pendingToolCalls.removeWhere((c) => c.id == call.id);
    _notify();
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

  // ---- gapless 播放管線 ----

  void _enqueuePlayback(Uint8List pcm) {
    _playQueue.add(pcm16ToWav(pcm));
    unawaited(_pumpPlayback());
  }

  /// gapless：目前槽播放時預先 prepare 下一個槽（`setSource`），完成時
  /// 直接 `resume` 切換，避免每包重建 player 造成可聽間隙。
  Future<void> _pumpPlayback() async {
    if (_disposed || _closing) return;
    if (_current == null) {
      await _startSlot();
    } else if (_next == null && !_priming) {
      await _primeSlot();
    }
  }

  _PlayerSlot _createSlot() {
    final seq = _audioSeq++;
    final player = _playerFactory('live_$seq');
    final slot = _PlayerSlot(player, _playQueue.removeFirst());
    slot.sub = player.onPlayerComplete.listen((_) => _onSlotComplete(slot));
    return slot;
  }

  Future<void> _startSlot() async {
    if (_disposed || _closing || _playing) return;
    if (_playQueue.isEmpty) return;
    final epoch = _playEpoch;
    final slot = _createSlot();
    _current = slot;
    try {
      // Android：必須用 mediaPlayer 模式——lowLatency 走 SoundPool，而
      // SoundPool 不支援 BytesSource（setForSoundPool 直接 error）。
      await slot.player.setPlayerMode(PlayerMode.mediaPlayer);
      if (epoch != _playEpoch) return;
      await slot.player.setSource(BytesSource(slot.wav));
      if (epoch != _playEpoch) {
        _disposeSlot(slot);
        return;
      }
      await slot.player.resume();
      if (epoch != _playEpoch) {
        _disposeSlot(slot);
        return;
      }
      _playing = true;
      _notify();
      FlutterLogger.log(
        'play #${_audioSeq - 1} start (${slot.wav.length} bytes)',
        tag: 'live-api',
      );
    } catch (e) {
      FlutterLogger.log('live playback failed: $e', tag: 'live-api');
      if (_current == slot) _current = null;
      _disposeSlot(slot);
      if (!_disposed && !_closing) {
        final next = _next;
        if (next != null) {
          // 已有預備槽（在目前槽失敗前已 prepare）：直接提拔為目前槽，
          // 避免管線卡住（佇列可能已被預備槽取空）。
          _next = null;
          _current = next;
          await _switchTo(next);
        } else {
          await _startSlot();
        }
      }
      return;
    }
    unawaited(_primeSlot());
  }

  /// 預先 prepare 下一個播放包（不播放）。
  Future<void> _primeSlot() async {
    if (_disposed || _closing || _priming) return;
    if (_next != null || _current == null) return;
    if (_playQueue.isEmpty) return;
    _priming = true;
    final epoch = _playEpoch;
    final slot = _createSlot();
    try {
      await slot.player.setPlayerMode(PlayerMode.mediaPlayer);
      if (epoch != _playEpoch) {
        _disposeSlot(slot);
        return;
      }
      await slot.player.setSource(BytesSource(slot.wav));
      if (epoch != _playEpoch) {
        _disposeSlot(slot);
        return;
      }
      if (_next == null && !_disposed && !_closing) {
        if (_current == null) {
          // 目前槽在我預備期間失敗並清空佇列：直接接手成為目前槽，
          // 避免管線卡住（_startSlot 遞迴時佇列已空）。
          _current = slot;
          await _switchTo(slot);
        } else {
          _next = slot;
        }
      } else {
        _disposeSlot(slot); // 已被 flush 或取代
      }
    } catch (e) {
      FlutterLogger.log('live playback prepare failed: $e', tag: 'live-api');
      _disposeSlot(slot);
      if (!_disposed && !_closing && _current != null) {
        // 跳過失敗包，繼續預備下一個
        unawaited(_primeSlot());
      }
    } finally {
      _priming = false;
    }
  }

  void _onSlotComplete(_PlayerSlot slot) {
    if (_disposed || _closing) return;
    if (_current != slot) return; // 已被取代
    final next = _next;
    _current = null;
    _next = null;
    _disposeSlot(slot);
    if (next != null) {
      _current = next;
      unawaited(_switchTo(next));
    } else {
      _playing = false;
      _notify();
      if (_playQueue.isNotEmpty) unawaited(_startSlot());
    }
  }

  /// 切換到已 prepare 的槽（gapless 的關鍵：只 resume，不重新建立）。
  Future<void> _switchTo(_PlayerSlot slot) async {
    final epoch = _playEpoch;
    try {
      await slot.player.resume();
      if (epoch != _playEpoch) {
        _disposeSlot(slot);
        return;
      }
      if (_current == slot) {
        _playing = true;
        _notify();
        unawaited(_primeSlot());
      }
    } catch (e) {
      FlutterLogger.log('live playback resume failed: $e', tag: 'live-api');
      if (_current == slot) _current = null;
      _disposeSlot(slot);
      if (!_disposed && !_closing) {
        _playing = false;
        _notify();
        if (_playQueue.isNotEmpty) unawaited(_startSlot());
      }
    }
  }

  void _disposeSlot(_PlayerSlot? slot) {
    if (slot == null) return;
    unawaited(slot.sub?.cancel());
    slot.sub = null;
    unawaited(slot.player.stop().then((_) {}, onError: (_) {}));
    unawaited(slot.player.dispose().catchError((_) {}));
  }

  /// 清空播放佇列並釋放所有播放槽（interrupted、stop、錯誤、goAway 共用）。
  void _flushPlayback() {
    _playEpoch++; // 讓進行中的 async 播放操作自動失效
    _playQueue.clear();
    _playBuf.clear();
    final c = _current;
    final n = _next;
    _current = null;
    _next = null;
    _playing = false;
    _disposeSlot(c);
    _disposeSlot(n);
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

/// gapless 播放槽：一個 WAV 播放包 + 對應的 [AudioPlayer]。
class _PlayerSlot {
  _PlayerSlot(this.player, this.wav);

  final AudioPlayer player;
  final Uint8List wav;
  StreamSubscription<void>? sub;
}
