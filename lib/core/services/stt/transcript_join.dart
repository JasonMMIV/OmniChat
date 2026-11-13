/// 分段轉錄文字的串接規則（docs/speech_recognition_import_plan.md §4.4.2）。
///
/// 批次 STT 每 30 秒一段，各段是獨立結果；直接 `+` 會讓英文黏在一起，
/// 一律補空白又會在中文之間插入空格。
String joinTranscript(String prefix, String next) {
  if (prefix.isEmpty) return next;
  if (next.isEmpty) return prefix;
  // 下一段已自帶前導空白（或換行）→ 尊重供應商輸出。
  final first = next.codeUnitAt(0);
  if (_isWhitespace(first)) return '$prefix$next';
  final last = prefix.codeUnitAt(prefix.length - 1);
  // CJK／泰文不使用空白分詞。
  if (_isNoSpaceScript(last) || _isNoSpaceScript(first)) return '$prefix$next';
  final lastAllowsSpace = _isLatinAlnum(last) ||
      _isHangul(last) ||
      _isPunctuation(last);
  final nextStartsWord = _isLatinAlnum(first) || _isHangul(first);
  if (lastAllowsSpace && nextStartsWord) return '$prefix $next';
  return '$prefix$next';
}

bool _isWhitespace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

bool _isLatinAlnum(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A);

bool _isHangul(int c) =>
    (c >= 0x1100 && c <= 0x11FF) ||
    (c >= 0x3130 && c <= 0x318F) ||
    (c >= 0xAC00 && c <= 0xD7A3);

/// Han／Hiragana／Katakana／Thai：不加空白（韓文另有空格分詞規則）。
bool _isNoSpaceScript(int c) =>
    (c >= 0x3400 && c <= 0x4DBF) ||
    (c >= 0x4E00 && c <= 0x9FFF) ||
    (c >= 0xF900 && c <= 0xFAFF) ||
    (c >= 0x3040 && c <= 0x30FF) ||
    (c >= 0x0E00 && c <= 0x0E7F) ||
    (c >= 0x3000 && c <= 0x303F);

bool _isPunctuation(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E) ||
    (c >= 0x2000 && c <= 0x206F);
