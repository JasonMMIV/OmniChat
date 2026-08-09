import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocketException;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:OmniChat/core/services/live/live_api_session.dart';

// ---- fakes ----

class _FakeSink implements WebSocketSink {
  _FakeSink(this._channel);

  final _FakeWebSocketChannel _channel;

  @override
  void add(dynamic data) => _channel.sent.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<dynamic> stream) async {
    await for (final e in stream) {
      add(e);
    }
  }

  @override
  Future close([int? closeCode, String? closeReason]) {
    _channel.sinkClosed = true;
    _channel.closeCode = closeCode;
    _channel.closeReason = closeReason;
    return Future<void>.value();
  }

  @override
  Future get done => Future<void>.value();
}

class _FakeWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  _FakeWebSocketChannel() {
    _incoming = StreamController<dynamic>.broadcast(sync: true);
  }

  final List<dynamic> sent = [];
  late final StreamController<dynamic> _incoming;
  bool sinkClosed = false;

  // 公開欄位同時滿足介面的 getter（int? get closeCode 等）。
  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  /// 模擬伺服器推訊息。
  void push(Map<String, dynamic> msg) => _incoming.add(jsonEncode(msg));

  /// 伺服器主動關閉連線。
  void serverClose(int code, String reason) async {
    closeCode = code;
    closeReason = reason;
    await _incoming.close();
  }

  /// 模擬串流錯誤（如 WebSocketException）。
  void serverError(Object e) => _incoming.addError(e);
}

class _FakeRecorder extends AudioRecorder {
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast(sync: true);

  RecordConfig? lastConfig;
  bool failStart = false;
  bool stopped = false;
  bool disposed = false;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    lastConfig = config;
    if (failStart) throw Exception('mic init failed');
    return _chunks.stream;
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _chunks.close();
  }

  void emit(Uint8List chunk) => _chunks.add(chunk);
}

class _FakePlayer extends AudioPlayer {
  _FakePlayer({super.playerId});

  // async 派發：emitComplete 的 listener 內會同步呼叫 dispose()
  // （close controller），sync 派發會在 add 進行中拋
  // 「Cannot fire new event」，因此不用 sync: true。
  final StreamController<void> _complete =
      StreamController<void>.broadcast();

  Source? lastSource;
  bool disposed = false;
  int playCount = 0;

  /// [setSource] 已呼叫（gapless 預備播放：prepare 完成但尚未 resume）。
  bool prepared = false;

  /// 為 true 時 [setSource] 拋錯（模擬 Windows Media Foundation 播放失敗）。
  bool failPlay = false;

  @override
  Stream<void> get onPlayerComplete => _complete.stream;

  @override
  Future<void> setPlayerMode(PlayerMode mode) async {}

  @override
  Future<void> setSource(Source source) async {
    lastSource = source;
    prepared = true;
    if (failPlay) throw Exception('Media Foundation playback failed');
  }

  @override
  Future<void> resume() async {
    playCount++;
  }

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    playCount++;
    lastSource = source;
    if (failPlay) throw Exception('Media Foundation playback failed');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _complete.close();
  }

  /// 模擬播放完成。
  void emitComplete() => _complete.add(null);
}

class _Harness {
  _Harness({
    this.maxReconnects = 3,
    this.failPlayForFirstN = 0,
    this.toolHandler,
  }) {
    session = LiveApiSession(
      apiKey: 'AIza-test',
      model: 'gemini-3.1-flash-live-preview',
      voice: 'Kore',
      baseUrl: 'wss://example.com/ws',
      toolHandler: toolHandler,
      maxReconnectAttempts: maxReconnects,
      // 測試用短退避（10ms 起、指數成長），避免測試等待真實秒級退避
      reconnectBackoffBase: const Duration(milliseconds: 10),
      channelFactory: (_) {
        final w = _FakeWebSocketChannel();
        wsList.add(w);
        return w;
      },
      recorderFactory: () {
        final r = _FakeRecorder();
        recorders.add(r);
        return r;
      },
      playerFactory: (id) {
        final p = _FakePlayer(playerId: id);
        if (players.length < failPlayForFirstN) {
          p.failPlay = true;
        }
        players.add(p);
        return p;
      },
    );
  }

