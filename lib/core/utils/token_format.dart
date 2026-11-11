// Token-count formatting for display chips (ported from Kelivo's
// `lib/core/utils/token_format.dart`).
//
// Pure Dart, no Flutter imports. Deliberately separate from
// `compactTokenText` in context_usage_service.dart, which mirrors AnyBuff's
// usage-ring formatting (always keeps the `.0`); chips follow Kelivo's
// truncated style instead: `128k` / `1M`, no trailing decimal zero.
library;

/// Formats a token count for a compact chip label.
///
/// - `< 1000` → raw digits (`999`)
/// - `< 1,000,000` → thousands with at most one decimal (`128k`, `1.5k`)
/// - else → millions with at most one decimal (`1M`, `1.5M`)
String formatTokenCount(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return '${_oneDecimal(tokens / 1000)}k';
  return '${_oneDecimal(tokens / 1000000)}M';
}

String _oneDecimal(double value) {
  final truncated = (value * 10).truncateToDouble() / 10;
  if (truncated == truncated.truncateToDouble()) {
    return '${truncated.toInt()}';
  }
  return truncated.toStringAsFixed(1);
}
