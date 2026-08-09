import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/live/live_api_session.dart';
import 'package:OmniChat/features/voice_chat/pages/live_call_screen.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// 記錄 pause/resume 呼叫的假 session（不建立真實連線）。
class _FakeSession extends LiveApiSession {
  _FakeSession()
      : super(
          apiKey: 'AIza-test',
          model: 'gemini-3.1-flash-live-preview',
          voice: 'Kore',
          baseUrl: 'wss://example.com/ws',
        );

  int pauseCount = 0;
  int resumeCount = 0;

  @override
  Future<void> start() async {}

  @override
  Future<void> pause() async {
    pauseCount++;
  }

  @override
  Future<void> resume() async {
    resumeCount++;
  }
}

/// 測試環境的 platform channel mock：record / call_mode / audio_session。
class _ChannelRecorder {
  final List<String> callMode = <String>[];
  final List<String> audioSession = <String>[];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('omnichat/call_mode'),
      (MethodCall call) async {
        callMode.add(call.method);
        return true;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (MethodCall call) async {
        if (call.method == 'hasPermission') return true;
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_session'),
      (MethodCall call) async {
        audioSession.add(call.method);
        return null;
      },
    );
    // AudioPlayer 與 AudioRecorder 建構子需要的 channel
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (MethodCall call) async => null,
    );
  }
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required SettingsProvider sp,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: sp,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LiveCallScreen(),
      ),
    ),
  );
  // 讓 _init 的 async 鏈（audio session → permission → call mode → session）推進；
  // 若 WebSocket ready 卡住，16s 後 ws.ready.timeout / setup timeout 也會收尾。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 16));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // SettingsProvider._load 會讀 secure storage；未 mock 的 platform
    // channel 在 widget 測試中永不回傳（會卡住 _load）。
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('LiveCall 啟動時啟動 call mode；結束按鈕釋放 focus 與 call mode',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_call_mode_v1': 'liveApi',
      'live_api_key_v1': 'AIza-test',
    });
    final sp = SettingsProvider();
    final recorder = _ChannelRecorder();
    recorder.install();

    await _pumpScreen(tester, sp: sp);

    // 通話啟動 → startCallMode 已呼叫（audio session 也已 configure）
    expect(recorder.callMode, contains('startCallMode'));
    expect(recorder.audioSession, contains('setConfiguration'));

    // 結束通話（X 按鈕）→ 對稱釋放；deactivateAudioSession 在 pop 前
    // 完成（測試主機上 audio_session.setActive 對非 iOS/Android 是 no-op，
    // 無法從 channel 觀察，以「畫面已 pop」代表 _end 的釋放路徑跑完）
    await tester.tap(find.byIcon(Lucide.X));
    await tester.pumpAndSettle();

    expect(recorder.callMode, contains('stopCallMode'));
    expect(find.byType(LiveCallScreen), findsNothing);
  });

  testWidgets('route dispose（返回）釋放 call mode 與停用 audio session',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_call_mode_v1': 'liveApi',
      'live_api_key_v1': 'AIza-test',
    });
    final sp = SettingsProvider();
    final recorder = _ChannelRecorder();
    recorder.install();

    await _pumpScreen(tester, sp: sp);
    expect(recorder.callMode, contains('startCallMode'));

    // 替換 widget → LiveCallScreen.dispose 被呼叫（等同返回/route 移除）
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: sp,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SizedBox(),
        ),
      ),
    );
    await tester.pump();

    expect(recorder.callMode, contains('stopCallMode'));
    expect(find.byType(LiveCallScreen), findsNothing);
  });

  testWidgets('lifecycle paused/resumed 接到 session.pause/resume',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_call_mode_v1': 'liveApi',
      'live_api_key_v1': 'AIza-test',
    });
    final sp = SettingsProvider();
    final recorder = _ChannelRecorder();
    recorder.install();
    final fakeSession = _FakeSession();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: sp,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LiveCallScreen(sessionFactory: (_) => fakeSession),
        ),
      ),
    );
    await tester.pump();

    // 背景（paused）→ session.pause
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(fakeSession.pauseCount, 1);

    // 前景（resumed）→ session.resume
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(fakeSession.resumeCount, 1);

    // 短暫轉場（inactive）不觸發 pause（避免 mic 反覆重啟）
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(fakeSession.pauseCount, 1);

    // 清理（dispose 路徑，等同返回）
    await tester.pumpWidget(const SizedBox());
  });
}
