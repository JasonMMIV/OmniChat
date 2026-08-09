import 'dart:io';

import 'package:audio_session/audio_session.dart';
// prefix 限定：audio_session 與 audioplayers 都匯出 AVAudioSessionCategory /
// AndroidAudioFocus，避免 ambiguous_import
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/services.dart';
import 'package:flutter_background/flutter_background.dart';

/// Android/iOS 音訊 session、Android 背景服務與 call mode channel 的集中設定
/// （Platform 判斷集中）。自 voice_chat_screen 搬移（Phase 3 任務 3.3）。
class PlatformAudioSetup {
  static const MethodChannel _callModeChannel =
      MethodChannel('omnichat/call_mode');

  /// Voice chat 專用音訊 session 設定（Bluetooth call simulation，Mobile only）。
  static Future<void> initAudioSessionForVoiceChat() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
                AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));
    } catch (_) {}
  }

  /// 開始聆聽前確保音訊 session 為 active（Mobile only）。
  static Future<void> activateAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (_) {}
  }

  /// 結束語音對話時停用音訊 session。
  static Future<void> deactivateAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}
  }

  /// Android 背景服務（保持語音對話在背景持續運作）。
  static Future<void> initBackgroundService() async {
    try {
      if (Platform.isAndroid) {
        final androidConfig = FlutterBackgroundAndroidConfig(
          notificationTitle: "OmniChat Voice Chat",
          notificationText: "Voice chat is active",
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon: const AndroidResource(
            name: 'ic_launcher',
            defType: 'mipmap',
          ),
        );
        await FlutterBackground.initialize(androidConfig: androidConfig);
        await FlutterBackground.enableBackgroundExecution();
      }
    } catch (_) {}
  }

  /// 停用 Android 背景執行。
  static Future<void> disableBackgroundExecution() async {
    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (_) {}
  }

  /// Android call mode（藍牙/喇叭路由處理）。
  static Future<void> startCallMode() async {
    try {
      await _callModeChannel.invokeMethod('startCallMode');
    } catch (_) {}
  }

  /// 建立與目前 call mode 路由一致的播放器 [AudioContext]（純函式，供測試）。
  ///
  /// C1 方案：`audioFocus: none` 讓 audioplayers 不再每包 request/abandon
  /// audio focus（focus 由 call mode 集中管理）；但 audioplayers 的
  /// `setAudioContext` 在 Android 會**全域覆寫** `AudioManager.mode` 與
  /// `isSpeakerphoneOn`，因此必須把目前路由值（藍牙→`inCommunication`/
  /// speakerphone off；喇叭→`normal`/speakerphone on）一併傳入，否則會
  /// 弄壞藍牙 SCO 或喇叭輸出路由。
  static ap.AudioContext buildPlaybackAudioContext({
    required bool bluetooth,
    required int audioMode,
    required bool isSpeakerphoneOn,
  }) {
    return ap.AudioContext(
      android: ap.AudioContextAndroid(
        audioFocus: ap.AndroidAudioFocus.none,
        // fromInt 對不到的值會拋錯；未知 mode 安全回退 normal
        audioMode: ap.AndroidAudioMode.values.firstWhere(
          (m) => m.value == audioMode,
          orElse: () => ap.AndroidAudioMode.normal,
        ),
        isSpeakerphoneOn: isSpeakerphoneOn,
        // 與 native startCallMode 一致：藍牙走語音通訊屬性、喇叭走媒體屬性
        contentType: bluetooth
            ? ap.AndroidContentType.speech
            : ap.AndroidContentType.music,
        usageType: bluetooth
            ? ap.AndroidUsageType.voiceCommunication
            : ap.AndroidUsageType.media,
      ),
    );
  }

  /// 查詢目前 call mode 路由並建立播放器 [AudioContext]。
  ///
  /// Android 才查詢；其他平台或查詢失敗回 null（不設 context，維持現狀，
  /// 不破壞路由）。
  static Future<ap.AudioContext?> playbackAudioContext() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _callModeChannel
          .invokeMethod<Map<dynamic, dynamic>>('getCallModeState');
      if (result == null) return null;
      final bluetooth = result['bluetoothConnected'] as bool? ?? false;
      final audioMode = (result['audioMode'] as num?)?.toInt() ?? 0;
      final isSpeakerphoneOn =
          result['isSpeakerphoneOn'] as bool? ?? false;
      return buildPlaybackAudioContext(
        bluetooth: bluetooth,
        audioMode: audioMode,
        isSpeakerphoneOn: isSpeakerphoneOn,
      );
    } catch (_) {
      return null;
    }
  }

  /// 停止 Android call mode。
  static Future<void> stopCallMode() async {
    try {
      await _callModeChannel.invokeMethod('stopCallMode');
    } catch (_) {}
  }
}
