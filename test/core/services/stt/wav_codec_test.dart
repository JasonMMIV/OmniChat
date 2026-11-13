import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/audio/wav_codec.dart';

void main() {
  test('pcm16MonoToWav writes a canonical 44-byte header', () {
    final pcm = Uint8List(3200);
    final wav = pcm16MonoToWav(pcm, sampleRate: 16000);
    expect(wav.length, 44 + pcm.length);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');

    final data = ByteData.sublistView(wav);
    expect(data.getUint16(20, Endian.little), 1); // PCM
    expect(data.getUint16(22, Endian.little), 1); // mono
    expect(data.getUint32(24, Endian.little), 16000);
    expect(data.getUint32(28, Endian.little), 32000); // byteRate
    expect(data.getUint16(32, Endian.little), 2); // blockAlign
    expect(data.getUint16(34, Endian.little), 16); // bits
    expect(data.getUint32(40, Endian.little), pcm.length);
    expect(data.getUint32(4, Endian.little), wav.length - 8);
  });

  test('isRiffWav only trusts the magic, not the extension or mime', () {
    final wav = pcm16MonoToWav(Uint8List(4), sampleRate: 16000);
    expect(isRiffWav(wav), isTrue);
    expect(isRiffWav(Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00])), isFalse);
  });

  test('parseWav returns format and audio bounds', () {
    final pcm = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final wav = pcm16MonoToWav(pcm, sampleRate: 16000);
    final info = parseWav(wav);
    expect(info.channels, 1);
    expect(info.sampleRate, 16000);
    expect(info.bitsPerSample, 16);
    expect(info.dataOffset, 44);
    expect(info.dataLength, 64);
    expect(info.audioData(wav), pcm);
  });

  test('parseWav rejects non-WAV and truncated data', () {
    expect(
      () => parseWav(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<WavFormatException>()),
    );
    final wav = pcm16MonoToWav(Uint8List(64), sampleRate: 16000);
    final truncated = Uint8List.sublistView(wav, 0, wav.length - 10);
    expect(
      () => parseWav(Uint8List.fromList(truncated)),
      throwsA(isA<WavFormatException>()),
    );
  });

  test('parseWav rejects unaligned data lengths', () {
    final pcm = Uint8List(65); // 不是 2-byte 對齊
    final wav = pcm16MonoToWav(pcm, sampleRate: 16000);
    expect(
      () => parseWav(wav),
      throwsA(isA<WavFormatException>()),
    );
  });

  test('encodeWav rewrites the header without touching audio bytes', () {
    final pcm = Uint8List.fromList([1, 0, 2, 0]);
    final wav = pcm16MonoToWav(pcm, sampleRate: 24000);
    final info = parseWav(wav);
    final formatData = Uint8List.sublistView(wav, 20, 36);
    final rebuilt = encodeWav(formatData, [pcm]);
    expect(rebuilt, wav);
    expect(info.sampleRate, 24000);
  });

  test('odd PCM is preserved verbatim (caller must align)', () {
    final pcm = Uint8List(7);
    final wav = pcm16MonoToWav(pcm, sampleRate: 16000);
    expect(wav.length, 44 + 7);
  });
}
