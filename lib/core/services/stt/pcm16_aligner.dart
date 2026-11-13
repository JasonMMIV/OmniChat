import 'dart:typed_data';

/// `record` 的 PCM chunk 不保證 2-byte 對齊（可能切在半個 16-bit sample）。
///
/// 保留 1 byte carry，跨 chunk 接回；只輸出偶數長度的資料，避免把
/// 半個 sample 寫進 WAV（會造成 click／解碼錯位）。
class Pcm16Aligner {
  int? _pendingByte;

  /// 目前是否有未配對的 byte（`finish()` 時應丟棄）。
  bool get hasPendingByte => _pendingByte != null;

  /// 回傳可直接放入 segment buffer 的偶數長度資料。
  Uint8List add(Uint8List chunk) {
    if (chunk.isEmpty) return Uint8List(0);
    final pending = _pendingByte;
    final total = chunk.length + (pending == null ? 0 : 1);
    final usable = total.isEven ? total : total - 1;
    if (usable <= 0) {
      // 只有 1 byte 且沒有 carry → 留到下一次。
      _pendingByte = chunk[0];
      return Uint8List(0);
    }
    final out = Uint8List(usable);
    var written = 0;
    if (pending != null) {
      out[0] = pending;
      written = 1;
      _pendingByte = null;
    }
    out.setRange(written, written + (usable - written), chunk);
    if (total.isOdd) {
      _pendingByte = chunk[chunk.length - 1];
    }
    return out;
  }

  /// 取出並清除 carry（`finish()` 時單一 byte 不是完整 sample）。
  int? takePendingByte() {
    final pending = _pendingByte;
    _pendingByte = null;
    return pending;
  }
}