  final LiveToolHandler? toolHandler;

  late final LiveApiSession session;

  /// 每次連線建立一個新 channel（重連會新增）。
  final List<_FakeWebSocketChannel> wsList = <_FakeWebSocketChannel>[];
  final List<_FakeRecorder> recorders = <_FakeRecorder>[];
  final List<_FakePlayer> players = <_FakePlayer>[];

  final int maxReconnects;

  /// 前 N 個建立的 player 會播放失敗（測播放失敗續播）。
  final int failPlayForFirstN;

  _FakeWebSocketChannel get ws => wsList.last;
  _FakeRecorder get recorder => recorders.last;

  /// start() 到 setupComplete → active。
  Future<void> activate() async {
    await session.start();
    expect(session.state, LiveCallState.connecting);
    ws.push(<String, dynamic>{'setupComplete': <String, dynamic>{}});
    await Future<void>.delayed(Duration.zero);
    expect(session.state, LiveCallState.active);
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  void sendAudio(int bytes) => recorder.emit(Uint8List(bytes));

  /// 伺服器送一段模型音訊（≥ 24000 bytes 會立即進播放佇列）。
  void pushModelAudio(int bytes) {
    ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'modelTurn': <String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{
              'inlineData': <String, dynamic>{
                'data': base64Encode(Uint8List(bytes)),
              },
            },
          ],
        },
      },
    });
  }

  void pushTurnComplete() {
    ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{'turnComplete': true},
    });
  }
}

