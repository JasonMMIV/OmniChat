import 'dart:typed_data';

/// 共用 WAV 容器工具（docs/speech_recognition_import_plan.md §6.3）。
///
/// 只處理容器／header，**不做重取樣**。ASR 上傳需要 `pcm16MonoToWav`；
/// TTS 串流哨兵長度解析（`allowStreamingLengths`）留待 Phase 5。
class WavFormatException implements Exception {
  const WavFormatException(this.message);

  final String message;

  @override
  String toString() => 'WavFormatException: $message';
}

/// 解析後的 WAV 資訊。`dataOffset` / `dataLength` 指向實際音訊 bytes。
class WavInfo {
  const WavInfo({
    required this.channels,
    required this.sampleRate,
    required this.byteRate,
    required this.blockAlign,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  final int channels;
  final int sampleRate;
  final int byteRate;
  final int blockAlign;
  final int bitsPerSample;
  final int dataOffset;
  final int dataLength;

  Uint8List audioData(Uint8List bytes) =>
      Uint8List.sublistView(bytes, dataOffset, dataOffset + dataLength);
}

const int _kRiffHeaderLength = 12;
const int _kFmtChunkMinLength = 16;

Uint8List _asciiBytes(String value) {
  final out = Uint8List(value.length);
  for (var i = 0; i < value.length; i++) {
    out[i] = value.codeUnitAt(i) & 0xFF;
  }
  return out;
}

bool _hasAscii(Uint8List bytes, int offset, String value) {
  if (offset + value.length > bytes.length) return false;
  for (var i = 0; i < value.length; i++) {
    if (bytes[offset + i] != value.codeUnitAt(i)) return false;
  }
  return true;
}

/// `RIFF....WAVE` magic 判斷（不看 mime；供應商標示不可信）。
bool isRiffWav(Uint8List bytes) =>
    bytes.length >= _kRiffHeaderLength &&
    _hasAscii(bytes, 0, 'RIFF') &&
    _hasAscii(bytes, 8, 'WAVE');

/// 把 16-bit PCM 包成 canonical 44-byte WAV（單聲道／多聲道通用）。
Uint8List pcm16MonoToWav(
  Uint8List pcm, {
  required int sampleRate,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final blockAlign = channels * bitsPerSample ~/ 8;
  final byteRate = sampleRate * blockAlign;
  final fmt = ByteData(_kFmtChunkMinLength);
  fmt.setUint16(0, 1, Endian.little); // PCM
  fmt.setUint16(2, channels, Endian.little);
  fmt.setUint32(4, sampleRate, Endian.little);
  fmt.setUint32(8, byteRate, Endian.little);
  fmt.setUint16(12, blockAlign, Endian.little);
  fmt.setUint16(14, bitsPerSample, Endian.little);
  return encodeWav(
    Uint8List.view(fmt.buffer),
    <Uint8List>[pcm],
  );
}

/// 以既有 `fmt ` chunk 內容重寫 canonical header（不重取樣、不補零）。
Uint8List encodeWav(Uint8List formatData, Iterable<Uint8List> audioData) {
  final chunks = <Uint8List>[...audioData];
  var dataLength = 0;
  for (final chunk in chunks) {
    dataLength += chunk.length;
  }
  final riffSize = 4 + 8 + formatData.length + 8 + dataLength;
  final out = Uint8List(8 + riffSize);
  final bytes = ByteData.sublistView(out);
  out.setRange(0, 4, _asciiBytes('RIFF'));
  bytes.setUint32(4, riffSize, Endian.little);
  out.setRange(8, 12, _asciiBytes('WAVE'));
  out.setRange(12, 16, _asciiBytes('fmt '));
  bytes.setUint32(16, formatData.length, Endian.little);
  var offset = 20;
  out.setRange(offset, offset + formatData.length, formatData);
  offset += formatData.length;
  out.setRange(offset, offset + 4, _asciiBytes('data'));
  bytes.setUint32(offset + 4, dataLength, Endian.little);
  offset += 8;
  for (final chunk in chunks) {
    out.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return out;
}

/// 解析 WAV。預設拒絕超出檔案範圍的長度（Phase 1 不含串流哨兵）。
WavInfo parseWav(Uint8List bytes, {bool allowStreamingLengths = false}) {
  if (bytes.length < _kRiffHeaderLength || !isRiffWav(bytes)) {
    throw const WavFormatException('Not a RIFF/WAVE file');
  }
  int? channels;
  int? sampleRate;
  int? byteRate;
  int? blockAlign;
  int? bitsPerSample;
  int? dataOffset;
  int? dataLength;

  var offset = _kRiffHeaderLength;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final declaredSize = ByteData.sublistView(
      bytes,
      offset + 4,
      offset + 8,
    ).getUint32(0, Endian.little);
    final body = offset + 8;

    if (id == 'fmt ') {
      if (declaredSize < _kFmtChunkMinLength || body + declaredSize > bytes.length) {
        throw const WavFormatException('Invalid fmt chunk');
      }
      final fmt = ByteData.sublistView(bytes, body, body + _kFmtChunkMinLength);
      if (channels != null) {
        // 多個 fmt chunk 內容不一致時直接報錯，不猜。
        final same = channels == fmt.getUint16(2, Endian.little) &&
            sampleRate == fmt.getUint32(4, Endian.little);
        if (!same) {
          throw const WavFormatException('Conflicting fmt chunks');
        }
      }
      channels = fmt.getUint16(2, Endian.little);
      sampleRate = fmt.getUint32(4, Endian.little);
      byteRate = fmt.getUint32(8, Endian.little);
      blockAlign = fmt.getUint16(12, Endian.little);
      bitsPerSample = fmt.getUint16(14, Endian.little);
      if (channels <= 0 || sampleRate <= 0 || bitsPerSample <= 0) {
        throw const WavFormatException('Invalid fmt values');
      }
      if (bitsPerSample % 8 != 0) {
        throw const WavFormatException('bitsPerSample must be a multiple of 8');
      }
      if (blockAlign != channels * bitsPerSample ~/ 8) {
        throw const WavFormatException('blockAlign does not match channels/bits');
      }
      if (byteRate != sampleRate * blockAlign) {
        throw const WavFormatException('byteRate does not match sampleRate');
      }
    } else if (id == 'data') {
      if (declaredSize == 0 && bytes.length == body) {
        throw const WavFormatException('Empty data chunk');
      }
      final available = bytes.length - body;
      if (declaredSize > available && !allowStreamingLengths) {
        throw const WavFormatException('data chunk exceeds file length');
      }
      dataOffset = body;
      dataLength = declaredSize > available ? available : declaredSize;
      // 音訊資料通常是最後一個 chunk；解析到此即可。
      break;
    }

    final padded = declaredSize.isOdd ? declaredSize + 1 : declaredSize;
    offset = body + padded;
  }

  if (channels == null ||
      sampleRate == null ||
      byteRate == null ||
      blockAlign == null ||
      bitsPerSample == null) {
    throw const WavFormatException('Missing fmt chunk');
  }
  if (dataOffset == null || dataLength == null || dataLength <= 0) {
    throw const WavFormatException('Missing or empty data chunk');
  }
  if (!allowStreamingLengths && dataLength % blockAlign != 0) {
    throw const WavFormatException('data length is not block aligned');
  }
  return WavInfo(
    channels: channels,
    sampleRate: sampleRate,
    byteRate: byteRate,
    blockAlign: blockAlign,
    bitsPerSample: bitsPerSample,
    dataOffset: dataOffset,
    dataLength: dataLength,
  );
}
