import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/features/voice_chat/services/platform_audio_setup.dart';

void main() {
  group('buildPlaybackAudioContext（C1：focus none + 保留路由）', () {
    test('audioFocus 一律為 none（不與 call mode 搶 focus）', () {
      final ctx = PlatformAudioSetup.buildPlaybackAudioContext(
        bluetooth: false,
        audioMode: 0, // MODE_NORMAL
        isSpeakerphoneOn: true,
      );
      expect(ctx.android.audioFocus, ap.AndroidAudioFocus.none);
    });

    test('喇叭路徑：保留 MODE_NORMAL + speakerphone on + media/music 屬性', () {
      final ctx = PlatformAudioSetup.buildPlaybackAudioContext(
        bluetooth: false,
        audioMode: 0, // AudioManager.MODE_NORMAL
        isSpeakerphoneOn: true,
      );
      expect(ctx.android.audioMode, ap.AndroidAudioMode.normal);
      expect(ctx.android.isSpeakerphoneOn, isTrue);
      expect(ctx.android.usageType, ap.AndroidUsageType.media);
      expect(ctx.android.contentType, ap.AndroidContentType.music);
    });

    test('藍牙路徑：保留 MODE_IN_COMMUNICATION + speakerphone off + 語音屬性', () {
      final ctx = PlatformAudioSetup.buildPlaybackAudioContext(
        bluetooth: true,
        audioMode: 3, // AudioManager.MODE_IN_COMMUNICATION
        isSpeakerphoneOn: false,
      );
      expect(ctx.android.audioMode, ap.AndroidAudioMode.inCommunication);
      expect(ctx.android.isSpeakerphoneOn, isFalse);
      expect(ctx.android.usageType, ap.AndroidUsageType.voiceCommunication);
      expect(ctx.android.contentType, ap.AndroidContentType.speech);
    });

    test('未知 audioMode 值不會 crash（fallback 以 fromInt 對應）', () {
      final ctx = PlatformAudioSetup.buildPlaybackAudioContext(
        bluetooth: false,
        audioMode: 99,
        isSpeakerphoneOn: false,
      );
      // fromInt 對不到時回第一個值（unknown/0）——只驗證不會拋錯
      expect(ctx.android, isA<ap.AudioContextAndroid>());
    });
  });
}
