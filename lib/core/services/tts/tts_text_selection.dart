enum TtsTextSelectionMode {
  fullText,
  outsideParentheses,
}

extension TtsTextSelectionModeStorage on TtsTextSelectionMode {
  String get storageValue => name;

  static TtsTextSelectionMode fromStorageValue(String? value) {
    for (final mode in TtsTextSelectionMode.values) {
      if (mode.name == value) return mode;
    }
    return TtsTextSelectionMode.fullText;
  }
}

class TtsTextSelection {
  const TtsTextSelection._();

  static String apply(
    String input, {
    required TtsTextSelectionMode mode,
    bool fallbackToOriginal = true,
  }) {
    final original = input.trim();
    if (original.isEmpty) return '';

    final selected = switch (mode) {
      TtsTextSelectionMode.fullText => original,
      TtsTextSelectionMode.outsideParentheses => _outsideParentheses(original),
    };
    final normalized = _normalizeSelectedText(selected);
    if (normalized.isNotEmpty || !fallbackToOriginal) return normalized;
    return original;
  }

  static String _outsideParentheses(String input) {
    // Replace content inside parentheses: (), （）, [], 【】
    var result = input;
    // Round brackets: ASCII () and Fullwidth （）
    result = result.replaceAll(RegExp(r'\([^)]*\)'), '');
    result = result.replaceAll(RegExp(r'（[^）]*）'), '');
    // Square brackets: ASCII [] and Fullwidth 【】
    result = result.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    result = result.replaceAll(RegExp(r'【[^】]*】'), '');
    return result;
  }

  static String _normalizeSelectedText(String input) {
    return input
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
  }
}