// ---- tests ----

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // AudioRecorder 建構子會 fire-and-forget 呼叫 platform create；
    // 測試環境沒有 plugin，註冊 mock 避免 MissingPluginException。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (MethodCall call) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global'),
          (MethodCall call) async => null,
        );
    // AudioPlayer 建構子對 base channel 呼叫 create
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers'),
          (MethodCall call) async => null,
        );
  });

  test('setupComplete 前不送音訊或 stream end', () async {
    final h = _Harness();
    await h.session.start();
    // start() 只送 setup payload
    expect(h.ws.sent.length, 1);
    expect(jsonDecode(h.ws.sent.first as String), isA<Map<String, dynamic>>());

    // setupComplete 前送 mic chunk → 丟棄
    h.sendAudio(3200);
    await h.pump();
    expect(h.ws.sent.length, 1);

    // setupComplete 前 mute → 不送 stream end
    await h.session.setMuted(true);
    expect(h.ws.sent.length, 1);
    await h.session.setMuted(false);

    h.session.dispose();
    await h.pump();
  });

  test('setupComplete 後 mic 資料以 audio 欄位送出', () async {
    final h = _Harness();
    await h.activate();
    h.sendAudio(3200); // 100ms @ 16kHz
    await h.pump();
    expect(h.ws.sent.length, 2); // setup + 1 個 audio
    final msg = jsonDecode(h.ws.sent.last as String) as Map<String, dynamic>;
    final audio =
        ((msg['realtimeInput'] as Map)['audio']) as Map<String, dynamic>;
    expect(audio['mimeType'], 'audio/pcm;rate=16000');
    expect(
      base64Decode(audio['data'] as String).length,
      3200,
    );
    h.session.dispose();
    await h.pump();
  });

  test('mute 送 audio_stream_end；unmute 清空 buffer 不重送舊 PCM', () async {
    final h = _Harness();
    await h.activate();

    // 先累積部分 chunk（< 100ms，尚未送出）
    h.sendAudio(1600);
    await h.pump();
    expect(h.ws.sent.length, 1);

    // mute → 送出 stream end
    await h.session.setMuted(true);
    final endMsg =
        jsonDecode(h.ws.sent.last as String) as Map<String, dynamic>;
    expect(
      ((endMsg['realtimeInput'] as Map)['audio_stream_end']),
      isA<Map<String, dynamic>>(),
    );
    final sentBefore = h.ws.sent.length;

    // 靜音期間 mic 資料被丟棄
    h.sendAudio(3200);
    await h.pump();
    expect(h.ws.sent.length, sentBefore);

    // unmute → 清掉舊 buffer（1600 bytes），新 chunk 才送出
    await h.session.setMuted(false);
    h.sendAudio(3200);
    await h.pump();
    expect(h.ws.sent.length, sentBefore + 1);
    final audioMsg =
        jsonDecode(h.ws.sent.last as String) as Map<String, dynamic>;
    final audio =
        ((audioMsg['realtimeInput'] as Map)['audio']) as Map<String, dynamic>;
    expect(base64Decode(audio['data'] as String).length, 3200); // 只有新資料

    h.session.dispose();
    await h.pump();
  });

  test('模型播放中不送 mic；播放完成後恢復送出（半雙工）', () async {
    final h = _Harness();
    await h.activate();

    // 伺服器送 24000 bytes 音訊（≥ 播放包門檻）→ 開始播放
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'modelTurn': <String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{
              'inlineData': <String, dynamic>{
                'data': base64Encode(Uint8List(24000)),
              },
            },
          ],
        },
      },
    });
    await h.pump();
    expect(h.players, isNotEmpty);
    expect(h.players.single.playCount, 1);
    final sentBefore = h.ws.sent.length;

    // 播放中送 mic → 丟棄
    h.sendAudio(3200);
    await h.pump();
    expect(h.ws.sent.length, sentBefore);

    // 播放完成 → 恢復 mic
    h.players.single.emitComplete();
    await h.pump();
    h.sendAudio(3200);
    await h.pump();
    expect(h.ws.sent.length, sentBefore + 1);

    h.session.dispose();
    await h.pump();
  });

  test('stop() 先送 stream end 再關閉，並清理所有資源', () async {
    final h = _Harness();
    await h.activate();

    await h.session.stop();

    final sent = h.ws.sent.cast<String>().toList();
    // setup → audio_stream_end → clientClose
    final endMsg = jsonDecode(sent[sent.length - 2]) as Map<String, dynamic>;
    expect(
      ((endMsg['realtimeInput'] as Map)['audio_stream_end']),
      isA<Map<String, dynamic>>(),
    );
    expect(sent.last, '{"clientClose":true}');
    expect(h.session.state, LiveCallState.ended);
    expect(h.recorder.stopped, isTrue);
    expect(h.recorder.disposed, isTrue);
    expect(h.ws.sinkClosed, isTrue);
  });

  test('retry 不會重用舊 buffer（重連前清空 mic 暫存）', () async {
    final h = _Harness();
    await h.activate();

    // 累積部分資料後伺服器 error → cleanup 清 buffer
    h.sendAudio(1600);
    await h.pump();
    h.ws.push(<String, dynamic>{
      'error': <String, dynamic>{'status': 'ERROR', 'message': 'boom'},
    });
    await h.pump();
    expect(h.session.state, LiveCallState.error);

    // 重新 start → 重新建立 recorder
    await h.session.start();
    h.ws.push(<String, dynamic>{'setupComplete': <String, dynamic>{}});
    await h.pump();
    expect(h.session.state, LiveCallState.active);
    expect(h.recorders.length, 2);

    // 送出 3200 bytes 新資料：只含新資料（不含先前 1600 bytes 殘留）
    h.sendAudio(3200);
    await h.pump();
    final msgs = h.ws.sent.cast<String>();
    final audioMsgs =
        msgs
            .map(jsonDecode)
            .whereType<Map<String, dynamic>>()
            .where(
              (m) =>
                  (m['realtimeInput'] as Map?)?.containsKey('audio') ?? false,
            )
            .toList();
    expect(audioMsgs, isNotEmpty);
    final data =
        (((audioMsgs.last['realtimeInput'] as Map)['audio'])
                as Map<String, dynamic>)['data'] as String;
    expect(base64Decode(data).length, 3200);

    h.session.dispose();
    await h.pump();
  });

  test('recorder 啟動失敗保留原始 mic 錯誤', () async {
    final failing = _FakeRecorder()..failStart = true;
    final ws = _FakeWebSocketChannel();
    final session = LiveApiSession(
      apiKey: 'AIza-test',
      model: 'gemini-3.1-flash-live-preview',
      voice: 'Kore',
      baseUrl: 'wss://example.com/ws',
      channelFactory: (_) => ws,
      recorderFactory: () => failing,
    );
    await session.start();
    await Future<void>.delayed(Duration.zero);
    expect(session.state, LiveCallState.error);
    expect(session.errorMessage, contains('mic:'));
    expect(failing.lastConfig?.sampleRate, LiveApiSession.micSampleRate);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('dispose 後不再通知 listener', () async {
    final h = _Harness();
    var notified = 0;
    h.session.addListener(() => notified++);

    await h.session.start();
    await h.pump();
    final ws = h.ws;

    h.session.dispose();
    await h.pump();
    final before = notified;

    ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{'modelTurn': <String, dynamic>{}},
    });
    await h.pump();
    expect(notified, before);
  });

  test('RecordConfig 使用 micSampleRate（16 kHz mono）', () async {
    final h = _Harness();
    await h.session.start();
    await h.pump();
    expect(h.recorder.lastConfig?.sampleRate, 16000);
    expect(h.recorder.lastConfig?.numChannels, 1);
    expect(h.recorder.lastConfig?.encoder, AudioEncoder.pcm16bits);
    // Android：record 的 focus loss 會暫停錄音且不恢復，
    // 必須設為 none 讓錄音器對 focus 變化免疫（由 call mode 集中管理 focus）。
    expect(h.recorder.lastConfig?.audioInterruption, AudioInterruptionMode.none);
    h.session.dispose();
    await h.pump();
  });

  test('播放失敗時 dispose player 並續播下一個播放包', () async {
    final h = _Harness(failPlayForFirstN: 1);
    await h.activate();

    // 兩個播放包入佇列
    h.pushModelAudio(24000);
    h.pushModelAudio(24000);
    await h.pump();

    // 第一個 player 播放失敗 → 被 dispose，第二個接手播放
    expect(h.players.length, 2);
    expect(h.players[0].disposed, isTrue);
    expect(h.players[1].playCount, 1);

    h.session.dispose();
    await h.pump();
  });

  test('interrupted 清空播放佇列並釋放目前 player', () async {
    final h = _Harness();
    await h.activate();

    h.pushModelAudio(24000);
    await h.pump();
    expect(h.players.length, 1);
    expect(h.players.single.playCount, 1);

    // 伺服器中斷 → flush：player 被 dispose、可恢復 mic
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{'interrupted': true},
    });
    await h.pump();
    expect(h.players.single.disposed, isTrue);

    // 中斷後新音訊建立全新 player（佇列未被舊資料污染）
    h.pushModelAudio(24000);
    await h.pump();
    expect(h.players.length, 2);
    expect(h.players[1].playCount, 1);

    h.session.dispose();
    await h.pump();
  });

  test('播放中 stop() 會釋放目前 player 且不 crash', () async {
    final h = _Harness();
    await h.activate();

    h.pushModelAudio(24000);
    await h.pump();
    expect(h.players.single.playCount, 1);
    expect(h.players.single.disposed, isFalse);

    await h.session.stop();
    expect(h.players.single.disposed, isTrue);
    expect(h.session.state, LiveCallState.ended);

    // stop 後伺服器再推音訊也不 crash（訊息處理已停止）
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'modelTurn': <String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{
              'inlineData': <String, dynamic>{
                'data': base64Encode(Uint8List(24000)),
              },
            },
          ],
        },
      },
    });
    await h.pump();
  });

  test('gapless：下一個播放包先 prepare，完成後 resume 切換不重建', () async {
    final h = _Harness();
    await h.activate();

    h.pushModelAudio(24000);
    h.pushModelAudio(24000);
    await h.pump();

    // 第一個播放中；第二個已預先 prepare（setSource 完成、未 resume）
    expect(h.players.length, 2);
    expect(h.players[0].playCount, 1);
    expect(h.players[0].disposed, isFalse);
    expect(h.players[1].playCount, 0);
    expect(h.players[1].prepared, isTrue);
    expect(h.players[1].disposed, isFalse);

    // 完成第一個 → 第二個直接 resume（不重新建立 player）
    h.players[0].emitComplete();
    await h.pump();
    expect(h.players[0].disposed, isTrue);
    expect(h.players[1].playCount, 1);
    expect(h.players[1].disposed, isFalse);
    expect(h.players.length, 2);

    h.session.dispose();
    await h.pump();
  });

  test('interrupted 釋放已 prepare 的預備槽與目前 player', () async {
    final h = _Harness();
    await h.activate();

    h.pushModelAudio(24000);
    h.pushModelAudio(24000);
    await h.pump();
    expect(h.players.length, 2);
    expect(h.players[1].prepared, isTrue);
    expect(h.players[1].disposed, isFalse);

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{'interrupted': true},
    });
    await h.pump();
    expect(h.players[0].disposed, isTrue);
    expect(h.players[1].disposed, isTrue);

    h.session.dispose();
    await h.pump();
  });

  // ---- §5.7 lifecycle、斷網與重連 ----

  test('斷線後自動重連：新 ws/recorder、舊資源已清理、不重送舊音訊', () async {
    final h = _Harness();
    await h.activate();
    final ws1 = h.ws;
    final recorder1 = h.recorder;

    // 網路中斷 → 伺服器關閉連線
    ws1.serverClose(1006, 'network lost');
    await h.pump();
    expect(h.session.state, LiveCallState.reconnecting);

    // 退避後自動重連 → 全新 ws/recorder；舊的已 close/dispose
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await h.pump();
    expect(h.session.state, LiveCallState.connecting);
    expect(h.wsList.length, 2);
    expect(h.ws, isNot(same(ws1)));
    expect(ws1.sinkClosed, isTrue);
    expect(h.recorders.length, 2);
    expect(recorder1.disposed, isTrue);

    // setupComplete → active
    h.ws.push(<String, dynamic>{'setupComplete': <String, dynamic>{}});
    await h.pump();
    expect(h.session.state, LiveCallState.active);

    // 新 mic 資料只含新 chunk（舊 buffer 未重送）
    h.sendAudio(3200);
    await h.pump();
    final msgs = h.ws.sent.cast<String>();
    final audioMsgs = msgs
        .map(jsonDecode)
        .whereType<Map<String, dynamic>>()
        .where(
          (m) => (m['realtimeInput'] as Map?)?.containsKey('audio') ?? false,
        )
        .toList();
    expect(audioMsgs, isNotEmpty);
    final data =
        (((audioMsgs.last['realtimeInput'] as Map)['audio'])
                as Map<String, dynamic>)['data'] as String;
    expect(base64Decode(data).length, 3200);

    h.session.dispose();
    await h.pump();
  });

  test('重連次數耗盡進入 error；手動 start 重試成功', () async {
    final h = _Harness(maxReconnects: 2);
    await h.activate();

    // 第一次斷線 → reconnecting → 自動重連
    h.ws.serverClose(1006, 'lost 1');
    await h.pump();
    expect(h.session.state, LiveCallState.reconnecting);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await h.pump();
    expect(h.session.state, LiveCallState.connecting);

    // 重連後再斷線 → reconnecting → 自動重連
    h.ws.serverClose(1006, 'lost 2');
    await h.pump();
    expect(h.session.state, LiveCallState.reconnecting);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await h.pump();
    expect(h.session.state, LiveCallState.connecting);

    // 第三次斷線 → 重連次數耗盡 → error（明確訊息 + 手動重試）
    h.ws.serverClose(1006, 'lost 3');
    await h.pump();
    expect(h.session.state, LiveCallState.error);
    expect(h.session.errorMessage, contains('已重連 2 次'));

    // 手動 start（UI 重試鈕）→ 計數歸零、重連成功
    await h.session.start();
    h.ws.push(<String, dynamic>{'setupComplete': <String, dynamic>{}});
    await h.pump();
    expect(h.session.state, LiveCallState.active);

    h.session.dispose();
    await h.pump();
  });

  test('server error 訊息直接 error，不觸發自動重連', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'error': <String, dynamic>{
        'status': 'INVALID_ARGUMENT',
        'message': 'invalid api key',
      },
    });
    await h.pump();
    expect(h.session.state, LiveCallState.error);
    expect(h.session.errorMessage, contains('INVALID_ARGUMENT'));
    expect(h.wsList.length, 1); // 沒有自動重連

    h.session.dispose();
    await h.pump();
  });

  test('ws error 訊息遮蔽 API Key（WebSocketException 含完整 uri）',
      () async {
    final h = _Harness(maxReconnects: 0); // 直接進 error，避免退避 timer
    await h.activate();

    h.ws.serverError(
      WebSocketException(
        "Connection to 'wss://example.com/ws?key=AIza-test' was not upgraded",
      ),
    );
    await h.pump();
    expect(h.session.state, LiveCallState.error);
    expect(h.session.errorMessage, isNot(contains('AIza-test')));

    h.session.dispose();
    await h.pump();
  });

  test('pause() 停止 mic、送 stream end、背景不播放；resume() 重啟 mic',
      () async {
    final h = _Harness();
    await h.activate();
    final recorder1 = h.recorder;

    await h.session.pause();
    expect(h.session.state, LiveCallState.background);
    expect(recorder1.stopped, isTrue);
    expect(recorder1.disposed, isTrue);

    // stream end 已送出（讓伺服器完成目前 turn）
    final endMsgs = h.ws.sent
        .cast<String>()
        .map(jsonDecode)
        .whereType<Map<String, dynamic>>()
        .where(
          (m) =>
              (m['realtimeInput'] as Map?)?.containsKey('audio_stream_end') ??
              false,
        );
    expect(endMsgs, isNotEmpty);

    // 背景期間伺服器推音訊 → 不建立 player
    h.pushModelAudio(24000);
    await h.pump();
    expect(h.players, isEmpty);

    // 恢復前景 → 新 recorder、active、mic 恢復送出
    await h.session.resume();
    expect(h.session.state, LiveCallState.active);
    expect(h.recorders.length, 2);
    expect(h.recorders.last.disposed, isFalse);

    final sentBefore = h.ws.sent.length;
    h.sendAudio(3200);
    await h.pump();
    expect(h.ws.sent.length, sentBefore + 1);

    h.session.dispose();
    await h.pump();
  });

  test('背景中斷線自動進入 reconnecting（不 crash）', () async {
    final h = _Harness();
    await h.activate();
    await h.session.pause();
    expect(h.session.state, LiveCallState.background);

    h.ws.serverClose(1006, 'lost while backgrounded');
    await h.pump();
    expect(h.session.state, LiveCallState.reconnecting);

    h.session.dispose();
    await h.pump();
  });

  test('input transcription 即時更新 userPartial（取代語意）', () async {
    final h = _Harness();
    await h.activate();
    expect(h.session.userPartial, '');

    // 同一句話的遞增/修正文字：每個訊息都是完整 partial，取代而非累加
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'input_transcription': <String, dynamic>{'text': '今天'},
      },
    });
    await h.pump();
    expect(h.session.userPartial, '今天');

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'input_transcription': <String, dynamic>{'text': '今天天氣如何'},
      },
    });
    await h.pump();
    expect(h.session.userPartial, '今天天氣如何');

    h.session.dispose();
    await h.pump();
  });

  test('input transcription 支援 camelCase（inputTranscription）', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'inputTranscription': <String, dynamic>{'text': '明天呢'},
      },
    });
    await h.pump();
    expect(h.session.userPartial, '明天呢');

    h.session.dispose();
    await h.pump();
  });

  test('turnComplete 清除 userPartial；下一個語句重新填入', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'input_transcription': <String, dynamic>{'text': '幫我算 1+1'},
      },
    });
    await h.pump();
    expect(h.session.userPartial, '幫我算 1+1');

    h.pushTurnComplete();
    await h.pump();
    expect(h.session.userPartial, '');

    // 下一個語句的轉錄重新填入
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'input_transcription': <String, dynamic>{'text': '第二句'},
      },
    });
    await h.pump();
    expect(h.session.userPartial, '第二句');

    h.session.dispose();
    await h.pump();
  });

  test('input transcription 空字串不覆寫既有 userPartial', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'input_transcription': <String, dynamic>{'text': '一段話'},
      },
    });
    await h.pump();
    expect(h.session.userPartial, '一段話');

    // 空文字訊息（部分實作會送）不應清掉目前的 partial
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'input_transcription': <String, dynamic>{'text': ''},
      },
    });
    await h.pump();
    expect(h.session.userPartial, '一段話');

    h.session.dispose();
    await h.pump();
  });

  test('output transcription 累積 assistantPartial（snake_case）', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'output_transcription': <String, dynamic>{'text': '第一段'},
      },
    });
    await h.pump();
    expect(h.session.assistantPartial, '第一段');

    // 累加語意（與 input 的取代語意不同）
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'output_transcription': <String, dynamic>{'text': '第二段'},
      },
    });
    await h.pump();
    expect(h.session.assistantPartial, '第一段第二段');

    h.session.dispose();
    await h.pump();
  });

  test('output transcription 支援 camelCase（outputTranscription）', () async {
    final h = _Harness();
    await h.activate();

    // 官方文件為 camelCase；實測 server 可能以 camelCase 回傳
    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'outputTranscription': <String, dynamic>{'text': '模型說的話'},
      },
    });
    await h.pump();
    expect(h.session.assistantPartial, '模型說的話');

    h.session.dispose();
    await h.pump();
  });

  test('output transcription 空字串不累積', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'output_transcription': <String, dynamic>{'text': '有內容'},
      },
    });
    await h.pump();
    expect(h.session.assistantPartial, '有內容');

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'output_transcription': <String, dynamic>{'text': ''},
      },
    });
    await h.pump();
    expect(h.session.assistantPartial, '有內容');

    h.session.dispose();
    await h.pump();
  });

  test('turnComplete 提交 assistantPartial 到 turns 並清除', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'serverContent': <String, dynamic>{
        'output_transcription': <String, dynamic>{'text': '完整回合'},
      },
    });
    await h.pump();
    expect(h.session.assistantPartial, '完整回合');

    h.pushTurnComplete();
    await h.pump();
    expect(h.session.assistantPartial, '');
    expect(h.session.turns, <String>['完整回合']);

    h.session.dispose();
    await h.pump();
  });

  // ---- Function calling ----

  test('setup 含 tools 宣告；未提供 tools 時不帶欄位', () async {
    final withTools = LiveApiSession.buildSetupPayload(
      model: 'gemini-3.1-flash-live-preview',
      voice: 'Kore',
      tools: <Map<String, dynamic>>[
        <String, dynamic>{
          'functionDeclarations': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'get_current_datetime',
              'description': '取得目前時間',
            },
          ],
        },
      ],
    );
    final decodedWith = jsonDecode(withTools) as Map<String, dynamic>;
    final setup = decodedWith['setup'] as Map<String, dynamic>;
    expect(setup['tools'], isA<List<dynamic>>());
    expect(
      (setup['tools'] as List).single,
      containsPair('functionDeclarations', isA<List<dynamic>>()),
    );

    final withoutTools = LiveApiSession.buildSetupPayload(
      model: 'gemini-3.1-flash-live-preview',
      voice: 'Kore',
    );
    final decodedWithout = jsonDecode(withoutTools) as Map<String, dynamic>;
    expect(
      (decodedWithout['setup'] as Map<String, dynamic>).containsKey('tools'),
      isFalse,
    );
  });

  test('toolCall → 執行 handler → 送 toolResponse、pending 清除', () async {
    final calls = <String>[];
    final h = _Harness(
      toolHandler: (name, args) async {
        calls.add(name);
        return <String, dynamic>{'now': '2026-08-09'};
      },
    );
    await h.activate();

    h.ws.push(<String, dynamic>{
      'toolCall': <String, dynamic>{
        'functionCalls': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'call-1',
            'name': 'get_current_datetime',
            'args': <String, dynamic>{'tz': 'Asia/Taipei'},
          },
        ],
      },
    });
    await h.pump();
    expect(calls, <String>['get_current_datetime']);
    expect(h.session.pendingToolCalls, isEmpty);

    final sent = h.ws.sent.cast<String>().toList();
    final toolMsg = sent
        .map(jsonDecode)
        .whereType<Map<String, dynamic>>()
        .lastWhere((m) => m.containsKey('toolResponse'));
    final fn =
        ((toolMsg['toolResponse'] as Map)['functionResponses'] as List).single
            as Map;
    expect(fn['id'], 'call-1');
    expect(fn['name'], 'get_current_datetime');
    expect((fn['response'] as Map)['now'], '2026-08-09');

    h.session.dispose();
    await h.pump();
  });

  test('無 handler 時回覆 error；handler 拋錯也回 error', () async {
    final h = _Harness();
    await h.activate();

    h.ws.push(<String, dynamic>{
      'toolCall': <String, dynamic>{
        'functionCalls': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'c1', 'name': 'unknown_tool'},
        ],
      },
    });
    await h.pump();
    expect(h.session.pendingToolCalls, isEmpty);
    final sent = h.ws.sent.cast<String>().toList();
    final toolMsg = sent
        .map(jsonDecode)
        .whereType<Map<String, dynamic>>()
        .lastWhere((m) => m.containsKey('toolResponse'));
    final fn =
        ((toolMsg['toolResponse'] as Map)['functionResponses'] as List).single
            as Map;
    expect((fn['response'] as Map)['error'], contains('no tool handler'));

    h.session.dispose();
    await h.pump();
  });

  test('toolCallCancellation 移除 pending tool call', () async {
    // 慢 handler：讓 call 停留在 pending 狀態
    final gate = Completer<Map<String, dynamic>>();
    final h = _Harness(toolHandler: (name, args) => gate.future);
    await h.activate();

    h.ws.push(<String, dynamic>{
      'toolCall': <String, dynamic>{
        'functionCalls': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'c1', 'name': 'slow_tool'},
        ],
      },
    });
    await h.pump();
    expect(h.session.pendingToolCalls, hasLength(1));

    h.ws.push(<String, dynamic>{
      'toolCallCancellation': <String, dynamic>{'ids': <String>['c1']},
    });
    await h.pump();
    expect(h.session.pendingToolCalls, isEmpty);

    gate.complete(<String, dynamic>{'ok': true});
    await h.pump();
    h.session.dispose();
    await h.pump();
  });
}
