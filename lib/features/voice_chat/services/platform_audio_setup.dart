import 'dart:io';

import 'package:audio_session/audio_session.dart';
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

  /// 停止 Android call mode。
  static Future<void> stopCallMode() async {
    try {
      await _callModeChannel.invokeMethod('stopCallMode');
    } catch (_) {}
  }
}
