import '../../../core/models/chat_message.dart';
import '../../../core/models/message_usage.dart';
import '../../../utils/usd_format.dart';

/// Builds the small stats line under a message bubble.
///
/// [usageSummary] is already localized by the caller. An empty summary must
/// leave the output byte-identical to the pre-cost-display format.
String buildMessageStatsText(ChatMessage message, {String? usageSummary}) {
  final int tokens;
  final bool isEstimated;
  if (message.totalTokens != null && message.totalTokens! > 0) {
    tokens = message.totalTokens!;
    isEstimated = false;
  } else {
    final fullText = message.content + (message.reasoningText ?? '');
    tokens = estimateMessageTokens(fullText);
    isEstimated = true;
  }

  final tokenStr = isEstimated ? '~$tokens tokens' : '$tokens tokens';
  final charCount = message.content.length;
  final base = charCount > 0 ? '$tokenStr · $charCount 字' : tokenStr;
  return usageSummary == null || usageSummary.isEmpty
      ? base
      : '$base · $usageSummary';
}

/// Builds the localized cost fragment appended to the stats line.
///
/// `billing_source` is authoritative when present, but an OpenCode Go response
/// may omit it while still carrying `allowance`. In that case the allowance is
/// preferred so a zero `cost` is never presented as a plain `$0` charge.
String? buildUsageSummary(
  MessageUsage? usage, {
  required String freeLabel,
  required String allowanceLabel,
  required String listPriceLabel,
}) {
  if (usage == null || usage.isEmpty) return null;
  final billing = (usage.billingSource ?? '').toLowerCase();
  switch (billing) {
    case 'free':
      return freeLabel;
    case 'go':
    case 'go-plus':
      final allowance = formatUsd(usage.allowanceUsd);
      if (usage.allowanceUsd != null && usage.allowanceUsd! > 0) {
        if (allowance != null) return '$allowanceLabel $allowance';
      }
      final list = formatUsd(usage.listCostUsd);
      if (list != null) return '$listPriceLabel $list';
      final charged = formatUsd(usage.costUsd);
      if (usage.costUsd != null && usage.costUsd! > 0) {
        if (charged != null) return charged;
      }
      return null;
    case 'byok':
      final formatted = formatUsd(usage.costUsd ?? usage.listCostUsd);
      if (formatted == null) return null;
      return usage.estimated ? '≈$formatted' : formatted;
    case 'balance':
      final formatted = formatUsd(usage.costUsd ?? usage.listCostUsd);
      if (formatted == null) return null;
      return usage.estimated ? '≈$formatted' : formatted;
    default:
      final allowance = formatUsd(usage.allowanceUsd);
      if (usage.allowanceUsd != null && usage.allowanceUsd! > 0) {
        if (allowance != null) return '$allowanceLabel $allowance';
      }
      final formatted = formatUsd(usage.costUsd ?? usage.listCostUsd);
      if (formatted == null) return null;
      return usage.estimated ? '≈$formatted' : formatted;
  }
}

/// Cheap fallback token estimate used when a provider does not report usage.
int estimateMessageTokens(String text) {
  if (text.isEmpty) return 0;
  int cjkCount = 0;
  int otherCharCount = 0;
  for (final char in text.runes) {
    if ((char >= 0x4E00 && char <= 0x9FFF) ||
        (char >= 0x3400 && char <= 0x4DBF) ||
        (char >= 0x3000 && char <= 0x303F) ||
        (char >= 0xFF00 && char <= 0xFFEF)) {
      cjkCount++;
    } else {
      otherCharCount++;
    }
  }
  return cjkCount + (otherCharCount / 4).ceil();
}
